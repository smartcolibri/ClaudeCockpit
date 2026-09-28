import Foundation

/// Watches one or more directories with kernel events and emits a debounced
/// tick whenever something changes underneath them. Not recursive: pass the
/// directories whose direct entries matter (the callers re-scan anyway).
///
/// A directory that does not exist yet cannot be watched — `open(2)` fails and
/// it is skipped. Whenever at least one directory is unwatched (a fresh user with
/// no `~/.claude/skills`, or a watched directory that was deleted or renamed
/// away), a polling timer runs every `pollingInterval` seconds: it re-tries
/// `open(2)`, attaching real watchers as the directories (re)appear, and stops
/// once they all have one. A poll yields only when it attached a directory, or
/// when nothing at all is watched — then the stream still ticks on every poll,
/// or a `for await` over `changes` would block forever. A poll that attached
/// nothing while other directories are watched stays silent, so a permanently
/// absent directory does not force a re-scan every interval.
public final class DirectoryWatcher: @unchecked Sendable {
    public let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let directories: [URL]
    private let queue = DispatchQueue(label: "fr.vincentlauriat.claudecockpit.watcher")
    private let debounce: TimeInterval
    private let pollingInterval: TimeInterval

    /// Guards every mutable field below: `stop()` may be called from any thread
    /// while the polling timer is attaching sources on `queue`.
    private let lock = NSLock()
    /// One kernel source per watched path. Each source closes its own descriptor
    /// in its cancel handler, so cancelling it is the only cleanup needed.
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var poller: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    private var stopped = false

    /// - Parameters:
    ///   - directories: the directories to watch; missing ones are polled for.
    ///   - debounce: how long to coalesce a burst of kernel events.
    ///   - pollingInterval: retry period used while some directory is not
    ///     watched. Lower it in tests.
    public init(directories: [URL], debounce: TimeInterval = 0.5, pollingInterval: TimeInterval = 60) {
        self.directories = directories
        self.debounce = debounce
        self.pollingInterval = pollingInterval
        var cont: AsyncStream<Void>.Continuation!
        changes = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        continuation = cont

        lock.lock()
        for dir in directories { attachLocked(dir) }
        if !allWatchedLocked { startPollingLocked() }
        lock.unlock()
    }

    /// Whether every directory has a kernel source. An empty list never counts as
    /// fully watched, so the stream still ticks. Caller holds `lock`.
    private var allWatchedLocked: Bool {
        !directories.isEmpty && directories.allSatisfy { sources[$0.path] != nil }
    }

    /// Opens `dir` and arms a kernel source on it. Caller holds `lock`.
    private func attachLocked(_ dir: URL) {
        let path = dir.path
        guard !stopped, sources[path] == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib, .extend],
            queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                self.detach(path, source: source)
            }
            self.schedule()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        sources[path] = source
    }

    /// The watched directory was deleted or renamed away: its descriptor now
    /// points at a dead vnode. Drop it and poll until the path exists again.
    private func detach(_ path: String, source: DispatchSourceFileSystemObject) {
        lock.lock()
        guard !stopped, sources[path] === source else { return lock.unlock() }
        sources[path] = nil
        startPollingLocked()
        lock.unlock()
        source.cancel()
    }

    /// Caller holds `lock`.
    private func startPollingLocked() {
        guard !stopped, poller == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollingInterval, repeating: pollingInterval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        poller = timer
    }

    /// One fallback tick: retry the directories that are still unwatched and stop
    /// polling once every one of them has a real source. Yields when a directory
    /// was just attached (its contents are new to the caller) or when nothing is
    /// watched at all (the stream's only heartbeat).
    private func poll() {
        lock.lock()
        guard !stopped else { return lock.unlock() }
        let watchedBefore = sources.count
        for dir in directories { attachLocked(dir) }
        let shouldYield = sources.count > watchedBefore || sources.isEmpty
        if allWatchedLocked {
            poller?.cancel()
            poller = nil
        }
        lock.unlock()
        if shouldYield { continuation.yield() }
    }

    /// Whether the fallback timer is running. Exposed for tests.
    var isPolling: Bool {
        lock.lock()
        defer { lock.unlock() }
        return poller != nil
    }

    private func schedule() {
        lock.lock()
        guard !stopped else { return lock.unlock() }
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.continuation.yield() }
        pending = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    public func stop() {
        lock.lock()
        stopped = true
        pending?.cancel()
        pending = nil
        poller?.cancel()
        poller = nil
        let openSources = Array(sources.values)
        sources.removeAll()
        lock.unlock()

        openSources.forEach { $0.cancel() }
        continuation.finish()
    }

    deinit { stop() }
}
