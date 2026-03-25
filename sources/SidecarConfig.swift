import Foundation

/// Persistent configuration for Project Sidecar.
/// Stored in ~/Library/Application Support/ProjectSidecar/config.json.
///
/// Tracks:
///   - Whether first-run onboarding has completed
///   - The configured external volume name and UUID
///   - User preferences (thresholds, auto-migrate, etc.)
///   - Known drive history (detect "new" vs "returning" drives)
final class SidecarConfig: ObservableObject {

    // MARK: - Types

    struct DriveRecord: Codable, Sendable, Identifiable {
        let id: String           // Volume UUID from diskutil
        let volumeName: String
        let firstSeen: Date
        var lastSeen: Date
        var totalCapacityBytes: UInt64
        var isConfigured: Bool   // Is this the active Sidecar drive?
    }

    struct UserPreferences: Codable, Sendable {
        var autoMigrateNewApps: Bool = true
        var minimumAppSizeMB: Int = 50
        var targetFreeSpaceGB: Int = 30
        var migrateLibraryData: Bool = true
        var migrateCaches: Bool = false   // Caches regenerate — optional
        var showNotifications: Bool = true
        var runHealthCheckOnMount: Bool = true
        var launchAtLogin: Bool = false
    }

    // MARK: - Stored State

    struct StoredState: Codable {
        var onboardingComplete: Bool = false
        var configuredDriveID: String?       // UUID of active drive
        var configuredVolumeName: String?
        var knownDrives: [DriveRecord] = []
        var preferences: UserPreferences = UserPreferences()
        var setupCompletedAt: Date?
    }

    // MARK: - Properties

    @Published var state: StoredState

    private let configURL: URL
    private let fileManager = FileManager.default

    // MARK: - Singleton

    static let shared = SidecarConfig()

    private init() {
        let supportDir = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("ProjectSidecar")

        try? FileManager.default.createDirectory(
            at: supportDir,
            withIntermediateDirectories: true
        )

        self.configURL = supportDir.appendingPathComponent("config.json")

        // Load or create default state.
        if let data = try? Data(contentsOf: configURL),
           let decoded = try? JSONDecoder.sidecar.decode(StoredState.self, from: data) {
            self.state = decoded
        } else {
            self.state = StoredState()
        }
    }

    // MARK: - Public API

    var needsOnboarding: Bool {
        !state.onboardingComplete
    }

    var configuredVolumeName: String? {
        state.configuredVolumeName
    }

    var preferences: UserPreferences {
        state.preferences
    }

    /// Register a drive we've seen. Returns whether it's new or returning.
    @discardableResult
    func registerDrive(
        volumeUUID: String,
        volumeName: String,
        capacityBytes: UInt64
    ) -> DriveStatus {
        if let index = state.knownDrives.firstIndex(where: { $0.id == volumeUUID }) {
            // Returning drive.
            state.knownDrives[index].lastSeen = Date()
            state.knownDrives[index].totalCapacityBytes = capacityBytes
            save()
            return .returning(record: state.knownDrives[index])
        } else {
            // Brand new drive.
            let record = DriveRecord(
                id: volumeUUID,
                volumeName: volumeName,
                firstSeen: Date(),
                lastSeen: Date(),
                totalCapacityBytes: capacityBytes,
                isConfigured: false
            )
            state.knownDrives.append(record)
            save()
            return .new(record: record)
        }
    }

    enum DriveStatus {
        case new(record: DriveRecord)
        case returning(record: DriveRecord)
    }

    /// Set a drive as the active Sidecar drive.
    func configureDrive(volumeUUID: String, volumeName: String) {
        // Unmark any previous drive.
        for i in state.knownDrives.indices {
            state.knownDrives[i].isConfigured = false
        }

        // Mark the selected drive.
        if let index = state.knownDrives.firstIndex(where: { $0.id == volumeUUID }) {
            state.knownDrives[index].isConfigured = true
        }

        state.configuredDriveID = volumeUUID
        state.configuredVolumeName = volumeName
        save()
    }

    /// Mark onboarding as complete.
    func completeOnboarding() {
        state.onboardingComplete = true
        state.setupCompletedAt = Date()
        save()
    }

    /// Update user preferences.
    func updatePreferences(_ update: (inout UserPreferences) -> Void) {
        update(&state.preferences)
        save()
    }

    /// Reset everything (for testing or re-onboarding).
    func reset() {
        state = StoredState()
        save()
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder.sidecar.encode(state) else { return }
        try? data.write(to: configURL, options: .atomic)
    }
}

// MARK: - Coder Helpers

private extension JSONEncoder {
    static let sidecar: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

private extension JSONDecoder {
    static let sidecar: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
