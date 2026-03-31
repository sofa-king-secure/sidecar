#!/usr/bin/env python3
"""
Sidecar Migration Tool (Interactive)
Scans apps, shows per-item selection, migrates chosen items.
Updates the Sidecar manifest so the native app can track everything.
"""

import os
import sys
import json
import shutil
import subprocess
from pathlib import Path
from datetime import datetime

HOME = Path.home()
LIBRARY = HOME / "Library"
MANIFEST_PATH = HOME / "Library/Application Support/ProjectSidecar/manifest.json"
CONFIG_PATH = HOME / "Library/Application Support/ProjectSidecar/config.json"
APPS_DIR = Path("/Applications")

# ── Helpers ──

def human_size(size_bytes):
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size_bytes < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} TB"

def get_dir_size(path):
    total = 0
    for root, dirs, files in os.walk(str(path), followlinks=False):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except:
                pass
    return total

def get_bundle_id(app_path):
    plist = app_path / "Contents" / "Info.plist"
    if not plist.exists():
        return None
    try:
        r = subprocess.run(["defaults", "read", str(plist), "CFBundleIdentifier"],
                          capture_output=True, text=True)
        return r.stdout.strip() if r.returncode == 0 else None
    except:
        return None

def is_apple_app(bid):
    return bid and bid.startswith("com.apple.")

def find_external_drive():
    if CONFIG_PATH.exists():
        with open(CONFIG_PATH) as f:
            config = json.load(f)
        vol = config.get("configuredVolumeName")
        if vol:
            p = Path(f"/Volumes/{vol}")
            if p.exists():
                return p
    # Fallback: any non-system volume
    for v in Path("/Volumes").iterdir():
        if v.name not in ("Macintosh HD", "Macintosh HD - Data") and v.is_mount():
            return v
    return None

def load_manifest():
    if MANIFEST_PATH.exists():
        with open(MANIFEST_PATH) as f:
            return json.load(f)
    return []

def save_manifest(records):
    MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(MANIFEST_PATH, 'w') as f:
        json.dump(records, f, indent=2)

# ── Scanner ──

SKIP_BUNDLES = {"com.projectsidecar.app"}
SKIP_NAMES = {"sidecar"}
MIN_SUBDIR_SIZE = 10_000_000   # 10 MB
MIN_APP_SIZE = 20_000_000      # 20 MB total to show app

def scan_app(app_path):
    """Scan an app for migratable subdirectories inside ~/Library."""
    name = app_path.stem  # e.g., "Claude"
    bid = get_bundle_id(app_path)

    if is_apple_app(bid):
        return None
    if bid in SKIP_BUNDLES or name.lower() in SKIP_NAMES:
        return None

    search_terms = [name]
    if bid:
        search_terms.append(bid)
        parts = bid.split(".")
        if len(parts) >= 2:
            search_terms.append(parts[-1])

    items = []

    # Deep scan Application Support (subdirs inside matching folders)
    app_support = LIBRARY / "Application Support"
    if app_support.exists():
        for folder in app_support.iterdir():
            if not folder.is_dir() or folder.is_symlink():
                continue
            if not any(t.lower() in folder.name.lower() for t in search_terms):
                continue
            # Scan subdirectories
            try:
                for subdir in folder.iterdir():
                    if not subdir.is_dir():
                        continue
                    if subdir.is_symlink():
                        items.append({
                            "path": str(subdir),
                            "name": f"{folder.name}/{subdir.name}",
                            "size": 0,
                            "type": "subdir",
                            "status": "already_symlinked",
                            "target": os.readlink(str(subdir))
                        })
                    else:
                        size = get_dir_size(subdir)
                        if size >= MIN_SUBDIR_SIZE:
                            items.append({
                                "path": str(subdir),
                                "name": f"{folder.name}/{subdir.name}",
                                "size": size,
                                "type": "subdir",
                                "status": "local"
                            })
            except PermissionError:
                pass

    # Top-level scan: Caches
    caches = LIBRARY / "Caches"
    if caches.exists():
        for folder in caches.iterdir():
            if not folder.is_dir():
                continue
            if not any(t.lower() in folder.name.lower() for t in search_terms):
                continue
            if folder.is_symlink():
                items.append({
                    "path": str(folder),
                    "name": f"Caches/{folder.name}",
                    "size": 0,
                    "type": "cache",
                    "status": "already_symlinked",
                    "target": os.readlink(str(folder))
                })
            else:
                size = get_dir_size(folder)
                if size >= MIN_SUBDIR_SIZE:
                    items.append({
                        "path": str(folder),
                        "name": f"Caches/{folder.name}",
                        "size": size,
                        "type": "cache",
                        "status": "local"
                    })

    # Top-level scan: Logs
    logs = LIBRARY / "Logs"
    if logs.exists():
        for folder in logs.iterdir():
            if not folder.is_dir():
                continue
            if not any(t.lower() in folder.name.lower() for t in search_terms):
                continue
            if not folder.is_symlink():
                size = get_dir_size(folder)
                if size >= MIN_SUBDIR_SIZE:
                    items.append({
                        "path": str(folder),
                        "name": f"Logs/{folder.name}",
                        "size": size,
                        "type": "log",
                        "status": "local"
                    })

    # Sort by size descending
    items.sort(key=lambda x: x["size"], reverse=True)

    total = sum(i["size"] for i in items if i["status"] == "local")
    if total < MIN_APP_SIZE and not any(i["status"] == "already_symlinked" for i in items):
        return None

    return {
        "name": name,
        "bid": bid,
        "app_size": get_dir_size(app_path),
        "items": items
    }


