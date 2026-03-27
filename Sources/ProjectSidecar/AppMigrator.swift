import Foundation

/// Handles the actual file migration: moving an app bundle AND its
/// associated ~/Library data to the external volume, replacing
/// originals with symbolic links.
///
/// Upgraded from bundle-only to full-footprint migration:
///   - Moves the .app bundle → symlinks it
///   - Moves safe Library data (App Support, Caches, etc.) → symlinks them
///   - Copies sandboxed containers (can't reliably symlink) → periodic sync
///   - Records everything in MigrationManifest for rollback
///
/// Per CLAUDE.md: async/await, native APIs only.
final class AppMigrator {

    // MARK: - Types

    /// User's chosen resolution when an app already exists on the external drive.
    enum ConflictResolution: Sendable {
        case overwrite
        case linkOnly
        case skip
    }

    /// What to do with each library item.
    enum LibraryStrategy: Sendable {
        case symlinkMove   // Move to external, replace with symlink (safe items)
        case copyOnly      // Copy to external, leave original (sandboxed containers)
        case skip          // Too small or user declined
    }

    enum MigrationError: Error, CustomStringConvertible {
        case volumeNotMounted
        case moveItemFailed(path: String, underlying: Error)
        case symlinkFailed(path: String, underlying: Error)
        case removeOriginalFailed(path: String, underlying: Error)
        case rollbackFailed(underlying: Error)

        var description: String {
            switch self {
            case .volumeNotMounted:
                return "External volume is not mounted."
            case .moveItemFailed(let p, let e):
                return "Failed to move \(p): \(e.localizedDescription)"
            case .symlinkFailed(let p, let e):
                return "Failed to symlink \(p): \(e.localizedDescription)"
            case .removeOriginalFailed(let p, let e):
                return "Failed to remove \(p): \(e.localizedDescription)"
            case .rollbackFailed(let e):
                return "Rollback failed: \(e.localizedDescription)"
            }
        }
    }

    /// Progress updates during a migration.
    struct MigrationProgress: Sendable {
        let phase: String
        let detail: String
        let bytesCompleted: UInt64
        let bytesTotal: UInt64
    }

    // MARK: - Properties

    private let fileManager = FileManager.default
    let manifest: MigrationManifest

    init(manifest: MigrationManifest = MigrationManifest()) {
        self.manifest = manifest
    }

    // MARK: - Public API: Full Footprint Migration

