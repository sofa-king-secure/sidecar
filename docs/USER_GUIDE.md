# Project Sidecar — User Guide

## What is Sidecar?

Sidecar is a macOS menu bar utility that keeps your internal drive clean by automatically migrating third-party applications and their data to an external USB4 drive. It replaces the originals with invisible symbolic links so everything continues to work normally — apps launch from the same place, Spotlight finds them, updates work — but the actual files live on your external drive.

---

## First Launch (Setup Wizard)

When you run Sidecar for the first time, a setup wizard walks you through configuration:

1. **Welcome** — Overview of what Sidecar does.
2. **Drive Selection** — Sidecar scans for connected external drives. Select the one you want to use. The drive must be formatted as **APFS** or **Mac OS Extended (HFS+)**. ExFAT, FAT32, and NTFS drives will appear but cannot be selected (they don't support macOS symlinks or file permissions).
3. **System Check** — Verifies that Terminal/Sidecar has **Full Disk Access** (required to move files in /Applications), and shows your current internal drive usage.
4. **Initial Scan** — Scans all installed third-party apps and their ~/Library data, then shows candidates ranked by size. You can select which ones to migrate now or skip and let Sidecar handle future installs.
5. **Start Sidecar** — Completes setup. The wizard window closes and Sidecar runs as a **menu bar icon** (the external drive icon near your clock).

---

## Menu Bar Interface

After setup, Sidecar lives entirely in your menu bar. Click the drive icon to see:

- **Status** — Active (drive mounted, monitoring), Drive Missing (drive disconnected), Scanning.
- **Disk info** — How much free space is on your internal drive.
- **Migrated count** — How many apps have been moved.
- **Scan & Recommend** — Manually scan all apps and get migration recommendations.
- **Health Check** — Verify all symlinks are intact.
- **Settings** — Toggle preferences (see below).
- **Quit** — Stop Sidecar.

---

## Settings Explained

### Auto-migrate new apps
**Default: ON**

When ON: Every time you install a new third-party app in /Applications, Sidecar detects it, scans its full footprint (app bundle + Library data), and prompts you to migrate it if it's above the size threshold (50 MB).

When OFF: Sidecar still monitors /Applications but stays silent. You control migrations manually via "Scan & Recommend" in the menu bar. Use this if you prefer to batch-migrate on your own schedule rather than being prompted after every install.

**Toggling it back ON** resumes automatic detection prompts immediately. Nothing is lost — it just controls whether you get prompted or not.

### Migrate Library data
**Default: ON**

When ON: Sidecar moves not just the .app bundle but also associated data in ~/Library — Application Support folders, Caches, Saved State, Logs, WebKit data, and more. This is where the real space savings are. A 500 MB app might have 5 GB of Library data.

When OFF: Sidecar only moves the .app bundle itself and creates a symlink. Library data stays on your internal drive. Use this if you're concerned about compatibility or if a specific app breaks after migration.

**Toggling it back ON** applies to future migrations only — it does not retroactively migrate Library data for apps already moved. Run "Scan & Recommend" to pick up anything that was missed.

### Launch at login
**Default: OFF**

**Note: This setting is not yet functional (v0.1).** Toggling it saves the preference but does not currently register a Launch Agent. In a future update, turning this on will create a LaunchAgent plist so Sidecar starts automatically when you log in.

For now, to start Sidecar you need to run it manually:
```bash
cd ~/Developer/sidecar
swift run ProjectSidecar
```

---

## How Migration Works

When Sidecar migrates an app, here's exactly what happens:

1. **Scan** — Reads the app's bundle identifier from its Info.plist, then searches 9 directories in ~/Library for matching data (Application Support, Containers, Group Containers, Caches, Preferences, Saved Application State, Logs, HTTPStorages, WebKit).

2. **Score** — Calculates a priority score (0-100) based on total footprint size, how much is Library data vs. app bundle, and current disk pressure. Apps under 50 MB total are skipped.

3. **Move** — Uses macOS FileManager to move the .app bundle to your external drive's /Applications folder. Preserves all file attributes and permissions.

4. **Symlink** — Creates a symbolic link at the original location (/Applications/AppName.app) pointing to the external drive copy. macOS treats this transparently — Spotlight, Launchpad, and the Dock all work normally.

5. **Library data** — For safe categories (Application Support, Caches, Logs, etc.), moves the folder and creates a symlink. For sandboxed containers (~/Library/Containers), copies the data as a backup but leaves the original in place (sandboxed apps reject symlinked containers).

6. **Record** — Saves a manifest entry in ~/Library/Application Support/ProjectSidecar/manifest.json tracking every file that was moved, so it can be rolled back.

---

## What Gets Migrated (and What Doesn't)

### Always migrated (if above size threshold)
- The .app bundle itself
- ~/Library/Application Support/{app name or bundle ID}
- ~/Library/Caches/{bundle ID} (if enabled)
- ~/Library/Saved Application State/{bundle ID}
- ~/Library/Logs/{app name or bundle ID}
- ~/Library/HTTPStorages/{bundle ID}
- ~/Library/WebKit/{bundle ID}

### Copied but not symlinked
- ~/Library/Containers/{bundle ID} — Sandboxed apps check the real path; symlinks break them. Sidecar copies this data to the external drive as a backup but leaves the original.
- ~/Library/Group Containers/ — Same reason.

### Never touched
- Apple/system apps (/System/Applications, anything signed by Apple)
- Apps under 50 MB total footprint
- ~/Library/Preferences/*.plist files under 1 MB (tiny config files, not worth it)

---

## Rollback

Every migration can be undone. If an app breaks after migration, or you want to bring it back to the internal drive:

1. The manifest at ~/Library/Application Support/ProjectSidecar/manifest.json tracks every move.
2. Rollback (coming in a future UI update) moves the app and all Library data back to their original locations and removes the symlinks.
3. You can also manually undo a migration:
```bash
# Remove the symlink
rm /Applications/AppName.app

# Move the app back from external drive
mv /Volumes/YourDrive/Applications/AppName.app /Applications/

# Do the same for any Library symlinks
```

---

## Health Check

Sidecar monitors the integrity of all migrations:

- **Runs automatically** when your external drive reconnects (if "Run health check on mount" is enabled).
- **Run manually** from the menu bar via "Health Check".

It detects three problems:

1. **Symlink missing** — The symlink in /Applications was deleted entirely.
2. **Target unreachable** — The symlink exists but the external drive isn't mounted (just means you need to plug it in).
3. **Updater replaced symlink** — An app update (via App Store or Sparkle) deleted the symlink and installed a fresh copy. Sidecar alerts you so you can re-migrate.

---

## Troubleshooting

### "Failed to set up drive: permission denied"
Grant Full Disk Access to Terminal (System Settings → Privacy & Security → Full Disk Access), and ensure your external drive is writable:
```bash
sudo chown -R $(whoami) /Volumes/YourDriveName/
```

### App won't launch after migration
The external drive must be connected. If it's not, symlinks point to nothing and the app won't start. Plug the drive in and try again. If the app still fails, it may be a sandboxed app that rejects symlinked containers — roll back the migration.

### Sidecar doesn't detect new apps
Make sure Sidecar is running (check for the drive icon in the menu bar) and "Auto-migrate new apps" is enabled in Settings. The app must be installed in /Applications — apps in ~/Applications or other locations are not monitored.

### "No apps meet the migration threshold"
Your installed apps are all under 50 MB total footprint, or your disk has enough free space that Sidecar doesn't see urgency. You can lower the threshold in a future settings update.

---

## File Locations

| File | Purpose |
|------|---------|
| ~/Library/Application Support/ProjectSidecar/config.json | Settings, drive history, onboarding state |
| ~/Library/Application Support/ProjectSidecar/manifest.json | Migration records for rollback |
| /Volumes/{YourDrive}/.sidecar-meta/sidecar.json | Drive marker (identifies Sidecar drives) |
| /Volumes/{YourDrive}/Applications/ | Migrated app bundles |
| /Volumes/{YourDrive}/Library/ | Migrated Library data |

---

## Current Limitations (v0.1)

- **No settings UI for thresholds** — The 50 MB minimum and 30 GB target free space are hardcoded. A settings panel is planned.
- **Launch at login not functional** — The toggle saves the preference but doesn't register a LaunchAgent yet.
- **No rollback UI** — Rollback requires manual file operations or editing the manifest. A UI is planned.
- **Single drive only** — Sidecar supports one external drive at a time.
- **No periodic container sync** — Sandboxed container backups are one-time copies, not continuously synced.
