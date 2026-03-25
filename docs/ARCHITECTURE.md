# Architecture

## Component Overview

Project Sidecar is a macOS menu bar application built with Swift/SwiftUI. It uses a pipeline architecture where each component has a single responsibility.

## Lifecycle

### First Launch

```
App Start → SidecarConfig.needsOnboarding == true
         → Show OnboardingView (WindowGroup)
         → Step 1: Welcome screen
         → Step 2: DriveSetup.discoverExternalVolumes()
                   User selects drive
                   DriveSetup.validateVolume() checks filesystem
                   DriveSetup.initializeDrive() creates directory layout
                   SidecarConfig.configureDrive() persists selection
         → Step 3: System check (Full Disk Access, disk state)
         → Step 4: LibraryScanner.scanAllApps() → DiskAnalyzer.prioritize()
                   User selects apps for initial migration
         → Step 5: SidecarConfig.completeOnboarding()
         → Start normal monitoring
```

### Normal Operation

```
App Start → SidecarConfig.needsOnboarding == false
         → VolumeMonitor.start() (watch for drive mount/unmount)
         → DirectoryMonitor.start() (watch /Applications via FSEvents)
         → On new .app detected:
              AppFilter.shouldProcess() → reject Apple/system apps
              LibraryScanner.scanFootprint() → discover full disk usage
              DiskAnalyzer.prioritize() → score the candidate
              User prompt → Migrate / Skip
              AppMigrator.migrateFullFootprint() → move + symlink
              MigrationManifest.recordMigration() → persist for rollback
```

### Drive Reconnect

```
VolumeMonitor detects mount → status = .active
                            → MigrationManifest.healthCheck()
                            → Detect broken/nuked symlinks
                            → Notify user if action needed
```

## Data Flow

### Configuration

Stored in `~/Library/Application Support/ProjectSidecar/config.json`:
- Onboarding state, drive history, user preferences
- Loaded once at startup via `SidecarConfig.shared`

### Migration Manifest

Stored in `~/Library/Application Support/ProjectSidecar/manifest.json`:
- Every migration record with original/external paths
- Library sub-migrations with category and size
- Status tracking (active, broken, rolled back, updater-nuked)

### Drive Marker

Stored on external drive at `.sidecar-meta/sidecar.json`:
- Identifies a drive as Sidecar-initialized
- Records creation date and originating Mac hostname

## Key Design Decisions

### Why FSEvents over DispatchSource/VNODE?

FSEvents is purpose-built for directory monitoring at scale. `VNODE` watchers require a file descriptor per watched item and don't handle subdirectory changes. FSEvents coalesces events and handles the entire directory tree with one stream.

### Why not symlink Containers?

macOS sandbox enforcement checks the *real path* of container directories. If `~/Library/Containers/com.app.foo` is a symlink, the sandbox may deny access. We copy container data to the external drive as a backup but leave the original in place.

### Why 50MB minimum?

Below 50MB, the overhead of managing a symlink (health checks, potential updater conflicts, rollback tracking) isn't worth the disk savings. The sweet spot is apps with 200MB+ footprints.

### Why JSON manifests instead of SQLite?

The manifest is small (hundreds of records at most), human-readable for debugging, and doesn't require additional dependencies. If the project grows to manage thousands of items, SQLite would be the natural upgrade.

## Security Considerations

- **Full Disk Access**: Required to move items in `/Applications` and read protected `~/Library` paths. Checked during onboarding; user is directed to System Settings if missing.
- **Code Signature Validation**: Uses `SecStaticCode` API to identify Apple-signed apps. No shell-out to `codesign`.
- **No Elevated Privileges**: Sidecar runs as the current user. It cannot move apps owned by root or other users.
- **Filesystem Validation**: Only APFS and HFS+ are accepted. ExFAT/FAT32 don't support Unix symlinks or file permissions.