    /// Migrate an app's full footprint (bundle + library data).
    func migrateFullFootprint(
        footprint: LibraryScanner.AppFootprint,
        externalBase: URL,
        conflictHandler: @Sendable (URL) async -> ConflictResolution,
        progressHandler: (@Sendable (MigrationProgress) -> Void)? = nil
    ) async throws {
        let appName = footprint.appBundleURL.lastPathComponent
        let externalAppsDir = externalBase.appendingPathComponent("Applications")
        let externalLibDir = externalBase.appendingPathComponent("Library")
        let appDestination = externalAppsDir.appendingPathComponent(appName)

        var bytesCompleted: UInt64 = 0
        let bytesTotal = footprint.totalSize

        // ── Step 1: Migrate the .app bundle ──

        progressHandler?(MigrationProgress(
            phase: "App Bundle",
            detail: "Moving \(appName)...",
            bytesCompleted: bytesCompleted,
            bytesTotal: bytesTotal
        ))

        try ensureDirectory(at: externalAppsDir)

        if fileManager.fileExists(atPath: appDestination.path) {
            let resolution = await conflictHandler(appDestination)
            switch resolution {
            case .overwrite:
                try removeItem(at: appDestination)
                try moveAndLink(source: footprint.appBundleURL, destination: appDestination)
            case .linkOnly:
                try removeItem(at: footprint.appBundleURL)
                try createSymlink(at: footprint.appBundleURL, pointingTo: appDestination)
            case .skip:
                return
            }
        } else {
            try moveAndLink(source: footprint.appBundleURL, destination: appDestination)
        }

        bytesCompleted += footprint.appBundleSize

        // ── Step 2: Migrate library data ──

        var libraryRecords: [MigrationManifest.LibraryMigrationRecord] = []

        for item in footprint.libraryItems {
            let strategy = strategyFor(item: item)
            guard strategy != .skip else { continue }

            let relativePath = item.category.rawValue + "/" + item.url.lastPathComponent
            let extDestination = externalLibDir.appendingPathComponent(relativePath)

            progressHandler?(MigrationProgress(
                phase: "Library Data",
                detail: "\(item.category.rawValue)/\(item.url.lastPathComponent)",
                bytesCompleted: bytesCompleted,
                bytesTotal: bytesTotal
            ))

            try ensureDirectory(at: extDestination.deletingLastPathComponent())

            switch strategy {
            case .symlinkMove:
                if fileManager.fileExists(atPath: extDestination.path) {
                    try removeItem(at: extDestination)
                }
                try moveAndLink(source: item.url, destination: extDestination)

                libraryRecords.append(MigrationManifest.LibraryMigrationRecord(
                    category: item.category.rawValue,
                    originalPath: item.url.path,
                    externalPath: extDestination.path,
                    sizeBytes: item.sizeBytes,
                    isSymlinked: true
                ))

            case .copyOnly:
                if !fileManager.fileExists(atPath: extDestination.path) {
                    try fileManager.copyItem(at: item.url, to: extDestination)
                }

                libraryRecords.append(MigrationManifest.LibraryMigrationRecord(
                    category: item.category.rawValue,
                    originalPath: item.url.path,
                    externalPath: extDestination.path,
                    sizeBytes: item.sizeBytes,
                    isSymlinked: false
                ))

            case .skip:
                break
            }

            bytesCompleted += item.sizeBytes
        }

        // ── Step 3: Record in manifest ──

        manifest.recordMigration(
            appName: appName,
            bundleIdentifier: footprint.bundleIdentifier,
            originalPath: footprint.appBundleURL.path,
            externalPath: appDestination.path,
            libraryMigrations: libraryRecords
        )

        progressHandler?(MigrationProgress(
            phase: "Complete",
            detail: "\(appName) migrated successfully.",
            bytesCompleted: bytesTotal,
            bytesTotal: bytesTotal
        ))
    }

    // MARK: - Public API: Simple Bundle-Only Migration (backward compat)

    func migrate(
        appURL: URL,
        to externalDir: URL,
        conflictHandler: @Sendable (URL) async -> ConflictResolution
    ) async throws {
        let appName = appURL.lastPathComponent
        let destinationURL = externalDir.appendingPathComponent(appName)

        try ensureDirectory(at: externalDir)

        if fileManager.fileExists(atPath: destinationURL.path) {
            let resolution = await conflictHandler(destinationURL)
            switch resolution {
            case .overwrite:
                try removeItem(at: destinationURL)
                try moveAndLink(source: appURL, destination: destinationURL)
            case .linkOnly:
                try removeItem(at: appURL)
                try createSymlink(at: appURL, pointingTo: destinationURL)
            case .skip:
                return
            }
        } else {
            try moveAndLink(source: appURL, destination: destinationURL)
        }

        manifest.recordMigration(
            appName: appName,
            bundleIdentifier: nil,
            originalPath: appURL.path,
            externalPath: destinationURL.path
        )
    }

    // MARK: - Strategy

    private func strategyFor(item: LibraryScanner.LibraryItem) -> LibraryStrategy {
        // Skip tiny items (< 1 MB).
        if item.sizeBytes < 1_000_000 {
            return .skip
        }

        // Sandboxed containers can't be reliably symlinked.
        if !item.category.symlinkSafe {
            return item.sizeBytes >= 50_000_000 ? .copyOnly : .skip
        }

        return .symlinkMove
    }

    // MARK: - File Operations

    private func moveAndLink(source: URL, destination: URL) throws {
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            throw MigrationError.moveItemFailed(path: source.path, underlying: error)
        }
        try createSymlink(at: source, pointingTo: destination)
    }

    private func createSymlink(at linkURL: URL, pointingTo target: URL) throws {
        do {
            try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: target)
        } catch {
            throw MigrationError.symlinkFailed(path: linkURL.path, underlying: error)
        }
    }

    private func removeItem(at url: URL) throws {
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw MigrationError.removeOriginalFailed(path: url.path, underlying: error)
        }
    }

    private func ensureDirectory(at url: URL) throws {
        var isDir: ObjCBool = false
        if !fileManager.fileExists(atPath: url.path, isDirectory: &isDir) || !isDir.boolValue {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