def scan_all():
    """Scan all third-party apps."""
    results = []
    for app in sorted(APPS_DIR.iterdir()):
        if not app.name.endswith(".app"):
            continue
        if app.is_symlink():
            continue
        result = scan_app(app)
        if result:
            results.append(result)
    return results


# ── Migration ──

def migrate_item(item, ext_drive, app_name):
    """Move a directory to external drive and create symlink."""
    local = Path(item["path"])
    
    # Build external path
    if item["type"] == "subdir":
        parent_name = local.parent.name  # e.g., "Claude"
        ext_path = ext_drive / "Library" / parent_name / local.name
    else:
        category = local.parent.name  # e.g., "Caches"
        ext_path = ext_drive / "Library" / category / local.name

    print(f"    Moving {item['name']} ({human_size(item['size'])})...", end=" ", flush=True)

    try:
        ext_path.parent.mkdir(parents=True, exist_ok=True)

        if ext_path.exists():
            shutil.rmtree(str(ext_path))

        shutil.move(str(local), str(ext_path))
        os.symlink(str(ext_path), str(local))

        # Verify
        if local.is_symlink() and os.path.exists(os.readlink(str(local))):
            print("✅")
            return {
                "category": f"{'Application Support (subdir)' if item['type'] == 'subdir' else item['type'].title()}",
                "originalPath": str(local),
                "externalPath": str(ext_path),
                "sizeBytes": item["size"],
                "isSymlinked": True
            }
        else:
            print("❌ verification failed")
            return None
    except Exception as e:
        print(f"❌ {e}")
        # Try to move back
        try:
            if ext_path.exists() and not local.exists():
                shutil.move(str(ext_path), str(local))
        except:
            pass
        return None


# ── Main ──

