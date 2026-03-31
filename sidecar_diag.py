#!/usr/bin/env python3
"""
Sidecar Diagnostic Script v2
Scans your system to find where app data actually lives.
"""

import os
import subprocess
import json
from pathlib import Path

HOME = Path.home()
LIBRARY = HOME / "Library"
APPS_DIR = Path("/Applications")

def get_size(path):
    """Get total size of a file or directory in bytes."""
    path_str = str(path)
    if os.path.isfile(path_str) and not os.path.islink(path_str):
        try:
            return os.path.getsize(path_str)
        except:
            return 0
    if not os.path.isdir(path_str):
        return 0
    total = 0
    try:
        for root, dirs, files in os.walk(path_str, followlinks=False):
            for f in files:
                try:
                    total += os.path.getsize(os.path.join(root, f))
                except:
                    pass
    except PermissionError:
        pass
    return total

def human_size(size_bytes):
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size_bytes < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} TB"

def get_bundle_id(app_path):
    plist = app_path / "Contents" / "Info.plist"
    if not plist.exists():
        return None
    try:
        result = subprocess.run(
            ["defaults", "read", str(plist), "CFBundleIdentifier"],
            capture_output=True, text=True
        )
        return result.stdout.strip() if result.returncode == 0 else None
    except:
        return None

def is_apple_app(bundle_id):
    if not bundle_id:
        return False
    return bundle_id.startswith("com.apple.")

def main():
    print("=" * 60)
    print("SIDECAR DIAGNOSTIC REPORT")
    print("=" * 60)

    print("\n--- Third-Party Apps in /Applications ---\n")
    apps = []
    for item in sorted(APPS_DIR.iterdir()):
        if not item.name.endswith(".app"):
            continue
        if item.is_symlink():
            print(f"  [SYMLINK] {item.name} -> {os.readlink(item)}")
            continue
        bundle_id = get_bundle_id(item)
        if is_apple_app(bundle_id):
            continue
        if str(item).startswith("/System"):
            continue
        if bundle_id == "com.projectsidecar.app":
            continue
        size = get_size(item)
        apps.append((item.name, bundle_id, size))
        print(f"  {item.name}")
        print(f"    Bundle ID: {bundle_id or 'UNKNOWN'}")
        print(f"    App size:  {human_size(size)}")

    print("\n--- Library Data Per App ---\n")

    lib_dirs = [
        "Application Support",
        "Caches",
        "Containers",
        "Group Containers",
        "Preferences",
        "Saved Application State",
        "Logs",
        "HTTPStorages",
        "WebKit",
    ]

    for app_name, bundle_id, app_size in apps:
        base_name = app_name.replace(".app", "")
        search_terms = [base_name]
        if bundle_id:
            search_terms.append(bundle_id)
            parts = bundle_id.split(".")
            if len(parts) >= 2:
                search_terms.append(parts[-1])
                if len(parts) >= 3:
                    search_terms.append(".".join(parts[-2:]))

        print(f"  {app_name} (bundle: {bundle_id})")
        print(f"    Search terms: {search_terms}")

        total_lib_size = 0
        found_any = False

        for lib_dir_name in lib_dirs:
            lib_dir = LIBRARY / lib_dir_name
            if not lib_dir.exists():
                continue

            try:
                for entry in lib_dir.iterdir():
                    entry_name = entry.name
                    matched = False
                    matched_term = None

                    for term in search_terms:
                        if term.lower() in entry_name.lower():
                            matched = True
                            matched_term = term
                            break

                    if matched:
                        is_link = entry.is_symlink()
                        size = get_size(entry) if not is_link else 0
                        total_lib_size += size
                        found_any = True
                        link_marker = " [SYMLINK]" if is_link else ""
                        print(f"    ✅ {lib_dir_name}/{entry_name} = {human_size(size)}{link_marker} (matched: '{matched_term}')")
            except PermissionError:
                print(f"    ⚠️  {lib_dir_name}: Permission denied")

        if not found_any:
            print(f"    ❌ No Library data found!")

        print(f"    TOTAL: App={human_size(app_size)} + Library={human_size(total_lib_size)} = {human_size(app_size + total_lib_size)}")
        meets_lib = total_lib_size >= 50_000_000
        print(f"    Library alone >= 50MB: {'YES ✅' if meets_lib else 'NO ❌  <-- THIS IS WHY SIDECAR SKIPS IT'}")
        print()

    print("\n--- Top 20 Biggest ~/Library/Application Support ---\n")
    app_support = LIBRARY / "Application Support"
    if app_support.exists():
        sizes = []
        for entry in app_support.iterdir():
            if entry.name.startswith("."):
                continue
            size = get_size(entry)
            sizes.append((entry.name, size, entry.is_symlink()))
        sizes.sort(key=lambda x: x[1], reverse=True)
        for name, size, is_link in sizes[:20]:
            marker = " [SYMLINK]" if is_link else ""
            print(f"  {human_size(size):>10}  {name}{marker}")

    print("\n--- Top 10 Biggest ~/Library/Containers ---\n")
    containers = LIBRARY / "Containers"
    if containers.exists():
        sizes = []
        for entry in containers.iterdir():
            if entry.name.startswith("."):
                continue
            size = get_size(entry)
            sizes.append((entry.name, size))
        sizes.sort(key=lambda x: x[1], reverse=True)
        for name, size in sizes[:10]:
            print(f"  {human_size(size):>10}  {name}")

    print("\n--- Top 10 Biggest ~/Library/Group Containers ---\n")
    group = LIBRARY / "Group Containers"
    if group.exists():
        sizes = []
        for entry in group.iterdir():
            if entry.name.startswith("."):
                continue
            size = get_size(entry)
            sizes.append((entry.name, size))
        sizes.sort(key=lambda x: x[1], reverse=True)
        for name, size in sizes[:10]:
            print(f"  {human_size(size):>10}  {name}")

    print("\n--- Sidecar State ---\n")
    manifest_path = HOME / "Library/Application Support/ProjectSidecar/manifest.json"
    if manifest_path.exists():
        with open(manifest_path) as f:
            records = json.load(f)
        active = [r for r in records if r.get("status") == "active"]
        print(f"  Total records: {len(records)}")
        print(f"  Active migrations: {len(active)}")
    else:
        print("  No manifest found.")

    config_path = HOME / "Library/Application Support/ProjectSidecar/config.json"
    if config_path.exists():
        with open(config_path) as f:
            config = json.load(f)
        prefs = config.get("preferences", {})
        print(f"  Volume: {config.get('configuredVolumeName', 'NOT SET')}")
        print(f"  Min size MB: {prefs.get('minimumAppSizeMB', '?')}")
        print(f"  Migrate library: {prefs.get('migrateLibraryData', '?')}")

    print("\n" + "=" * 60)
    print("END OF DIAGNOSTIC REPORT")
    print("=" * 60)

if __name__ == "__main__":
    main()
