import AppKit
import SwiftUI

/// A SwiftUI view that shows a per-item checklist for migration.
/// Presented in its own NSWindow from the menu bar "Scan & Migrate" action.
struct MigrationPickerView: View {

    let results: [LibraryScanner.AppScanResult]
    let onConfirm: ([LibraryScanner.MigratableItem]) -> Void
    let onCancel: () -> Void

    @State private var selectedIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.plus")
                    .font(.system(size: 36))
                    .foregroundColor(.accentColor)

                Text("Select Items to Migrate")
                    .font(.title2.bold())

                Text("Check the items you want to move to your external drive. Apps stay in /Applications — only data subdirectories move.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 450)
            }
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            // Item list
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(results, id: \.id) { result in
                        appSection(result)
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 350)

            Divider()

            // Footer with totals and buttons
            HStack {
                let selectedItems = allItems.filter { selectedIDs.contains($0.id) }
                let totalBytes = selectedItems.reduce(0) { $0 + $1.sizeBytes }
                let formatted = ByteCountFormatter.string(
                    fromByteCount: Int64(totalBytes), countStyle: .file
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(selectedItems.count) of \(allItems.count) selected")
                        .font(.callout.bold())
                    Text("\(formatted) will move to external drive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)

                Button("Migrate Selected") {
                    let items = allItems.filter { selectedIDs.contains($0.id) }
                    onConfirm(items)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIDs.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 520, height: 500)
        .onAppear {
            // Pre-select all items by default
            selectedIDs = Set(allItems.map(\.id))
        }
    }

    // MARK: - App Section

    private func appSection(_ result: LibraryScanner.AppScanResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // App header with select all / deselect all
            HStack {
                Text(result.appName)
                    .font(.headline)

                Spacer()

                let appItemIDs = Set(result.migratableItems.map(\.id))
                let allSelected = appItemIDs.isSubset(of: selectedIDs)

                Button(allSelected ? "Deselect All" : "Select All") {
                    if allSelected {
                        selectedIDs.subtract(appItemIDs)
                    } else {
                        selectedIDs.formUnion(appItemIDs)
                    }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }

            // Items
            ForEach(result.migratableItems, id: \.id) { item in
                itemRow(item)
            }

            Divider()
                .padding(.top, 4)
        }
    }

    // MARK: - Item Row

    private func itemRow(_ item: LibraryScanner.MigratableItem) -> some View {
        let isSelected = selectedIDs.contains(item.id)

        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .font(.title3)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent)
                    .font(.callout)
                Text(item.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(item.formattedSize)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected {
                selectedIDs.remove(item.id)
            } else {
                selectedIDs.insert(item.id)
            }
        }
    }

    // MARK: - Helpers

    private var allItems: [LibraryScanner.MigratableItem] {
        results.flatMap(\.migratableItems)
    }
}

// MARK: - Window Presenter

/// Opens the migration picker as a standalone NSWindow.
/// Returns the selected items (empty if cancelled).
@MainActor
func showMigrationPicker(
    results: [LibraryScanner.AppScanResult]
) async -> [LibraryScanner.MigratableItem] {
    await withCheckedContinuation { continuation in
        var window: NSWindow?

        let view = MigrationPickerView(
            results: results,
            onConfirm: { items in
                window?.close()
                continuation.resume(returning: items)
            },
            onCancel: {
                window?.close()
                continuation.resume(returning: [])
            }
        )

        let hostingController = NSHostingController(rootView: view)
        let newWindow = NSWindow(contentViewController: hostingController)
        newWindow.title = "Sidecar — Migrate Data"
        newWindow.styleMask = [.titled, .closable]
        newWindow.setContentSize(NSSize(width: 520, height: 550))
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window = newWindow
    }
}
