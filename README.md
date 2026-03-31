# Project Sidecar

> **Keep your Mac's internal drive clean.** Automatically find and move heavy app data subdirectories to an external drive using symbolic links — apps keep working normally.

---

## The Problem

macOS apps store huge amounts of data in `~/Library` — caches, VM bundles, indexes, blobs. Claude Desktop alone stores 12GB+ of VM bundles. These eat your internal drive while the app bundles themselves are relatively small.

## The Solution

Sidecar scans **inside** each app's Library folders for heavy subdirectories and moves them to an external drive, replacing them with symlinks. The parent folder stays real — apps don't notice the difference.

```
~/Library/Application Support/Claude/          ← stays real (local)
~/Library/Application Support/Claude/vm_bundles → /Volumes/ExtDrive/Library/Claude/vm_bundles (12GB)
~/Library/Application Support/Claude/Cache      → /Volumes/ExtDrive/Library/Claude/Cache (146MB)
~/Library/Application Support/Claude/config.json ← stays real (tiny, local)
```

## Why Sub-Directory Symlinks?

We tested three approaches before landing on this one:

| Approach | Result |
|----------|--------|
| Symlink entire `.app` bundle to external | ❌ macOS Launch Services blocks it (error -10657) |
| Symlink entire `Application Support/AppName` folder | ❌ Electron/Chromium apps reject it (sandbox check) |
| Symlink heavy subdirectories **inside** the folder | ✅ Apps work perfectly, even when drive is disconnected |

## Features

### Intelligent Deep Scanning
Scans inside `~/Library/Application Support/{app}/` for heavy subdirectories (>10MB). Also scans `~/Library/Caches/` and `~/Library/Logs/` for top-level app folders.

### Graceful Disconnect Handling
When the external drive is unplugged:
- Dead symlinks are replaced with empty placeholder directories
- Apps launch normally (minus the migrated data)
- When the drive reconnects, symlinks are restored and any locally-written data is merged back

### Menu Bar App
- Shows drive status (Active / Missing)
- Internal drive usage stats
- Scan & Migrate with per-item details
- Health check for broken symlinks

### Migration Safety
- Every migration recorded in a JSON manifest for rollback
- Health checks detect broken or replaced symlinks
- Self-protection: Sidecar never migrates itself

## Requirements

- **macOS 14+** (Sonoma, Sequoia, or later)
- **External USB4/Thunderbolt drive** formatted as APFS or HFS+

## Quick Start

```bash
git clone https://github.com/sofa-king-secure/sidecar.git
cd sidecar
swift build
./install.sh           # Builds .app, installs to /Applications
open /Applications/Sidecar.app
```

## Project Structure

```
Sources/ProjectSidecar/
├── SidecarApp.swift          # App entry, menu bar, state management
├── OnboardingView.swift      # First-run setup wizard
├── LibraryScanner.swift      # Deep scans inside Library folders
├── AppMigrator.swift         # Moves subdirectories + creates symlinks
├── DisconnectGuard.swift     # Handles drive disconnect/reconnect safely
├── MigrationManifest.swift   # Tracks migrations for rollback
├── DirectoryMonitor.swift    # FSEvents watcher for /Applications
├── AppFilter.swift           # Excludes Apple/system apps + self
├── VolumeMonitor.swift       # External drive mount/unmount detection
├── DriveSetup.swift          # Drive discovery and validation
├── SidecarConfig.swift       # Persistent configuration
└── DiskAnalyzer.swift        # Disk state reporting
```

## How It Works

1. **Scan** — For each third-party app, look inside its `~/Library/Application Support/` folder for subdirectories larger than 10MB
2. **Prompt** — Show the user what was found with sizes
3. **Move** — `FileManager.moveItem` each heavy subdirectory to the external drive
4. **Symlink** — `FileManager.createSymbolicLink` at the original location pointing to the external copy
5. **Record** — Save to manifest for rollback and health checks
6. **Guard** — On drive disconnect, replace dead symlinks with empty placeholders

## Proven Results

| App | Item | Size | Works Without Drive? |
|-----|------|------|---------------------|
| Claude Desktop | vm_bundles | 12 GB | ✅ Yes (chat works, Code VM unavailable) |
| Firefox | Caches | 890 MB | ✅ Yes (rebuilds cache) |

## License

MIT — see [LICENSE](LICENSE) for details.
