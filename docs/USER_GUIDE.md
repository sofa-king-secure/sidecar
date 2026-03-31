# User Guide

## What Sidecar Does

Sidecar saves space on your Mac's internal drive by moving heavy application data folders to an external drive. It creates invisible symbolic links so apps find their data in the expected location — they don't know anything changed.

Your apps stay in `/Applications`. Only the bulky data subdirectories inside `~/Library/Application Support/` and `~/Library/Caches/` get moved.

## The Menu Bar

Sidecar lives in your menu bar as a small drive icon. The icon changes based on status:

| Icon | Meaning |
|------|---------|
| Drive with checkmark | Active — external drive connected, monitoring |
| Drive with X | Drive missing — external drive not connected |
| Drive with ? | Scanning |
| Drive with + | Setup required |

## Scanning & Migrating

Click **Scan & Migrate** to find migratable data:

1. Sidecar scans every third-party app in `/Applications`
2. For each app, it looks inside `~/Library/Application Support/{app}/` for subdirectories larger than 10 MB
3. It also checks `~/Library/Caches/{app}` folders
4. Results appear in a checklist window grouped by app
5. Check the items you want to move, uncheck what you want to keep local
6. Click **Migrate Selected**

Items that are already on the external drive won't appear in the list.

## Viewing Status

Click **View Status & Health** to see:

- **Drive status** — Connected or disconnected, with total data on external drive
- **Disk usage** — Visual bar showing internal drive usage percentage
- **Per-app breakdown** — Each migrated app with its items listed
- **Health indicators** — Per-item status showing whether symlinks are healthy
- **History** — Previously rolled-back migrations

## Settings

### Auto-prompt for new apps
When enabled, Sidecar will prompt you whenever a new app is installed in `/Applications`, offering to migrate its data. When disabled, you control everything manually through Scan & Migrate.

### Launch at login
When enabled, Sidecar starts automatically when you log in and runs silently in the menu bar. When disabled, you need to launch it manually.

## What Happens When the Drive Is Disconnected

This is the most important thing to understand:

1. **Sidecar detects the disconnect** and replaces dead symlinks with empty placeholder directories
2. **Your apps can still launch** — they just don't have access to the offloaded data
3. **If you launch a migrated app**, Sidecar shows a warning dialog with two options:
   - **Quit the app** and connect the drive
   - **Continue without data** — the app runs in a degraded state
4. **When the drive reconnects**, Sidecar restores the symlinks automatically

Your core app functionality is never broken. Settings, login state, and preferences stay on the internal drive. Only caches, VM bundles, and large data directories are affected.

## What Can and Can't Be Migrated

### Works well
- Application Support subdirectories (caches, VMs, code indexes)
- ~/Library/Caches folders (regenerable by the app)
- ~/Library/Logs folders

### Doesn't work
- The .app bundle itself — macOS blocks launching symlinked apps from external drives
- The parent Application Support folder — Electron apps reject this
- ~/Library/Containers — sandboxed apps check real paths
- Anything under 10 MB — not worth the overhead

### Tested apps
| App | What moves | Size saved | Works without drive? |
|-----|-----------|------------|---------------------|
| Claude Desktop | vm_bundles, claude-code-vm, claude-code, Cache, Code Cache | ~13.5 GB | Yes — chat works, Claude Code features unavailable |
| Firefox | Caches/Firefox, Profiles | ~1.3 GB | Not tested yet |

## Rollback

If something breaks after migration, you can restore data to the internal drive:

**Using the CLI tool:**
```bash
python3 rollback.py
```

**Manually for a single item:**
```bash
# Remove the symlink
rm ~/Library/Application\ Support/AppName/broken_item

# Move data back from external drive
mv /Volumes/YourDrive/Library/AppName/broken_item ~/Library/Application\ Support/AppName/
```

## Tips

- **Close apps before migrating their data** — moving files while an app is using them can cause errors
- **Start with one app** to test before migrating everything
- **Check status after reconnecting** your drive to make sure everything is green
- **Keep the drive connected** for best performance — symlinked data is read from the external drive, which may be slower than internal SSD
