# Installation Guide

## Prerequisites

- **macOS 14 or later** (Sonoma, Sequoia)
- **External USB4 or Thunderbolt drive** formatted as APFS or Mac OS Extended (HFS+)
- **Xcode Command Line Tools**

If you haven't installed the command line tools:
```bash
xcode-select --install
```

## Quick Install

```bash
git clone https://github.com/sofa-king-secure/sidecar.git
cd sidecar
chmod +x build-app.sh install.sh uninstall.sh
./install.sh
```

The installer will ask if you want to start Sidecar at login. Say **y** to have it run automatically.

## Grant Permissions

After installing, you need to grant Full Disk Access:

1. Open **System Settings**
2. Go to **Privacy & Security → Full Disk Access**
3. Click the **+** button
4. Navigate to **/Applications/Sidecar.app** and click Open
5. Toggle it **on**

## First Launch

```bash
open /Applications/Sidecar.app
```

On first launch, a setup wizard appears:

1. **Welcome** — Overview of what Sidecar does
2. **Drive Selection** — Pick your external drive (must be APFS or HFS+)
3. **System Check** — Verifies permissions and shows disk usage
4. **Done** — Setup is complete

After setup, the wizard closes and Sidecar runs in your **menu bar**. Look for the drive icon near your clock.

## Migrating Data

1. Click the Sidecar icon in the menu bar
2. Click **Scan & Migrate...**
3. A checklist window appears showing all migratable items with sizes
4. Check/uncheck the items you want to move
5. Click **Migrate Selected**
6. Close the affected apps first when prompted

## Checking Status

1. Click the Sidecar icon in the menu bar
2. Click **View Status & Health...**
3. The dashboard shows all migrations with health indicators:
   - 🟢 **Healthy** — Symlink is working
   - 🟡 **Drive Off** — External drive not connected
   - 🟠 **Replaced** — App recreated the directory
   - 🔴 **Missing** — Symlink or target is gone

## Updating

```bash
cd ~/GitProj/sidecar  # or wherever you cloned it
git pull
./install.sh
```

## Uninstalling

```bash
cd ~/GitProj/sidecar
./uninstall.sh
```

This removes the app, LaunchAgent, and configuration. It does **not** remove:
- Migrated data on your external drive
- Symlinks in ~/Library

The uninstaller will warn you about any active migrations and give you the option to keep or remove the manifest.

## Troubleshooting

**Sidecar icon doesn't appear in menu bar**
- Check that Sidecar.app is running: `ps aux | grep Sidecar`
- Try launching manually: `/Applications/Sidecar.app/Contents/MacOS/Sidecar`

**"Permission denied" during migration**
- Ensure Full Disk Access is granted to Sidecar.app
- Check external drive permissions: `ls -la /Volumes/YourDrive/`
- Fix with: `sudo chown -R $(whoami) /Volumes/YourDrive/Library/`

**App doesn't work after migration**
- The app may not tolerate symlinked subdirectories
- Use `python3 sidecar_migrate.py` to check what was moved
- Rollback: use `python3 rollback.py` or manually:
  ```bash
  rm ~/Library/Application\ Support/AppName/broken_subdir
  mv /Volumes/Drive/Library/AppName/broken_subdir ~/Library/Application\ Support/AppName/
  ```

**Launch at Login checkbox doesn't sync**
- Kill and relaunch Sidecar — it checks the actual LaunchAgent file on startup
- Manually check: `ls ~/Library/LaunchAgents/com.projectsidecar.app.plist`
