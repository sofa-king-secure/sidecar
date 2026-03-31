# Sidecar

<p align="center">
  <img src="Resources/AppIcon.png" alt="Sidecar" width="200" />
</p>

<p align="center">
  <strong>Keep your Mac's internal drive clean.</strong><br>
  Automatically offload heavy application data to an external USB4 drive using symbolic links — saving gigabytes without breaking your apps.
</p>

---

## How It Works

macOS apps store large amounts of data in `~/Library` — caches, VM bundles, code indexes, profiles. On a 256GB MacBook, this adds up fast. Sidecar moves the heaviest subdirectories to your external drive and creates symlinks so apps find their data exactly where they expect it.

**What moves:** Heavy subdirectories *inside* `~/Library/Application Support/{app}/`, plus `~/Library/Caches/{app}` folders.

**What stays:** The `.app` bundle, the parent Application Support folder, preferences, and config files. macOS Launch Services and app sandboxing remain happy.

**When the drive is disconnected:** Apps launch normally. They just don't see the offloaded data (caches rebuild, VMs reload on reconnect). Sidecar detects the disconnect and warns you if you launch a migrated app.

### Example: Claude Desktop

| Item | Size | Location |
|------|------|----------|
| Claude.app | 930 MB | /Applications *(stays)* |
| Claude/vm_bundles | 12.9 GB | External drive *(symlinked)* |
| Claude/claude-code-vm | 228 MB | External drive *(symlinked)* |
| Claude/claude-code | 197 MB | External drive *(symlinked)* |
| Claude/Cache | 155 MB | External drive *(symlinked)* |

**Result:** 13.5 GB freed from internal drive. Claude works identically.

---

## Features

- **Per-item migration picker** — Choose exactly which data folders to move. Never all-or-nothing.
- **Status dashboard** — See every migration, symlink health, sizes, and drive connection status at a glance.
- **Disconnect safety** — Dead symlinks are replaced with empty placeholders. Apps launch without crashing. Data syncs back on reconnect.
- **App monitoring** — Watches `/Applications` for new installs and offers to migrate their data.
- **Rollback** — Every migration is recorded in a manifest. Undo any migration to restore data locally.
- **Launch at Login** — Runs silently in the menu bar, starts automatically when you log in.
- **No Dock icon** — Lives entirely in the menu bar. Clean and unobtrusive.

---

## Requirements

- macOS 14+ (Sonoma, Sequoia, or later)
- External USB4/Thunderbolt drive formatted as **APFS** or **Mac OS Extended (HFS+)**
- Xcode Command Line Tools (`xcode-select --install`)

---

## Installation

```bash
# Clone
git clone https://github.com/sofa-king-secure/sidecar.git
cd sidecar

# Build and install
chmod +x build-app.sh install.sh
./install.sh
```

The installer will:
1. Build a release binary
2. Create `Sidecar.app` with the app icon
3. Copy it to `/Applications`
4. Optionally set up Launch at Login

After installing, grant Full Disk Access:

**System Settings → Privacy & Security → Full Disk Access → + → select Sidecar.app**

Then launch:
```bash
open /Applications/Sidecar.app
```

---

## Usage

### First Launch

A setup wizard walks you through:
1. Selecting your external drive
2. Verifying system permissions
3. Completing configuration

After setup, Sidecar runs in the **menu bar** (look for the drive icon near your clock).

### Menu Bar

| Action | What it does |
|--------|-------------|
| **Scan & Migrate** | Scans all apps, shows a checklist of migratable items with sizes. Pick which ones to move. |
| **View Status & Health** | Dashboard showing all migrations, symlink health (green/yellow/red), sizes, and drive status. |
| **Settings → Auto-prompt** | Toggle automatic prompts when new apps are installed. |
| **Settings → Launch at login** | Start Sidecar automatically at login. |

### What Gets Scanned

Sidecar looks inside `~/Library/Application Support/{app}/` for subdirectories larger than 10 MB, and checks `~/Library/Caches/{app}` folders. Items under 10 MB are skipped — not worth the symlink overhead.

### What Doesn't Get Migrated

