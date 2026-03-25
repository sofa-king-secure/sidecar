import Foundation

/// Monitors the availability of the user-configured external volume
/// and exposes its mount state.
///
/// Per PRD: only run migration logic when the configured external volume is mounted.
/// Per TECH_SPECS: handle "Drive Disconnected" gracefully with user notification.
final class VolumeMonitor: @unchecked Sendable {

    // MARK: - Types

    enum VolumeState: Equatable, Sendable {
        case mounted(path: URL)
        case missing
    }

    // MARK: - Properties

    /// The volume name the user configured (e.g. "SidecarDrive").
    private let volumeName: String

    /// Callback invoked on volume state changes.
    private let onStateChange: @Sendable (VolumeState) -> Void

    /// Current state — safe to read from main thread.
    private(set) var state: VolumeState = .missing

    private var mountObserver: NSObjectProtocol?
    private var unmountObserver: NSObjectProtocol?

    // MARK: - Init

    init(
        volumeName: String,
        onStateChange: @escaping @Sendable (VolumeState) -> Void
    ) {
        self.volumeName = volumeName
        self.onStateChange = onStateChange
    }

    deinit {
        stop()
    }

    // MARK: - Public API

    /// Performs an initial mount check, then subscribes to workspace
    /// mount/unmount notifications.
    func start() {
        // Initial check via native FileManager volume enumeration.
        refreshMountState()

        let center = NSWorkspace.shared.notificationCenter

        mountObserver = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleMount(notification)
        }

        unmountObserver = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleUnmount(notification)
        }
    }

    /// Remove observers.
    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        if let obs = mountObserver { center.removeObserver(obs) }
        if let obs = unmountObserver { center.removeObserver(obs) }
        mountObserver = nil
        unmountObserver = nil
    }

    // MARK: - State

    /// Scans currently mounted volumes using native `FileManager` API.
    func refreshMountState() {
        let volumeURLs = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []

        for url in volumeURLs {
            if let name = try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName,
               name == volumeName {
                transition(to: .mounted(path: url))
                return
            }
        }

        transition(to: .missing)
    }

    /// The expected root path for migrated apps on the external volume.
    var externalAppsDirectory: URL? {
        guard case .mounted(let path) = state else { return nil }
        return path.appendingPathComponent("Applications", isDirectory: true)
    }

    // MARK: - Notifications

    private func handleMount(_ notification: Notification) {
        guard let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else {
            return
        }
        if let name = try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName,
           name == volumeName {
            transition(to: .mounted(path: url))
        }
    }

    private func handleUnmount(_ notification: Notification) {
        guard let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else {
            return
        }
        if let name = try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName,
           name == volumeName {
            transition(to: .missing)
        }
    }

    // MARK: - Helpers

    private func transition(to newState: VolumeState) {
        guard state != newState else { return }
        state = newState
        onStateChange(newState)
    }
}