def main():
    print()
    print("┌─────────────────────────────────────────────────────────┐")
    print("│            SIDECAR MIGRATION TOOL                       │")
    print("└─────────────────────────────────────────────────────────┘")

    ext_drive = find_external_drive()
    if not ext_drive:
        print("\n  ❌ No external drive found. Connect your drive and try again.")
        sys.exit(1)

    print(f"\n  External drive: {ext_drive.name}")
    print(f"  Scanning apps...\n")

    results = scan_all()

    if not results:
        print("  No apps with migratable data found.")
        return

    # Display all items with numbers
    all_items = []  # (index, app_name, bid, item)
    idx = 1

    for app in results:
        migratable = [i for i in app["items"] if i["status"] == "local"]
        symlinked = [i for i in app["items"] if i["status"] == "already_symlinked"]

        if not migratable and not symlinked:
            continue

        print(f"  {app['name']}:")

        for item in symlinked:
            print(f"    [✓]  {item['name']} (already on external)")

        for item in migratable:
            print(f"    [{idx}]  {item['name']} — {human_size(item['size'])}")
            all_items.append((idx, app["name"], app["bid"], item))
            idx += 1

        print()

    if not all_items:
        print("  Everything is already migrated!")
        return

    total_available = sum(i[3]["size"] for i in all_items)
    print(f"  Total available to migrate: {human_size(total_available)}")
    print()
    print("  Enter item numbers to migrate (comma-separated), 'all', or 'q' to quit:")
    print("  Example: 1,2,5")
    print()

    choice = input("  → ").strip().lower()

    if choice == 'q' or choice == '':
        print("  Cancelled.")
        return

    if choice == 'all':
        selected = all_items
    else:
        try:
            nums = [int(x.strip()) for x in choice.split(",")]
            selected = [item for item in all_items if item[0] in nums]
        except ValueError:
            print("  Invalid input.")
            return

    if not selected:
        print("  No valid items selected.")
        return

    total_selected = sum(i[3]["size"] for i in selected)
    print(f"\n  Migrating {len(selected)} item(s) ({human_size(total_selected)})...")
    print(f"  ⚠️  Close affected apps first!\n")
    input("  Press Enter to continue (or Ctrl+C to cancel)...")

    # Do the migration
    manifest = load_manifest()
    migrated_by_app = {}

    for idx, app_name, bid, item in selected:
        if app_name not in migrated_by_app:
            migrated_by_app[app_name] = {"bid": bid, "records": []}

        result = migrate_item(item, ext_drive, app_name)
        if result:
            migrated_by_app[app_name]["records"].append(result)

    # Update manifest
    for app_name, data in migrated_by_app.items():
        if not data["records"]:
            continue

        # Check if there's an existing active record for this app
        existing = None
        for r in manifest:
            if r.get("appName") == f"{app_name}.app" and r.get("status") == "active":
                existing = r
                break

        if existing:
            existing["libraryMigrations"].extend(data["records"])
        else:
            manifest.append({
                "id": f"migrate-{app_name}-{datetime.now().strftime('%Y%m%d%H%M%S')}",
                "appName": f"{app_name}.app",
                "bundleIdentifier": data["bid"],
                "originalPath": f"/Applications/{app_name}.app",
                "externalPath": f"/Applications/{app_name}.app",
                "symlinkPath": f"/Applications/{app_name}.app",
                "libraryMigrations": data["records"],
                "migratedAt": datetime.now().isoformat() + "Z",
                "status": "active"
            })

    save_manifest(manifest)

    # Also register the manual Claude vm_bundles symlink if it exists and isn't tracked
    claude_vm = HOME / "Library/Application Support/Claude/vm_bundles"
    if claude_vm.is_symlink():
        already_tracked = any(
            any(l["originalPath"] == str(claude_vm) for l in r.get("libraryMigrations", []))
            for r in manifest
        )
        if not already_tracked:
            target = os.readlink(str(claude_vm))
            size = get_dir_size(claude_vm)
            # Find or create Claude record
            claude_record = None
            for r in manifest:
                if "Claude" in r.get("appName", "") and r.get("status") == "active":
                    claude_record = r
                    break

            if claude_record:
                claude_record["libraryMigrations"].append({
                    "category": "Application Support (subdir)",
                    "originalPath": str(claude_vm),
                    "externalPath": target,
                    "sizeBytes": size,
                    "isSymlinked": True
                })
            else:
                manifest.append({
                    "id": f"migrate-Claude-manual",
                    "appName": "Claude.app",
                    "bundleIdentifier": "com.anthropic.claudefordesktop",
                    "originalPath": "/Applications/Claude.app",
                    "externalPath": "/Applications/Claude.app",
                    "symlinkPath": "/Applications/Claude.app",
                    "libraryMigrations": [{
                        "category": "Application Support (subdir)",
                        "originalPath": str(claude_vm),
                        "externalPath": target,
                        "sizeBytes": size,
                        "isSymlinked": True
                    }],
                    "migratedAt": datetime.now().isoformat() + "Z",
                    "status": "active"
                })
            save_manifest(manifest)
            print(f"\n  ℹ️  Also registered existing Claude/vm_bundles symlink in manifest.")

    # Summary
    total_moved = sum(
        r["sizeBytes"]
        for data in migrated_by_app.values()
        for r in data["records"]
    )

    print(f"\n  ─────────────────────────────────────────────")
    print(f"  ✅ Migrated {human_size(total_moved)} to external drive.")
    print(f"  Run 'python3 sidecar_status.py' to see current state.")
    print()


if __name__ == "__main__":
    main()
