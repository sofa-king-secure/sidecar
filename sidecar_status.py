#!/usr/bin/env python3
"""
Sidecar Status Check
Shows a clean overview of current state: migrations, symlinks, sizes, health.
"""

import os
import json
import shutil
from pathlib import Path
from datetime import datetime

HOME = Path.home()
MANIFEST = HOME / "Library/Application Support/ProjectSidecar/manifest.json"
CONFIG = HOME / "Library/Application Support/ProjectSidecar/config.json"

def human_size(size_bytes):
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size_bytes < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} TB"

def get_dir_size(path):
    total = 0
    try:
        for root, dirs, files in os.walk(str(path), followlinks=True):
            for f in files:
                try:
                    total += os.path.getsize(os.path.join(root, f))
                except:
                    pass
    except:
        pass
    return total

def main():
    print()
    print("┌─────────────────────────────────────────────────────────┐")
    print("│              SIDECAR STATUS CHECK                       │")
    print("└─────────────────────────────────────────────────────────┘")

    # Disk state
    internal = shutil.disk_usage(str(HOME))
    print(f"\n  💾 Internal Drive")
    print(f"     {human_size(internal.used)} used / {human_size(internal.total)} total ({human_size(internal.free)} free)")

    # Find external drive
    ext_drive = None
    if CONFIG.exists():
        with open(CONFIG) as f:
            config = json.load(f)
        vol_name = config.get("configuredVolumeName", "")
        ext_path = Path(f"/Volumes/{vol_name}")
        if ext_path.exists():
            ext = shutil.disk_usage(str(ext_path))
            ext_drive = ext_path
            print(f"\n  🔌 External Drive: {vol_name} (CONNECTED)")
            print(f"     {human_size(ext.used)} used / {human_size(ext.total)} total ({human_size(ext.free)} free)")
        else:
            print(f"\n  ⚠️  External Drive: {vol_name} (DISCONNECTED)")
    else:
        print("\n  ❌ No Sidecar configuration found.")
        return

    # Migration records
    if not MANIFEST.exists():
        print("\n  📋 No migrations recorded yet.")
        print()
        return

    with open(MANIFEST) as f:
        records = json.load(f)

    active = [r for r in records if r.get("status") == "active"]
    rolled_back = [r for r in records if r.get("status") == "rolledBack"]

    print(f"\n  📋 Migrations: {len(active)} active, {len(rolled_back)} rolled back")

    if not active:
        print("     No active migrations.")
        print()
        return

    # Per-app breakdown
    total_migrated = 0
    total_items = 0

    for record in active:
        app_name = record["appName"].replace(".app", "")
        libs = record.get("libraryMigrations", [])
        symlinked = [l for l in libs if l.get("isSymlinked")]

        if not symlinked:
            continue

        app_size = sum(l.get("sizeBytes", 0) for l in symlinked)
        total_migrated += app_size
        total_items += len(symlinked)

        migrated_at = record.get("migratedAt", "unknown")
        try:
            dt = datetime.fromisoformat(migrated_at.replace("Z", "+00:00"))
            migrated_at = dt.strftime("%b %d, %Y %I:%M %p")
        except:
            pass

        print(f"\n  ┌── {app_name} ({human_size(app_size)} on external)")
        print(f"  │   Migrated: {migrated_at}")

        for lib in symlinked:
            orig = lib["originalPath"]
            ext = lib["externalPath"]
            size = lib.get("sizeBytes", 0)
            category = lib.get("category", "")

            # Check symlink health
            is_symlink = os.path.islink(orig)
            if is_symlink:
                target = os.readlink(orig)
                target_exists = os.path.exists(target)
                if target_exists:
                    status = "✅"
                    # Get actual current size
                    actual_size = get_dir_size(orig)
                    size_str = human_size(actual_size)
                else:
                    status = "⚠️  (drive disconnected)"
                    size_str = human_size(size) + " (last known)"
            elif os.path.exists(orig):
                status = "🔄 (placeholder — drive was disconnected)"
                size_str = "placeholder"
            else:
                status = "❌ MISSING"
                size_str = "—"

            short_path = orig.replace(str(HOME), "~")
            print(f"  │   {status} {os.path.basename(orig)}")
            print(f"  │      Local: {short_path}")
            print(f"  │      Size:  {size_str}")

        print(f"  └──")

    print(f"\n  ─────────────────────────────────────────────")
    print(f"  Total: {total_items} item(s), {human_size(total_migrated)} on external drive")

    # Space saved
    print(f"  Space saved on internal: ~{human_size(total_migrated)}")
    print()

if __name__ == "__main__":
    main()
