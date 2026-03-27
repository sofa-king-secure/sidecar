import Foundation

/// Handles external drive inspection and setup during onboarding.
///
/// Responsibilities:
///   - Enumerate mounted external volumes
///   - Read volume UUID, filesystem type, capacity
///   - Determine if a drive is ready for Sidecar (APFS/HFS+ required)
///   - Check if the drive has an existing Sidecar directory structure
///   - Create the initial directory layout on a fresh drive
///
/// Uses native macOS APIs where possible; falls back to diskutil
/// for UUID/filesystem inspection since there's no pure-Swift API
/// for disk partition metadata.
struct DriveSetup {

    // MARK: - Types

    /// Information about a discovered external volume.
    struct DiscoveredVolume: Identifiable, Sendable {
        let id: String              // Volume UUID (or fallback identifier)
        let name: String
        let mountPoint: URL
        let fileSystem: FileSystemType
        let totalBytes: UInt64
        let availableBytes: UInt64
        let hasSidecarData: Bool    // Existing Sidecar directory found?
        let isRemovable: Bool

        var formattedCapacity: String {
            ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
        }

        var formattedAvailable: String {
            ByteCountFormatter.string(fromByteCount: Int64(availableBytes), countStyle: .file)
        }

        var isReady: Bool {
            fileSystem.supportsSidecar
        }
    }

    enum FileSystemType: String, Sendable {
        case apfs = "apfs"
        case hfsPlus = "hfs"
        case exfat = "exfat"
        case fat32 = "msdos"
        case ntfs = "ntfs"
        case unknown = "unknown"

        /// APFS and HFS+ support symlinks, permissions, and large files.
        /// ExFAT/FAT32/NTFS don't support Unix symlinks properly.
        var supportsSidecar: Bool {
            switch self {
            case .apfs, .hfsPlus: return true
            default: return false
            }
        }

        var displayName: String {
            switch self {
            case .apfs:    return "APFS"
            case .hfsPlus: return "Mac OS Extended (HFS+)"
            case .exfat:   return "ExFAT"
            case .fat32:   return "FAT32"
            case .ntfs:    return "NTFS"
            case .unknown: return "Unknown"
            }
        }

        var formatAdvice: String? {
            guard !supportsSidecar else { return nil }
            return "This drive is formatted as \(displayName), which doesn't support macOS symlinks or file permissions. " +
                   "Sidecar requires APFS or HFS+. You can reformat it in Disk Utility — " +
                   "note: this will erase all data on the drive."
        }
    }

    enum SetupError: Error, CustomStringConvertible {
        case noExternalVolumes
        case unsupportedFileSystem(FileSystemType)
        case directoryCreationFailed(underlying: Error)
        case diskutilFailed

        var description: String {
            switch self {
            case .noExternalVolumes:
                return "No external volumes detected. Please connect a USB drive."
            case .unsupportedFileSystem(let fs):
                return "Drive is formatted as \(fs.displayName). Sidecar requires APFS or Mac OS Extended."
            case .directoryCreationFailed(let e):
                return "Failed to create Sidecar directory structure: \(e.localizedDescription)"
            case .diskutilFailed:
                return "Could not read disk information."
            }
        }
    }

    // MARK: - Properties

    private let fileManager = FileManager.default

    // MARK: - Public API: Discovery

    /// Find all mounted external volumes.
    func discoverExternalVolumes() async -> [DiscoveredVolume] {
        let volumeURLs = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: [
                .volumeNameKey,
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
                .volumeIsRemovableKey,
                .volumeIsInternalKey,
                .volumeUUIDStringKey
            ],
            options: [.skipHiddenVolumes]
        ) ?? []

        var volumes: [DiscoveredVolume] = []

        for url in volumeURLs {
            guard let values = try? url.resourceValues(forKeys: [
                .volumeNameKey,
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
                .volumeIsRemovableKey,
                .volumeIsInternalKey,
                .volumeUUIDStringKey
            ]) else { continue }

            // Skip internal drives.
            let isInternal = values.volumeIsInternal ?? true
            if isInternal { continue }

            let name = values.volumeName ?? url.lastPathComponent
            let uuid = values.volumeUUIDString ?? "unknown-\(name)-\(url.path.hashValue)"
            let total = UInt64(values.volumeTotalCapacity ?? 0)
            let available = UInt64(values.volumeAvailableCapacity ?? 0)
            let isRemovable = values.volumeIsRemovable ?? false

            // Check filesystem type.
            let fsType = await detectFileSystem(at: url)

            // Check for existing Sidecar data.
            let sidecarDir = url.appendingPathComponent("Applications")
            let hasSidecar = fileManager.fileExists(atPath: sidecarDir.path)

            volumes.append(DiscoveredVolume(
                id: uuid,
                name: name,
                mountPoint: url,
                fileSystem: fsType,
                totalBytes: total,
                availableBytes: available,
                hasSidecarData: hasSidecar,
                isRemovable: isRemovable
            ))
        }

