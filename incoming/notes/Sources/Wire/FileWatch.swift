import Foundation

/// Calls `changed` on a background queue when a file is created, replaced, edited or removed.
/// kqueue on its folder sees it appear, go, or be swapped in by an atomic save; on the file itself,
/// edits in place, emptying included. When the file is a symbolic link, the folder of the file it
/// points to is watched as well. The events of one save are let settle for a moment and then
/// reported once: a save in place empties the file before writing it, and that moment is not one
/// to report. A folder that is missing is looked for again every few seconds.
public final class FileWatch: @unchecked Sendable {
    private let file: URL
    private let changed: @Sendable () -> Void
    private let queue = DispatchQueue(label: "Wire.FileWatch")
    // Touched only on `queue`.
    private var folders: [DispatchSourceFileSystemObject] = []
    private var watched: DispatchSourceFileSystemObject?
    private var retrying = false
    private var settling = false
    private var stopped = false

    public init(_ file: URL, changed: @escaping @Sendable () -> Void) {
        self.file = file
        self.changed = changed
        queue.sync { rewatch() }
    }

    /// Watches the folders on the way to the file, and the file itself, again. A source follows one
    /// inode, and saves, removals and a link pointed elsewhere all put new ones in place.
    private func rewatch() {
        folders.forEach { $0.cancel() }
        folders = []
        var paths = [file.deletingLastPathComponent().path]
        var target = file
        for _ in 0..<8 {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: target.path) else { break }
            target = URL(fileURLWithPath: destination, relativeTo: target.deletingLastPathComponent()).standardizedFileURL
            paths.append(target.deletingLastPathComponent().path)
        }
        var missing = false
        for path in Set(paths) {
            guard let source = source(path, [.write, .delete, .rename], { [weak self] _ in
                self?.rewatch()
                self?.settle()
            }) else {
                missing = true
                continue
            }
            folders.append(source)
        }
        watchFile()
        if missing && !retrying {
            retrying = true
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, !self.stopped else { return }
                self.retrying = false
                self.rewatch()
                self.changed()
            }
        }
    }

    /// The file itself. When it is there but may not be opened, the source it had is kept, so the
    /// permission coming back is still seen.
    private func watchFile() {
        // Emptying a file in place only changes its attributes.
        let source = source(file.path, [.write, .extend, .attrib, .delete, .rename]) { [weak self] events in
            if !events.isDisjoint(with: [.delete, .rename]) { self?.rewatch() }
            self?.settle()
        }
        guard source != nil || errno != EACCES else { return }
        watched?.cancel()
        watched = source
    }

    /// Calls `changed` 50 ms after the first of a run of events. The wait is not put off by later
    /// ones, so a steady stream of them can't hold it back; one coming after the call schedules
    /// another, so the last call always follows the last event.
    private func settle() {
        guard !settling else { return }
        settling = true
        queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            guard let self, !self.stopped else { return }
            self.settling = false
            self.changed()
        }
    }

    private func source(_ path: String, _ mask: DispatchSource.FileSystemEvent,
                        _ handler: @escaping (DispatchSource.FileSystemEvent) -> Void) -> DispatchSourceFileSystemObject? {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: mask, queue: queue)
        source.setEventHandler { [weak source] in handler(source?.data ?? []) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    public func stop() {
        queue.sync {
            stopped = true
            folders.forEach { $0.cancel() }
            watched?.cancel()
            folders = []
            watched = nil
        }
    }

    deinit {
        folders.forEach { $0.cancel() }
        watched?.cancel()
    }
}
