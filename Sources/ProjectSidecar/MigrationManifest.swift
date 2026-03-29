import Foundation

/// Persistent record of every migration operation. Enables:
///   1. Undo/rollback of individual app migrations.
///   2. Detection of broken symlinks (e.g., after app updates).
///   3. Re-migration after an updater nukes a symlink.
///
/// Stored as JSON in ~/Library/Application Support/ProjectSidecar/manifest.json.
final class MigrationManifest {

    // MARK: - Types

    struct MigrationRecord: Codable, Identifiable, Sendable {
        let id: String                      // UUID
        let appName: String
        let bundleIdentifier: String?
        let originalPath: String            // Where it was (e.g., /Applications/Foo.app)
        let externalPath: String            // Where it went (e.g., /Volumes/Drive/Applications/Foo.app)
        let symlinkPath: String             // The symlink (usually == originalPath)
        var libraryMigrations: [LibraryMigrationRecord]
        let migratedAt: Date
        var status: Status

        enum Status: String, Codable, Sendable {
            case active        // Symlink in place, everything working
            case broken        // Symlink exists but target is missing (drive disconnected?)
            case rolledBack    // User undid this migration
            case updatedNuked  // An app update replaced the symlink with a real app
        }
    }

    struct LibraryMigrationRecord: Codable, Sendable {
        let category: String        // LibraryItem.Category.rawValue
        let originalPath: String
        let externalPath: String
        let sizeBytes: UInt64
        var isSymlinked: Bool
    }

    // MARK: - Properties

    private var records: [MigrationRecord] = []
    private let manifestURL: URL
    private let fileManager = FileManager.default

    // MARK: - Init

    init() {
        let supportDir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("ProjectSidecar")

        self.manifestURL = supportDir.appendingPathComponent("manifest.json")

        // Ensure directory exists.
        try? fileManager.createDirectory(
            at: supportDir,
            withIntermediateDirectories: true
        )

        load()
    }

    // MARK: - Public API: CRUD

    /// Record a completed migration.
    func recordMigration(
        appName: String,
        bundleIdentifier: String?,
        originalPath: String,
        externalPath: String,
        libraryMigrations: [LibraryMigrationRecord] = []
    ) {
        let record = MigrationRecord(
            id: UUID().uuidString,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            originalPath: originalPath,
            externalPath: externalPath,
            symlinkPath: originalPath,
            libraryMigrations: libraryMigrations,
            migratedAt: Date(),
            status: .active
        )
        records.append(record)
        save()
    }

    /// All active migration records.
    var activeRecords: [MigrationRecord] {
        records.filter { $0.status == .active }
    }

    /// All records (including rolled-back, broken).
    var allRecords: [MigrationRecord] {
        records
    }

    /// Find a record by original path.
    func record(forOriginalPath path: String) -> MigrationRecord? {
        records.first { $0.originalPath == path }
    }

    /// Find a record by bundle ID.
    func record(forBundleID bundleID: String) -> MigrationRecord? {
        records.first { $0.bundleIdentifier == bundleID && $0.status == .active }
    }

    // MARK: - Public API: Rollback

    /// Undo a migration: restore Library data from external to internal,
    /// removing symlinks.
    /// Note (v0.2): App bundle is not moved — it stays in /Applications.
    func rollback(recordID: String) async throws {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else {
            throw ManifestError.recordNotFound
        }

        let record = records[index]

        // v0.2: App bundle stays local, so skip app bundle rollback.
        // Only roll back library data.

        // Roll back library data.
        for libRecord in record.libraryMigrations {
            let extLibURL = URL(fileURLWithPath: libRecord.externalPath)
            let origLibURL = URL(fileURLWithPath: libRecord.originalPath)

            // Remove symlink if present.
            if libRecord.isSymlinked {
                let libResourceValues = try? origLibURL.resourceValues(forKeys: [.isSymbolicLinkKey])
                if libResourceValues?.isSymbolicLink == true {
                    try fileManager.removeItem(at: origLibURL)
                }
            }

            // Move data back.
            if fileManager.fileExists(atPath: extLibURL.path) {
                try fileManager.moveItem(at: extLibURL, to: origLibURL)
            }
        }

        // 4. Update record status.
        records[index].status = .rolledBack
        save()
    }

    // MARK: - Public API: Health Check

    /// Scan all active migrations and detect broken symlinks or
    /// updater-nuked apps (where the symlink was replaced with a real app).
    func healthCheck() -> [HealthIssue] {
        var issues: [HealthIssue] = []

        for (index, record) in records.enumerated() where record.status == .active {
            let symlinkURL = URL(fileURLWithPath: record.symlinkPath)

            if !fileManager.fileExists(atPath: record.symlinkPath) {
                // Symlink completely missing.
                issues.append(HealthIssue(
                    recordID: record.id,
                    appName: record.appName,
                    type: .symlinkMissing
                ))
            } else {
                let resourceValues = try? symlinkURL.resourceValues(forKeys: [.isSymbolicLinkKey])
                if resourceValues?.isSymbolicLink != true {
                    // There's a real file/directory where the symlink should be.
                    // An app updater likely replaced it.
                    records[index].status = .updatedNuked
                    issues.append(HealthIssue(
                        recordID: record.id,
                        appName: record.appName,
                        type: .updaterReplacedSymlink
                    ))
                } else {
                    // Symlink exists — check if target is reachable.
                    let dest = try? fileManager.destinationOfSymbolicLink(atPath: record.symlinkPath)
                    if let dest, !fileManager.fileExists(atPath: dest) {
                        records[index].status = .broken
                        issues.append(HealthIssue(
                            recordID: record.id,
                            appName: record.appName,
                            type: .targetUnreachable
                        ))
                    }
                }
            }
        }

        if !issues.isEmpty { save() }
        return issues
    }

    struct HealthIssue: Sendable {
        let recordID: String
        let appName: String
        let type: IssueType

        enum IssueType: Sendable {
            case symlinkMissing         // Symlink gone entirely
            case targetUnreachable      // Symlink exists but target missing (drive disconnected?)
            case updaterReplacedSymlink  // Real app replaced the symlink (needs re-migration)
        }
    }

    // MARK: - Persistence

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([MigrationRecord].self, from: data)) ?? []
    }

    // MARK: - Errors

    enum ManifestError: Error, CustomStringConvertible {
        case recordNotFound

        var description: String {
            switch self {
            case .recordNotFound:
                return "Migration record not found in manifest."
            }
        }
    }
}