        return volumes
    }

    // MARK: - Public API: Setup

    /// Validate that a volume is ready for Sidecar.
    func validateVolume(_ volume: DiscoveredVolume) -> ValidationResult {
        var issues: [String] = []
        var warnings: [String] = []

        // Filesystem check.
        if !volume.fileSystem.supportsSidecar {
            issues.append(volume.fileSystem.formatAdvice ?? "Unsupported filesystem.")
        }

        // Capacity check.
        let minimumBytes: UInt64 = 32 * 1024 * 1024 * 1024  // 32 GB minimum
        if volume.totalBytes < minimumBytes {
            warnings.append("This drive is only \(volume.formattedCapacity). For best results, use a drive with at least 32 GB.")
        }

        // Available space check.
        let minimumFree: UInt64 = 10 * 1024 * 1024 * 1024  // 10 GB free minimum
        if volume.availableBytes < minimumFree {
            warnings.append("Only \(volume.formattedAvailable) available. Sidecar needs room to store migrated apps.")
        }

        return ValidationResult(
            isReady: issues.isEmpty,
            issues: issues,
            warnings: warnings,
            hasPreviousData: volume.hasSidecarData
        )
    }

    struct ValidationResult: Sendable {
        let isReady: Bool
        let issues: [String]       // Blockers — must fix before proceeding
        let warnings: [String]     // Non-blocking but worth noting
        let hasPreviousData: Bool  // Drive was used with Sidecar before
    }

    /// Create the Sidecar directory structure on the external drive.
    func initializeDrive(at mountPoint: URL) throws {
        let dirs = [
            mountPoint.appendingPathComponent("Applications"),
            mountPoint.appendingPathComponent("Library"),
            mountPoint.appendingPathComponent("Library/Application Support"),
            mountPoint.appendingPathComponent("Library/Caches"),
            mountPoint.appendingPathComponent("Library/Saved Application State"),
            mountPoint.appendingPathComponent("Library/Logs"),
            mountPoint.appendingPathComponent("Library/HTTPStorages"),
            mountPoint.appendingPathComponent("Library/WebKit"),
            mountPoint.appendingPathComponent(".sidecar-meta")
        ]

        for dir in dirs {
            do {
                try fileManager.createDirectory(
                    at: dir,
                    withIntermediateDirectories: true
                )
            } catch {
                throw SetupError.directoryCreationFailed(underlying: error)
            }
        }

        // Write a marker file so we can identify Sidecar drives later.
        let marker = SidecarMarker(
            version: "1.0",
            createdAt: Date(),
            hostName: Host.current().localizedName ?? "Unknown Mac"
        )

        let markerURL = mountPoint
            .appendingPathComponent(".sidecar-meta")
            .appendingPathComponent("sidecar.json")

        if let data = try? JSONEncoder.sidecarSetup.encode(marker) {
            try? data.write(to: markerURL, options: .atomic)
        }
    }

    /// Read the Sidecar marker from a drive (if it exists).
    func readMarker(at mountPoint: URL) -> SidecarMarker? {
        let markerURL = mountPoint
            .appendingPathComponent(".sidecar-meta")
            .appendingPathComponent("sidecar.json")
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return try? JSONDecoder.sidecarSetup.decode(SidecarMarker.self, from: data)
    }

    struct SidecarMarker: Codable, Sendable {
        let version: String
        let createdAt: Date
        let hostName: String
    }

    // MARK: - Filesystem Detection

    /// Detect the filesystem type of a volume.
    /// Uses URL resource values first, falls back to diskutil.
    private func detectFileSystem(at volumeURL: URL) async -> FileSystemType {
        // Try native resource values.
        if let values = try? volumeURL.resourceValues(forKeys: [.volumeLocalizedFormatDescriptionKey]),
           let desc = values.volumeLocalizedFormatDescription?.lowercased() {
            if desc.contains("apfs") { return .apfs }
            if desc.contains("mac os extended") || desc.contains("hfs") { return .hfsPlus }
            if desc.contains("exfat") { return .exfat }
            if desc.contains("fat") { return .fat32 }
            if desc.contains("ntfs") { return .ntfs }
        }

        // Fallback: use diskutil info (this is the one exception to the
        // "prefer native APIs" rule — there's no Swift API for this).
        return await diskutilFileSystem(for: volumeURL)
    }

    /// Parse `diskutil info` output for filesystem type.
    private func diskutilFileSystem(for volumeURL: URL) async -> FileSystemType {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "-plist", volumeURL.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let plist = try PropertyListSerialization.propertyList(
                from: data, format: nil
            ) as? [String: Any] else {
                return .unknown
            }

            if let fsType = plist["FilesystemType"] as? String {
                switch fsType.lowercased() {
                case "apfs":                       return .apfs
                case "hfs", "hfs+", "jhfs+":       return .hfsPlus
                case "exfat":                      return .exfat
                case "msdos":                      return .fat32
                case "ntfs":                       return .ntfs
                default:                           return .unknown
                }
            }
        } catch {
            // Silently fall back.
        }

        return .unknown
    }
}

// MARK: - Coder Helpers

private extension JSONEncoder {
    static let sidecarSetup: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted]
        return e
    }()
}

private extension JSONDecoder {
    static let sidecarSetup: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
