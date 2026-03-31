#!/usr/bin/env python3
"""
Sidecar Direct Migration Script
Migrates Library data for Claude and Firefox to external drive.
Bypasses the Sidecar app UI to prove the concept works.
"""

import os
import sys
import json
import shutil
from pathlib import Path
from datetime import datetime

HOME = Path.home()
LIBRARY = HOME / "Library"
MANIFEST_PATH = HOME / "Library/Application Support/ProjectSidecar/manifest.json"
CONFIG_PATH = HOME / "Library/Application Support/ProjectSidecar/config.json"

# Detect external drive
EXTERNAL_CANDIDATES = [
    Path("/Volumes/ExtApplications"),
    Path("/Volumes/ExtApplications 1"),
]

def find_external_drive():
    for p in EXTERNAL_CANDIDATES:
        if p.exists() and p.is_mount():
            return p
    # Try any non-system volume
    volumes = Path("/Volumes")
    for v in volumes.iterdir():
        if v.name not in ("Macintosh HD", "Macintosh HD - Data") and v.is_mount():
            return v
    return None

def human_size(size_bytes):
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size_bytes < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} TB"

def get_size(path):
    total = 0
    for root, dirs, files in os.walk(str(path), followlinks=False):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except:
                pass
    return total

def migrate_library_item(local_path, external_base, app_name, category):
    """Move a library folder to external drive and create symlink."""
    local = Path(local_path)
    
    if not local.exists():
        print(f"    ⚠️  Not found: {local}")
        return None
    
    if local.is_symlink():
        print(f"    ⏭️  Already symlinked: {local}")
        return None
    
    size = get_size(local)
    if size < 1_000_000:  # Skip < 1MB
        print(f"    ⏭️  Too small ({human_size(size)}): {local.name}")
        return None
    
    # Build external path
    ext_dir = external_base / "Library" / category
    ext_path = ext_dir / local.name
    
    print(f"    📦 Moving {category}/{local.name} ({human_size(size)})...")
    
    # Create external directory
    ext_dir.mkdir(parents=True, exist_ok=True)
    
    # Handle conflict
    if ext_path.exists():
        print(f"    ⚠️  Already exists on external — removing old copy")
        shutil.rmtree(str(ext_path))
    
    # Move
    try:
        shutil.move(str(local), str(ext_path))
    except Exception as e:
        print(f"    ❌ Move failed: {e}")
        return None
    
    # Create symlink
    try:
        os.symlink(str(ext_path), str(local))
    except Exception as e:
        print(f"    ❌ Symlink failed: {e}")
        # Try to move back
        try:
            shutil.move(str(ext_path), str(local))
        except:
            pass
        return None
    
    # Verify
    if local.is_symlink() and os.path.exists(os.readlink(str(local))):
        print(f"    ✅ Done: {local.name} → {ext_path}")
        return {
            "category": category,
            "originalPath": str(local),
            "externalPath": str(ext_path),
            "sizeBytes": size,
            "isSymlinked": True
        }
    else:
        print(f"    ❌ Verification failed!")
        return None


def main():
    print("=" * 60)
    print("SIDECAR DIRECT MIGRATION")
    print("=" * 60)
    
    # Find external drive
    ext_drive = find_external_drive()
    if not ext_drive:
        print("\n❌ No external drive found!")
        sys.exit(1)
    
    print(f"\nExternal drive: {ext_drive}")
    print(f"Internal free:  {human_size(shutil.disk_usage(str(HOME)).free)}")
    print(f"External free:  {human_size(shutil.disk_usage(str(ext_drive)).free)}")
    
    # Define what to migrate
    apps_to_migrate = [
        {
            "name": "Claude.app",
            "bundleID": "com.anthropic.claudefordesktop",
            "items": [
                (LIBRARY / "Application Support/Claude", "Application Support"),
                (LIBRARY / "Caches/com.anthropic.claudefordesktop", "Caches"),
                (LIBRARY / "Logs/Claude", "Logs"),
                (LIBRARY / "HTTPStorages/com.anthropic.claudefordesktop", "HTTPStorages"),
            ]
        },
        {
            "name": "Firefox.app",
            "bundleID": "org.mozilla.firefox",
            "items": [
                (LIBRARY / "Application Support/Firefox", "Application Support"),
                (LIBRARY / "Caches/Firefox", "Caches"),
            ]
        },
    ]
    
    # Show what we'll do
    print("\n--- Migration Plan ---\n")
    total_size = 0
    for app in apps_to_migrate:
        print(f"  {app['name']}:")
        for local_path, category in app["items"]:
            if local_path.exists() and not local_path.is_symlink():
                size = get_size(local_path)
                total_size += size
                print(f"    {category}/{local_path.name}: {human_size(size)}")
            elif local_path.is_symlink():
                print(f"    {category}/{local_path.name}: [already symlinked]")
            else:
                print(f"    {category}/{local_path.name}: [not found]")
    
    print(f"\n  Total to migrate: {human_size(total_size)}")
    
    # Confirm
    print()
    confirm = input("Proceed with migration? (y/n): ").strip().lower()
    if confirm != 'y':
        print("Cancelled.")
        return
    
    # Close apps first
    print("\n⚠️  Make sure Claude and Firefox are CLOSED before continuing!")
    input("Press Enter when ready...")
    
    # Do the migration
    print("\n--- Migrating ---\n")
    
    # Load or create manifest
    manifest = []
    if MANIFEST_PATH.exists():
        with open(MANIFEST_PATH) as f:
            manifest = json.load(f)
    
    for app in apps_to_migrate:
        print(f"\n  {app['name']}:")
        lib_records = []
        
        for local_path, category in app["items"]:
            result = migrate_library_item(local_path, ext_drive, app["name"], category)
            if result:
                lib_records.append(result)
        
        if lib_records:
            # Record in manifest
            record = {
                "id": f"manual-{app['bundleID']}-{datetime.now().strftime('%Y%m%d%H%M%S')}",
                "appName": app["name"],
                "bundleIdentifier": app["bundleID"],
                "originalPath": f"/Applications/{app['name']}",
                "externalPath": f"/Applications/{app['name']}",
                "symlinkPath": f"/Applications/{app['name']}",
                "libraryMigrations": lib_records,
                "migratedAt": datetime.now().isoformat() + "Z",
                "status": "active"
            }
            manifest.append(record)
    
    # Save manifest
    MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(MANIFEST_PATH, 'w') as f:
        json.dump(manifest, f, indent=2)
    print(f"\nManifest saved: {MANIFEST_PATH}")
    
    # Verify
    print("\n--- Verification ---\n")
    print(f"Internal free:  {human_size(shutil.disk_usage(str(HOME)).free)}")
    print(f"External free:  {human_size(shutil.disk_usage(str(ext_drive)).free)}")
    
    print("\nSymlink check:")
    for app in apps_to_migrate:
        for local_path, category in app["items"]:
            if local_path.is_symlink():
                target = os.readlink(str(local_path))
                exists = os.path.exists(target)
                status = "✅" if exists else "❌ BROKEN"
                print(f"  {status} {local_path.name} → {target}")
            elif local_path.exists():
                print(f"  ⏭️  {local_path.name} (not symlinked)")
    
    print("\n" + "=" * 60)
    print("MIGRATION COMPLETE")
    print("Now launch Claude and Firefox to verify they work!")
    print("=" * 60)


if __name__ == "__main__":
    main()
