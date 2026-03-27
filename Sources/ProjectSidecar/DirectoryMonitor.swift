import Foundation

/// Monitors `/Applications` for newly added `.app` bundles using FSEvents.
/// Conforms to CLAUDE.md: uses async/await and native macOS APIs (no shell scripts).
final class DirectoryMonitor: @unchecked Sendable {

    // MARK: - Types

    /// Events emitted when a new .app is detected.
    enum Event {
        case appAdded(url: URL)
        case error(MonitorError)
    }

    enum MonitorError: Error, CustomStringConvertible {
        case streamCreationFailed
        case alreadyRunning
        case permissionDenied(path: String)

        var description: String {
            switch self {
            case .streamCreationFailed:
                return "Failed to create FSEvent stream for /Applications."
            case .alreadyRunning:
                return "Directory monitor is already running."
            case .permissionDenied(let path):
                return "Permission denied accessing \(path). Enable Full Disk Access in System Settings."
            }
        }
    }

    // MARK: - Properties

    private let monitoredPath: String
    private var stream: FSEventStreamRef?
    private let eventHandler: @Sendable (Event) -> Void
    private let appFilter: AppFilter

    /// Tracks known .app bundles so we only emit events for new additions.
    private var knownApps: Set<String>

    // MARK: - Init

    /// - Parameters:
    ///   - path: Directory to monitor (defaults to `/Applications`).
    ///   - appFilter: Filter to exclude system/Apple apps.
    ///   - onEvent: Callback fired on the main queue when an event occurs.
    init(
        path: String = "/Applications",
        appFilter: AppFilter = AppFilter(),
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        self.monitoredPath = path
        self.appFilter = appFilter
        self.eventHandler = onEvent
        self.knownApps = Self.scanExistingApps(in: path)
    }

    // MARK: - Public API

    /// Begin monitoring. Throws if already running or if the stream can't be created.
    func start() throws {
        guard stream == nil else {
            throw MonitorError.alreadyRunning
        }

        // Verify read access before starting.
        guard FileManager.default.isReadableFile(atPath: monitoredPath) else {
            throw MonitorError.permissionDenied(path: monitoredPath)
        }

        let pathsToWatch = [monitoredPath] as CFArray

        // We pass `self` as the context info pointer so the C callback can
        // route events back to our Swift instance.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            DirectoryMonitor.fsEventCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,                                         // 1-second latency coalescing
            UInt32(kFSEventStreamCreateFlagFileEvents |
                   kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            throw MonitorError.streamCreationFailed
        }

        self.stream = newStream
        FSEventStreamSetDispatchQueue(newStream, DispatchQueue.main)
        FSEventStreamStart(newStream)
    }

    /// Stop monitoring and release the FSEvent stream.
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: - FSEvents C Callback

    /// Static callback required by the FSEvents C API. Bridges into the
    /// instance method `handleRawEvents`.
    private static let fsEventCallback: FSEventStreamCallback = {
        (stream, clientInfo, numEvents, eventPaths, eventFlags, eventIds) in

        guard let clientInfo else { return }
        let monitor = Unmanaged<DirectoryMonitor>
            .fromOpaque(clientInfo)
            .takeUnretainedValue()

        guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else {
            return
        }

        let flags = Array(UnsafeBufferPointer(start: eventFlags, count: numEvents))
        monitor.handleRawEvents(paths: paths, flags: flags)
    }

    // MARK: - Event Processing

    /// Processes raw FSEvent paths, detects new `.app` bundles,
    /// and runs them through the filter before emitting.
    private func handleRawEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        for (index, path) in paths.enumerated() {
            let flag = flags[index]

            // We care about item-created or item-renamed (moved in).
            let isCreated = flag & UInt32(kFSEventStreamEventFlagItemCreated) != 0
            let isRenamed = flag & UInt32(kFSEventStreamEventFlagItemRenamed) != 0
            let isDir     = flag & UInt32(kFSEventStreamEventFlagItemIsDir)   != 0

            guard (isCreated || isRenamed) && isDir else { continue }
            guard path.hasSuffix(".app") else { continue }

            // De-duplicate against our known set.
            guard !knownApps.contains(path) else { continue }
            knownApps.insert(path)

            let url = URL(fileURLWithPath: path)

            // Run through the filter (async bridge handled by caller).
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let shouldProcess = try await self.appFilter.shouldProcess(appURL: url)
                    if shouldProcess {
                        self.eventHandler(.appAdded(url: url))
                    }
                } catch {
                    self.eventHandler(.error(.permissionDenied(path: path)))
                }
            }
        }
    }

    // MARK: - Helpers

    /// Snapshot the current contents of the monitored directory so we only
    /// fire events for truly *new* additions.
    private static func scanExistingApps(in directory: String) -> Set<String> {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: directory) else {
            return []
        }
        return Set(
            contents
                .filter { $0.hasSuffix(".app") }
                .map { (directory as NSString).appendingPathComponent($0) }
        )
    }
}
