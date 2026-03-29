# Project Sidecar

> **Keep your Mac's internal drive clean.** Automatically migrate third-party applications and their Library data to an external USB4 volume using symbolic links.

<p align="center">
  <img src="docs/assets/menu-bar-preview.png" alt="Menu Bar Preview" width="280" />
</p>

---

## The Problem

You bought a MacBook with a 256GB or 512GB drive. After macOS, Xcode, Docker, a few creative apps, and their associated Library data — you're already running low. Apps like Adobe Creative Cloud, Logic Pro, or Docker Desktop can consume 10-50GB+ each once you count their `~/Library` footprint.

## The Solution

**Sidecar** monitors `/Applications` for new installs, scans their *full disk footprint* (the `.app` bundle + associated `~/Library` data), and migrates them to an external USB4 drive — replacing originals with symlinks so everything still works transparently.

## Features

### 🧭 First-Run Setup Wizard
- Detects external drives automatically
- Validates filesystem compatibility (APFS / HFS+ required)
- Checks Full Disk Access permissions
- Scans existing apps and recommends what to migrate

### 📦 Library-Only Migration (v0.2)
macOS Launch Services blocks apps launched via symlinks to external drives. So Sidecar takes the smarter approach: **the .app bundle stays in /Applications** while the Library data — where the real disk space lives — gets moved to the external drive and symlinked.

Not just the `.app` bundle — Sidecar scans **9 Library directories** per app:

| Directory | Typical Contents | Symlink Safe? |
|-----------|-----------------|:---:|
| `Application Support` | Plugins, databases, configs | ✅ |
| `Containers` | Sandboxed app data | ⚠️ Copy only |
| `Group Containers` | Shared sandboxed data | ⚠️ Copy only |
| `Caches` | Regenerable cache data | ✅ |
| `Preferences` | `.plist` settings | ✅ |
| `Saved Application State` | Window positions, state | ✅ |
| `Logs` | App logs | ✅ |
| `HTTPStorages` | Cookie/session data | ✅ |
| `WebKit` | WebKit storage | ✅ |

### 📊 Smart Prioritization
- Scores apps 0-100 based on total footprint, library-to-bundle ratio, and disk pressure
- Generates migration plans that target a specific free-space goal
- Apps under 50MB are ignored (not worth the symlink complexity)
- Disk pressure multiplier: more aggressive when your drive is nearly full

### 🔁 Rollback & Health Monitoring
- Every migration is recorded in a JSON manifest
- Full undo: moves everything back, removes symlinks
- Detects broken symlinks (drive disconnected)
- Detects when app updaters nuke symlinks and replace them with real files

### 🖥 Menu Bar App
- Status indicator: Active / Idle / Drive Missing / Scanning
- Shows disk usage and migrated app count
- Quick access to scan, health check, and settings

## Requirements

- **macOS 14+** (Sonoma, Sequoia, or later)
- **External USB4/Thunderbolt drive** formatted as APFS or Mac OS Extended (HFS+)
- **Full Disk Access** permission (prompted during setup)

## Building

```bash
# Clone the repo
git clone https://github.com/YOUR_USERNAME/project-sidecar.git
cd project-sidecar

# Build
swift build

# Run tests
swift test

# Build for release
swift build -c release
```

## Project Structure

```
ProjectSidecar/
├── Package.swift                 # Swift Package Manager manifest
├── Sources/ProjectSidecar/
│   ├── main.swift                # App entry point, menu bar, state management
│   ├── OnboardingView.swift      # First-run setup wizard (SwiftUI)
│   ├── SidecarConfig.swift       # Persistent configuration & preferences
│   ├── DriveSetup.swift          # External volume discovery & validation
│   ├── DirectoryMonitor.swift    # FSEvents watcher for /Applications
│   ├── AppFilter.swift           # Excludes Apple/system apps
│   ├── LibraryScanner.swift      # Discovers ~/Library data per app
│   ├── DiskAnalyzer.swift        # Size-based scoring & prioritization
│   ├── AppMigrator.swift         # File move + symlink creation
│   ├── MigrationManifest.swift   # Rollback tracking & health checks
│   └── VolumeMonitor.swift       # External drive mount/unmount detection
├── Tests/ProjectSidecarTests/
│   └── ProjectSidecarTests.swift # Unit tests
├── docs/
│   └── ARCHITECTURE.md           # Detailed architecture documentation
├── CLAUDE.md                     # AI/dev pair-programming instructions
├── PRD.md                        # Product requirements
├── TECH_SPECS.md                 # Technical specifications
├── LICENSE                       # MIT License
└── CONTRIBUTING.md               # Contribution guidelines
```

## How It Works

```
┌─────────────┐     ┌──────────┐     ┌─────────────────┐
│  /Applications │──▶│ FSEvents │──▶│ DirectoryMonitor │
│  (new .app)    │   │ stream   │   │                   │
└─────────────┘     └──────────┘   └────────┬──────────┘
                                             │
                                    ┌────────▼──────────┐
                                    │    AppFilter       │
                                    │ (skip Apple apps)  │
                                    └────────┬──────────┘
                                             │
                                    ┌────────▼──────────┐
                                    │  LibraryScanner    │
                                    │ (full footprint)   │
                                    └────────┬──────────┘
                                             │
                                    ┌────────▼──────────┐
                                    │   DiskAnalyzer     │
                                    │ (score & plan)     │
                                    └────────┬──────────┘
                                             │
                                    ┌────────▼──────────┐
                                    │   AppMigrator      │──▶ External Drive
                                    │ (move + symlink)   │    /Volumes/Drive/
                                    └────────┬──────────┘
                                             │
                                    ┌────────▼──────────┐
                                    │ MigrationManifest  │
                                    │ (record + rollback)│
                                    └───────────────────┘
```

## Configuration

Settings are stored in `~/Library/Application Support/ProjectSidecar/config.json`.

| Setting | Default | Description |
|---------|---------|-------------|
| `autoMigrateNewApps` | `true` | Prompt when new apps are installed |
| `minimumAppSizeMB` | `50` | Skip apps smaller than this |
| `targetFreeSpaceGB` | `30` | Target free space on internal drive |
| `migrateLibraryData` | `true` | Also migrate ~/Library folders |
| `migrateCaches` | `false` | Include Caches (they regenerate) |
| `runHealthCheckOnMount` | `true` | Check symlinks when drive reconnects |
| `launchAtLogin` | `false` | Start Sidecar at login |

## Roadmap

- [ ] Settings UI panel (volume selection, thresholds)
- [ ] LaunchAgent plist generation for login start
- [ ] Periodic container sync for sandboxed apps
- [ ] Notifications via UserNotifications framework
- [ ] Homebrew formula
- [ ] Disk usage dashboard in menu bar popover
- [ ] Multiple drive support

## License

MIT — see [LICENSE](LICENSE) for details.
