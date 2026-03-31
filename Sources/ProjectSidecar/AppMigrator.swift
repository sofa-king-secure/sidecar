import Foundation

/// Migrates heavy subdirectories to an external drive via symlinks.
///
/// v0.3 STRATEGY:
///   - .app bundles: NEVER moved (Launch Services blocks external symlinks)
///   - ~/Library/Application Support/{app}/: NEVER moved (Electron rejects it)
///   - Heavy subdirs INSIDE Application Support: moved + symlinked ✅
///   - ~/Library/Caches/{app}: moved + symlinked entirely ✅ (regenerable)
///   - ~/Library/Logs/{app}: moved + symlinked entirely ✅ (expendable)
///
/// The parent Application Support folder stays real on the internal drive.
/// Only the heavy subdirectories inside it get symlinked to external.
final class AppMigrator {

    // MARK: - Types

    enum MigrationError: Error, CustomStringConvertible {
        case volumeNotMounted
        case moveItemFailed(path: String, underlying: Error)
        case symlinkFailed(path: String, underlying: Error)
        case removeOriginalFailed(path: String, underlying: Error)
        case noItemsToMigrate

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
            case .noItemsToMigrate:
                return "No items selected for migration."
            }
        }
    }

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

    // MARK: - Public API

    /// Migrate selected items for an app.
    func migrateItems(
        appName: String,
        bundleIdentifier: String?,
        items: [LibraryScanner.MigratableItem],
        externalBase: URL,
        progressHandler: (@Sendable (MigrationProgress) -> Void)? = nil
    ) async throws {
        if items.isEmpty {
            throw MigrationError.noItemsToMigrate
        }

        let bytesTotal = items.reduce(0) { $0 + $1.sizeBytes }
        var bytesCompleted: UInt64 = 0
        var records: [MigrationManifest.LibraryMigrationRecord] = []

        for item in items {
            let externalPath = buildExternalPath(for: item, externalBase: externalBase)

            progressHandler?(MigrationProgress(
                phase: "Moving",
                detail: item.displayName,
                bytesCompleted: bytesCompleted,
                bytesTotal: bytesTotal
            ))

            print("[Sidecar] Moving: \(item.displayName) (\(item.formattedSize))")

            do {
                try ensureDirectory(at: externalPath.deletingLastPathComponent())

                // Remove existing external copy if present.
                if fileManager.fileExists(atPath: externalPath.path) {
                    try removeItem(at: externalPath)
                }

                // Move to external.
                try moveItem(from: item.url, to: externalPath)

                // Create symlink at original location.
                try createSymlink(at: item.url, pointingTo: externalPath)

                records.append(MigrationManifest.LibraryMigrationRecord(
                    category: item.depth == .subDirectory ? "Application Support (subdir)" : "Top-level",
                    originalPath: item.url.path,
                    externalPath: externalPath.path,
                    sizeBytes: item.sizeBytes,
                    isSymlinked: true
                ))

                print("[Sidecar] ✅ \(item.displayName) → external")
            } catch {
                print("[Sidecar] ❌ Failed: \(item.displayName): \(error)")
                // Continue with other items — don't abort the whole migration.
            }

            bytesCompleted += item.sizeBytes
        }

        // Record in manifest.
        if !records.isEmpty {
            manifest.recordMigration(
                appName: appName + ".app",
                bundleIdentifier: bundleIdentifier,
                originalPath: "/Applications/\(appName).app",
                externalPath: "/Applications/\(appName).app",
                libraryMigrations: records
            )
        }

        let totalMigrated = ByteCountFormatter.string(
            fromByteCount: Int64(bytesCompleted), countStyle: .file
        )

        progressHandler?(MigrationProgress(
            phase: "Complete",
            detail: "\(appName): \(totalMigrated) migrated to external drive.",
            bytesCompleted: bytesTotal,
            bytesTotal: bytesTotal
        ))

        print("[Sidecar] ✅ \(appName): \(totalMigrated) total migrated (\(records.count) items)")
    }

    // MARK: - Path Building

    /// Build the external drive path for an item.
    /// Structure: /Volumes/Drive/Library/{AppName}/{subdirName}
    /// or:        /Volumes/Drive/Library/Caches/{cacheName}
    private func buildExternalPath(
        for item: LibraryScanner.MigratableItem,
        externalBase: URL
    ) -> URL {
        switch item.depth {
        case .subDirectory:
            // e.g., ~/Library/Application Support/Claude/vm_bundles
            // → /Volumes/Drive/Library/Claude/vm_bundles
            let parentName = item.url.deletingLastPathComponent().lastPathComponent
            return externalBase
                .appendingPathComponent("Library")
                .appendingPathComponent(parentName)
                .appendingPathComponent(item.url.lastPathComponent)

        case .topLevel:
            // e.g., ~/Library/Caches/Firefox
            // → /Volumes/Drive/Library/Caches/Firefox
            let categoryName = item.url.deletingLastPathComponent().lastPathComponent
            return externalBase
                .appendingPathComponent("Library")
                .appendingPathComponent(categoryName)
                .appendingPathComponent(item.url.lastPathComponent)
        }
    }

    // MARK: - File Operations

    private func moveItem(from source: URL, to destination: URL) throws {
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            throw MigrationError.moveItemFailed(path: source.path, underlying: error)
        }
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
