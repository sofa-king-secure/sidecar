import Foundation

/// Persistent record of every migration operation.
/// Stored as JSON in ~/Library/Application Support/ProjectSidecar/manifest.json.
final class MigrationManifest {

    // MARK: - Types

    struct MigrationRecord: Codable, Identifiable, Sendable {
        let id: String
        let appName: String
        let bundleIdentifier: String?
        let originalPath: String
        let externalPath: String
        let symlinkPath: String
        var libraryMigrations: [LibraryMigrationRecord]
        let migratedAt: Date
        var status: Status

        enum Status: String, Codable, Sendable {
            case active
            case broken
            case rolledBack
            case updatedNuked
        }
    }

    struct LibraryMigrationRecord: Codable, Sendable {
        let category: String
        let originalPath: String
        let externalPath: String
        let sizeBytes: UInt64
        var isSymlinked: Bool
    }

    // MARK: - Properties

    private var records: [MigrationRecord] = []
    private let manifestURL: URL
    private let fileManager = FileManager.default

    init() {
        let supportDir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("ProjectSidecar")

        self.manifestURL = supportDir.appendingPathComponent("manifest.json")
        try? fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: - CRUD

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

    var activeRecords: [MigrationRecord] { records.filter { $0.status == .active } }
    var allRecords: [MigrationRecord] { records }

    func record(forBundleID bundleID: String) -> MigrationRecord? {
        records.first { $0.bundleIdentifier == bundleID && $0.status == .active }
    }

    // MARK: - Rollback

    /// Undo a migration: restore symlinked items from external to internal.
    func rollback(recordID: String) async throws {
        guard let index = records.firstIndex(where: { $0.id == recordID }) else {
            throw ManifestError.recordNotFound
        }

        let record = records[index]

        for libRecord in record.libraryMigrations where libRecord.isSymlinked {
            let origURL = URL(fileURLWithPath: libRecord.originalPath)
            let extURL = URL(fileURLWithPath: libRecord.externalPath)

            // Remove symlink if present.
            let resourceValues = try? origURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            if resourceValues?.isSymbolicLink == true {
                try fileManager.removeItem(at: origURL)
            }

            // Move data back from external.
            if fileManager.fileExists(atPath: extURL.path) &&
               !fileManager.fileExists(atPath: origURL.path) {
                try fileManager.moveItem(at: extURL, to: origURL)
            }
        }

        records[index].status = .rolledBack
        save()
    }

    // MARK: - Health Check

    func healthCheck() -> [HealthIssue] {
        var issues: [HealthIssue] = []

        for (index, record) in records.enumerated() where record.status == .active {
            for libRecord in record.libraryMigrations where libRecord.isSymlinked {
                let origURL = URL(fileURLWithPath: libRecord.originalPath)

                if !fileManager.fileExists(atPath: libRecord.originalPath) {
                    issues.append(HealthIssue(
                        recordID: record.id,
                        appName: record.appName,
                        itemPath: libRecord.originalPath,
                        type: .symlinkMissing
                    ))
                } else {
                    let resourceValues = try? origURL.resourceValues(forKeys: [.isSymbolicLinkKey])
                    if resourceValues?.isSymbolicLink != true {
                        records[index].status = .updatedNuked
                        issues.append(HealthIssue(
                            recordID: record.id,
                            appName: record.appName,
                            itemPath: libRecord.originalPath,
                            type: .updaterReplacedSymlink
                        ))
                    } else {
                        let dest = try? fileManager.destinationOfSymbolicLink(atPath: libRecord.originalPath)
                        if let dest, !fileManager.fileExists(atPath: dest) {
                            issues.append(HealthIssue(
                                recordID: record.id,
                                appName: record.appName,
                                itemPath: libRecord.originalPath,
                                type: .targetUnreachable
                            ))
                        }
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
        let itemPath: String
        let type: IssueType

        enum IssueType: Sendable {
            case symlinkMissing
            case targetUnreachable
            case updaterReplacedSymlink
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

    enum ManifestError: Error, CustomStringConvertible {
        case recordNotFound
        var description: String { "Migration record not found in manifest." }
    }
}
