import Foundation

/// Analyzes disk state and provides context for migration decisions.
/// Simplified in v0.3 — scoring is less important now that we show
/// per-app item selection. Mainly provides disk state info.
struct DiskAnalyzer {

    struct DiskState: Sendable {
        let totalBytes: UInt64
        let availableBytes: UInt64
        let usedBytes: UInt64

        var usedPercentage: Double {
            guard totalBytes > 0 else { return 0 }
            return Double(usedBytes) / Double(totalBytes) * 100.0
        }

        var formattedAvailable: String {
            ByteCountFormatter.string(fromByteCount: Int64(availableBytes), countStyle: .file)
        }

        var formattedTotal: String {
            ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
        }
    }

    /// Read current disk state for the boot volume.
    func currentDiskState() -> DiskState {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? homeURL.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]) else {
            return DiskState(totalBytes: 0, availableBytes: 0, usedBytes: 0)
        }

        let total = UInt64(values.volumeTotalCapacity ?? 0)
        let available = UInt64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        let used = total > available ? total - available : 0

        return DiskState(totalBytes: total, availableBytes: available, usedBytes: used)
    }
}