- Apple system apps
- The `.app` bundle itself (macOS blocks symlinked app bundles)
- The parent Application Support folder (Electron apps reject symlinked parents)
- Sandboxed Containers (`~/Library/Containers/`) — these reject symlinks
- Sidecar itself

---

## Project Structure

```
sidecar/
├── Sources/ProjectSidecar/
│   ├── SidecarApp.swift          # App entry point, menu bar, state
│   ├── OnboardingView.swift      # First-run setup wizard
│   ├── MigrationPickerView.swift # Per-item migration checklist
│   ├── StatusView.swift          # Migration dashboard & health checks
│   ├── LibraryScanner.swift      # Scans inside ~/Library for heavy subdirs
│   ├── AppMigrator.swift         # Moves data + creates symlinks
│   ├── MigrationManifest.swift   # Tracks migrations for rollback
│   ├── DisconnectGuard.swift     # Drive disconnect safety system
│   ├── AppFilter.swift           # Excludes Apple/system/self apps
│   ├── DirectoryMonitor.swift    # FSEvents watcher for /Applications
│   ├── VolumeMonitor.swift       # External drive mount/unmount detection
│   ├── DriveSetup.swift          # Drive discovery & filesystem validation
│   ├── DiskAnalyzer.swift        # Internal drive usage stats
│   └── SidecarConfig.swift       # Persistent configuration
├── Tests/ProjectSidecarTests/
├── Resources/
│   └── AppIcon.png               # Application icon
├── build-app.sh                  # Builds .app bundle with icon
├── install.sh                    # Build + install + LaunchAgent setup
├── uninstall.sh                  # Clean removal
├── sidecar_migrate.py            # CLI migration tool (alternative to GUI)
├── sidecar_status.py             # CLI status checker
└── Package.swift
```

---

## How Migration Works

```
1. Scan    ~/Library/Application Support/Claude/
           ├── vm_bundles/        → 12.9 GB  ← migrate this
           ├── claude-code-vm/    → 228 MB   ← migrate this
           ├── Cache/             → 155 MB   ← migrate this
           ├── config.json        → 1 KB     ← too small, skip
           └── Cookies            → 28 KB    ← too small, skip

2. Move    vm_bundles/ → /Volumes/ExtDrive/Library/Claude/vm_bundles/

3. Symlink ~/Library/Application Support/Claude/vm_bundles
           → /Volumes/ExtDrive/Library/Claude/vm_bundles

4. Record  manifest.json tracks original path, external path, size

5. Verify  Symlink points to valid target ✅
```

---

## Drive Disconnect Behavior

| Scenario | What happens |
|----------|-------------|
| Drive connected | App uses data from external drive via symlink. Normal operation. |
| Drive disconnected while app running | App may lose access to cached data. Core functionality works. |
| App launched without drive | App starts normally. Offloaded data unavailable. Sidecar warns you. |
| Drive reconnected | Symlinks automatically resolve. Data accessible again. |

---

## Configuration Files

| File | Purpose |
|------|---------|
| `~/Library/Application Support/ProjectSidecar/config.json` | Drive config, preferences |
| `~/Library/Application Support/ProjectSidecar/manifest.json` | Migration records |
| `~/Library/LaunchAgents/com.projectsidecar.app.plist` | Launch at Login agent |
| `/Volumes/{Drive}/Library/{App}/` | Migrated data on external drive |

---

## CLI Tools

For users who prefer the command line:

```bash
# Interactive migration with per-item selection
python3 sidecar_migrate.py

# Status overview
python3 sidecar_status.py
```

---

## Uninstalling

```bash
chmod +x uninstall.sh
./uninstall.sh
```

Removes the app, LaunchAgent, config, and logs. Does **not** remove migrated data on the external drive or symlinks in ~/Library (warns you about these).

---

## Key Design Decisions

**Why not symlink the .app bundle?** macOS Launch Services refuses to open apps via symlinks to external volumes (error -10657).

**Why not symlink the entire Application Support folder?** Electron apps (Claude, VS Code, Teams) check the real path of their support directory and refuse to launch if it's a symlink.

**Why symlink subdirectories inside Application Support?** Apps see a real parent folder (passes sandbox checks) but the heavy data inside is on the external drive. Apps degrade gracefully when the drive is disconnected.

---

## License

MIT — see [LICENSE](LICENSE) for details.
