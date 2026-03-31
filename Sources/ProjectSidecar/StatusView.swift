import AppKit
import SwiftUI

/// Shows the current state of all migrations: what's on the external drive,
/// symlink health, sizes, and rollback options.
struct StatusView: View {

    let manifest: MigrationManifest
    let driveName: String
    let driveConnected: Bool
    let diskState: DiskAnalyzer.DiskState
    let onRollback: (String, String) -> Void  // (recordID, itemPath)
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    driveStatusCard
                    diskUsageCard

                    if activeRecords.isEmpty {
                        emptyState
                    } else {
                        ForEach(activeRecords, id: \.id) { record in
                            appCard(record)
                        }
                    }

                    if !rolledBackRecords.isEmpty {
                        historySection
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer
            HStack {
                Text("\(totalMigratedItems) item(s) on external drive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { onClose() }
            }
            .padding(16)
        }
        .frame(width: 560, height: 600)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill.badge.checkmark")
                .font(.system(size: 28))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Sidecar Status")
                    .font(.title2.bold())
                Text("Migration overview and health check")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(20)
    }

    // MARK: - Drive Status

    private var driveStatusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: driveConnected
                  ? "externaldrive.fill.badge.checkmark"
                  : "externaldrive.fill.badge.xmark")
                .font(.title2)
                .foregroundColor(driveConnected ? .green : .red)

            VStack(alignment: .leading, spacing: 2) {
                Text(driveName)
                    .font(.callout.bold())
                Text(driveConnected ? "Connected" : "Disconnected")
                    .font(.caption)
                    .foregroundColor(driveConnected ? .green : .red)
            }

            Spacer()

            if driveConnected {
                Text(totalMigratedFormatted)
                    .font(.callout.monospacedDigit().bold())
                    .foregroundColor(.accentColor)
                Text("on drive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }

    // MARK: - Disk Usage

    private var diskUsageCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Internal Drive")
                    .font(.caption.bold())
                Spacer()
                Text("\(diskState.formattedAvailable) free of \(diskState.formattedTotal)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(usageBarColor)
                        .frame(width: geo.size.width * CGFloat(diskState.usedPercentage / 100.0))
                }
            }
            .frame(height: 8)

            Text("\(Int(diskState.usedPercentage))% used")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }

    private var usageBarColor: Color {
        let pct = diskState.usedPercentage
        if pct >= 90 { return .red }
        if pct >= 75 { return .orange }
        return .green
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No active migrations")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Use \"Scan & Migrate\" to move app data to your external drive.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    // MARK: - App Card

    private func appCard(_ record: MigrationManifest.MigrationRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // App header
            HStack {
                Text(record.appName.replacingOccurrences(of: ".app", with: ""))
                    .font(.headline)

                Spacer()

                let itemCount = record.libraryMigrations.filter(\.isSymlinked).count
                Text("\(itemCount) item(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Each migrated item
            ForEach(record.libraryMigrations.filter(\.isSymlinked), id: \.originalPath) { lib in
                itemRow(lib, recordID: record.id)
            }

            // Migration date
            if let dateStr = formatDate(record.migratedAt) {
                Text("Migrated: \(dateStr)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.06))
        .cornerRadius(8)
    }

    private func itemRow(
        _ lib: MigrationManifest.LibraryMigrationRecord,
        recordID: String
    ) -> some View {
        let health = checkHealth(lib)
        let shortPath = lib.originalPath
            .replacingOccurrences(of: "/Users/\(NSUserName())/Library/", with: "~/Library/")

        return HStack(spacing: 8) {
            Image(systemName: health.icon)
                .foregroundColor(health.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: lib.originalPath).lastPathComponent)
                    .font(.callout)
                Text(shortPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(ByteCountFormatter.string(fromByteCount: Int64(lib.sizeBytes), countStyle: .file))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Text(health.label)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(health.color.opacity(0.15))
                .foregroundColor(health.color)
                .cornerRadius(4)
        }
        .padding(.vertical, 4)
    }

    // MARK: - History (Rolled Back)

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            ForEach(rolledBackRecords, id: \.id) { record in
                HStack {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .foregroundStyle(.secondary)
                    Text(record.appName.replacingOccurrences(of: ".app", with: ""))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("— rolled back")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(Color.gray.opacity(0.04))
        .cornerRadius(8)
    }

    // MARK: - Health Check

    struct HealthStatus {
        let icon: String
        let label: String
        let color: Color
    }

    private func checkHealth(_ lib: MigrationManifest.LibraryMigrationRecord) -> HealthStatus {
        let path = lib.originalPath
        let fm = FileManager.default

        // Check if the path exists at all
        guard fm.fileExists(atPath: path) else {
            return HealthStatus(icon: "xmark.circle.fill", label: "Missing", color: .red)
        }

        // Check if it's a symlink
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let type = attrs[.type] as? FileAttributeType,
              type == .typeSymbolicLink else {
            // Exists but not a symlink — app may have recreated it
            return HealthStatus(icon: "exclamationmark.triangle.fill", label: "Replaced", color: .orange)
        }

        // Check if target is reachable
        if let target = try? fm.destinationOfSymbolicLink(atPath: path),
           fm.fileExists(atPath: target) {
            return HealthStatus(icon: "checkmark.circle.fill", label: "Healthy", color: .green)
        } else {
            if driveConnected {
                return HealthStatus(icon: "xmark.circle.fill", label: "Broken", color: .red)
            } else {
                return HealthStatus(icon: "minus.circle.fill", label: "Drive Off", color: .yellow)
            }
        }
    }

    // MARK: - Computed

    private var activeRecords: [MigrationManifest.MigrationRecord] {
        manifest.activeRecords
    }

    private var rolledBackRecords: [MigrationManifest.MigrationRecord] {
        manifest.allRecords.filter { $0.status == .rolledBack }
    }

    private var totalMigratedItems: Int {
        activeRecords.reduce(0) { $0 + $1.libraryMigrations.filter(\.isSymlinked).count }
    }

    private var totalMigratedBytes: UInt64 {
        activeRecords.reduce(0) { total, record in
            total + record.libraryMigrations.filter(\.isSymlinked).reduce(0) { $0 + $1.sizeBytes }
        }
    }

    private var totalMigratedFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalMigratedBytes), countStyle: .file)
    }

    private func formatDate(_ isoString: Date) -> String? {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: isoString)
    }
}

// MARK: - Window Presenter

@MainActor
func showStatusWindow(
    manifest: MigrationManifest,
    driveName: String,
    driveConnected: Bool,
    diskState: DiskAnalyzer.DiskState
) {
    var statusWindow: NSWindow?

    let view = StatusView(
        manifest: manifest,
        driveName: driveName,
        driveConnected: driveConnected,
        diskState: diskState,
        onRollback: { recordID, itemPath in
            print("[Sidecar] Rollback requested: \(itemPath)")
            // TODO: Wire up rollback
        },
        onClose: {
            statusWindow?.close()
        }
    )

    let hostingController = NSHostingController(rootView: view)
    let window = NSWindow(contentViewController: hostingController)
    window.title = "Sidecar Status"
    window.styleMask = [.titled, .closable]
    window.setContentSize(NSSize(width: 560, height: 600))
    window.center()
    window.isReleasedWhenClosed = false
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    statusWindow = window
}
