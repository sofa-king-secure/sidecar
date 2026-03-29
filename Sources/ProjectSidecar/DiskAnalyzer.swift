import Foundation

/// Analyzes internal disk usage and prioritizes which apps to migrate
/// based on size, disk pressure, and data category.
///
/// This solves the problem of blindly migrating every app — a 5MB utility
/// doesn't need to move; a 4GB DAW with 20GB of samples absolutely does.
struct DiskAnalyzer {

    // MARK: - Types

    /// Snapshot of the internal drive's state.
    struct DiskState: Sendable {
        let totalBytes: UInt64
        let availableBytes: UInt64
        let usedBytes: UInt64

        var usedPercentage: Double {
            guard totalBytes > 0 else { return 0 }
            return Double(usedBytes) / Double(totalBytes) * 100.0
        }

        var pressure: DiskPressure {
            switch usedPercentage {
            case 90...: return .critical  // < 10% free — urgent
            case 80...: return .high      // < 20% free — should act
            case 65...: return .moderate  // < 35% free — plan ahead
            default:    return .low       // Plenty of room
            }
        }

        var formattedAvailable: String {
            ByteCountFormatter.string(fromByteCount: Int64(availableBytes), countStyle: .file)
        }

        var formattedTotal: String {
            ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file)
        }
    }

    enum DiskPressure: Int, Comparable, Sendable {
        case low = 0
        case moderate = 1
        case high = 2
        case critical = 3

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// A scored migration candidate with reasoning.
    struct MigrationCandidate: Sendable, Identifiable {
        let id: String
        let footprint: LibraryScanner.AppFootprint
        let score: Double           // 0-100, higher = higher priority to migrate
        let reclaimableBytes: UInt64 // How much space we'd actually get back
        let reasoning: String

        var formattedReclaimable: String {
            ByteCountFormatter.string(fromByteCount: Int64(reclaimableBytes), countStyle: .file)
        }
    }

    // MARK: - Configuration

    /// Minimum app footprint (bytes) to even consider for migration.
    /// Apps smaller than this aren't worth the symlink complexity.
    var minimumFootprintBytes: UInt64 = 50 * 1024 * 1024  // 50 MB default

    /// Target: how much free space we'd like to maintain (bytes).
    var targetFreeBytes: UInt64 = 30 * 1024 * 1024 * 1024  // 30 GB default

    // MARK: - Public API

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
        // Use "important usage" metric — more accurate than raw available.
        let available = UInt64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        let used = total > available ? total - available : 0

        return DiskState(totalBytes: total, availableBytes: available, usedBytes: used)
    }

    /// Score and rank all apps by migration priority.
    func prioritize(
        footprints: [LibraryScanner.AppFootprint],
        diskState: DiskState
    ) -> [MigrationCandidate] {
        var candidates: [MigrationCandidate] = []

        for footprint in footprints {
            // Skip tiny apps.
            guard footprint.totalSize >= minimumFootprintBytes else { continue }

            let score = computeScore(footprint: footprint, diskState: diskState)
            let reclaimable = computeReclaimable(footprint: footprint)
            let reasoning = buildReasoning(footprint: footprint, score: score, diskState: diskState)

            candidates.append(MigrationCandidate(
                id: footprint.appBundleURL.path,
                footprint: footprint,
                score: score,
                reclaimableBytes: reclaimable,
                reasoning: reasoning
            ))
        }

        // Sort by score descending.
        candidates.sort { $0.score > $1.score }
        return candidates
    }

    /// Given current disk state, return a recommended migration plan:
    /// which apps to move to hit the target free space.
    func recommendMigrationPlan(
        candidates: [MigrationCandidate],
        diskState: DiskState
    ) -> (toMigrate: [MigrationCandidate], projectedFreeBytes: UInt64) {
        guard diskState.availableBytes < targetFreeBytes else {
            // Already above target — return empty plan.
            return ([], diskState.availableBytes)
        }

        let deficit = targetFreeBytes - diskState.availableBytes
        var accumulated: UInt64 = 0
        var plan: [MigrationCandidate] = []

        for candidate in candidates {
            plan.append(candidate)
            accumulated += candidate.reclaimableBytes
            if accumulated >= deficit { break }
        }

        return (plan, diskState.availableBytes + accumulated)
    }

    // MARK: - Scoring

    /// Compute a 0-100 priority score.
    /// Factors: total size, disk pressure multiplier, cache ratio, library data ratio.
    private func computeScore(
        footprint: LibraryScanner.AppFootprint,
        diskState: DiskState
    ) -> Double {
        var score: Double = 0

        // --- Size factor (0-40 points) ---
        // Logarithmic scale: 100MB=10, 1GB=25, 10GB=40
        let sizeGB = Double(footprint.totalSize) / (1024 * 1024 * 1024)
        let sizeFactor = min(40.0, log10(max(sizeGB, 0.01) * 10 + 1) * 15)
        score += sizeFactor

        // --- Library data ratio (0-25 points) ---
        // Apps with huge Library data relative to bundle size = more to gain.
        let libraryTotal = footprint.libraryItems.reduce(0) { $0 + $1.sizeBytes }
        if footprint.appBundleSize > 0 {
            let ratio = Double(libraryTotal) / Double(footprint.appBundleSize)
            score += min(25.0, ratio * 5)
        }

        // --- Disk pressure multiplier (1.0x - 2.0x) ---
        let pressureMultiplier: Double = {
            switch diskState.pressure {
            case .critical: return 2.0
            case .high:     return 1.5
            case .moderate: return 1.2
            case .low:      return 1.0
            }
        }()

        // --- Symlinkability bonus (0-10 points) ---
        // Higher if most data is safe to symlink (simpler migration).
        let symlinkableBytes = footprint.symlinkableItems.reduce(0) { $0 + $1.sizeBytes }
        if footprint.totalSize > 0 {
            let symlinkRatio = Double(symlinkableBytes) / Double(footprint.totalSize)
            score += symlinkRatio * 10
        }

        return min(100.0, score * pressureMultiplier)
    }

    /// Estimate how many bytes we'd reclaim on the internal drive.
    /// App bundle stays local (v0.2) — only Library data is reclaimable.
    /// Symlink-safe items: full reclaim. Unsafe items (containers):
    /// conservative estimate since we may need to copy, not move.
    private func computeReclaimable(footprint: LibraryScanner.AppFootprint) -> UInt64 {
        var total: UInt64 = 0  // App bundle NOT included — stays on internal drive

        for item in footprint.libraryItems {
            if item.category.symlinkSafe {
                total += item.sizeBytes
            } else {
                // Containers: we can move the data but some apps re-create it.
                // Estimate 70% reclaimable for planning purposes.
                total += UInt64(Double(item.sizeBytes) * 0.7)
            }
        }

        return total
    }

    private func buildReasoning(
        footprint: LibraryScanner.AppFootprint,
        score: Double,
        diskState: DiskState
    ) -> String {
        let appName = footprint.appBundleURL.deletingPathExtension().lastPathComponent
        let totalFormatted = footprint.formattedTotalSize
        let libCount = footprint.libraryItems.count

        var parts: [String] = [
            "\(appName): \(totalFormatted) total footprint"
        ]

        if libCount > 0 {
            let libSize = ByteCountFormatter.string(
                fromByteCount: Int64(footprint.libraryItems.reduce(0) { $0 + $1.sizeBytes }),
                countStyle: .file
            )
            parts.append("\(libCount) Library folders (\(libSize))")
        }

        if !footprint.unsafeItems.isEmpty {
            parts.append("\(footprint.unsafeItems.count) sandboxed container(s) need special handling")
        }

        if diskState.pressure >= .high {
            parts.append("⚠️ Disk pressure is \(diskState.pressure) — migration recommended")
        }

        return parts.joined(separator: " · ")
    }
}
