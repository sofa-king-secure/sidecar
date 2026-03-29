import Foundation

/// Handles migration of application Library data to an external volume,
/// replacing originals with symbolic links.
///
/// KEY DESIGN DECISION (v0.2):
///   macOS Launch Services refuses to open .app bundles via symlinks to
///   external volumes (error -10657). The .app bundle STAYS on the internal
///   drive. Only ~/Library data is migrated — this is where the real disk
///   space lives anyway.
///
///   - App bundle: STAYS in /Applications (untouched)
///   - Safe Library data (App Support, Caches, etc.): moved → symlinked
///   - Sandboxed containers: copied to external as backup (not symlinked)
///   - Everything recorded in MigrationManifest for rollback
///
/// Per CLAUDE.md: async/await, native APIs only.
final class AppMigrator {

    // MARK: - Types

    /// User's chosen resolution when data already exists on the external drive.
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
        case noLibraryDataToMigrate

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
            case .noLibraryDataToMigrate:
                return "No Library data found to migrate for this app."
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

    // MARK: - Public API: Library-Only Migration

    /// Migrate an app's Library data to the external drive.
    /// The .app bundle stays in /Applications — only Library data moves.
    ///
    /// This is the primary migration method (v0.2+).
    func migrateLibraryData(
        footprint: LibraryScanner.AppFootprint,
        externalBase: URL,
        conflictHandler: @Sendable (URL) async -> ConflictResolution,
        progressHandler: (@Sendable (MigrationProgress) -> Void)? = nil
    ) async throws {
        let appName = footprint.appBundleURL.lastPathComponent
        let externalLibDir = externalBase.appendingPathComponent("Library")

        // Filter to items we'll actually migrate.
        let migratable = footprint.libraryItems.filter { strategyFor(item: $0) != .skip }

        if migratable.isEmpty {
            throw MigrationError.noLibraryDataToMigrate
        }

        let bytesTotal = migratable.reduce(0) { $0 + $1.sizeBytes }
        var bytesCompleted: UInt64 = 0

        progressHandler?(MigrationProgress(
            phase: "Library Data",
            detail: "Migrating data for \(appName)...",
            bytesCompleted: 0,
            bytesTotal: bytesTotal
        ))

        // ── Migrate each library item ──

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
                    let resolution = await conflictHandler(extDestination)
                    switch resolution {
                    case .overwrite:
                        try removeItem(at: extDestination)
                    case .linkOnly:
                        // Remove local, link to existing external copy.
                        try removeItem(at: item.url)
                        try createSymlink(at: item.url, pointingTo: extDestination)
                        libraryRecords.append(MigrationManifest.LibraryMigrationRecord(
                            category: item.category.rawValue,
                            originalPath: item.url.path,
                            externalPath: extDestination.path,
                            sizeBytes: item.sizeBytes,
                            isSymlinked: true
                        ))
                        bytesCompleted += item.sizeBytes
                        continue
                    case .skip:
                        bytesCompleted += item.sizeBytes
                        continue
                    }
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

        // ── Record in manifest ──
        // Note: originalPath/externalPath still reference the .app for identification,
        // but the app bundle itself is NOT moved in v0.2+.

        manifest.recordMigration(
            appName: appName,
            bundleIdentifier: footprint.bundleIdentifier,
            originalPath: footprint.appBundleURL.path,
            externalPath: footprint.appBundleURL.path,  // Same — bundle stays local
            libraryMigrations: libraryRecords
        )

        let totalMigrated = ByteCountFormatter.string(
            fromByteCount: Int64(bytesCompleted), countStyle: .file
        )

        progressHandler?(MigrationProgress(
            phase: "Complete",
            detail: "\(appName): \(totalMigrated) of Library data migrated.",
            bytesCompleted: bytesTotal,
            bytesTotal: bytesTotal
        ))
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
