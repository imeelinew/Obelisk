import Foundation

@MainActor
final class BookmarkFileWatcher {
    private let fileURL: URL
    private let onChange: () -> Void
    private var fileDescriptor: CInt = -1
    private var directoryDescriptor: CInt = -1
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var debounceWorkItem: DispatchWorkItem?
    private var restartPending = false

    init(fileURL: URL, onChange: @escaping () -> Void) {
        self.fileURL = fileURL
        self.onChange = onChange
        start()
    }

    private func start() {
        if restartPending { return }
        let hadSources = fileSource != nil || directorySource != nil
        stop()
        if hadSources {
            // Cancel handlers run on .main; defer reopen to a later main-queue
            // tick so that orphan handlers close their original fds before we
            // open new ones (avoids fd-number reuse closing the wrong fd).
            restartPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.restartPending = false
                self.openSources()
            }
        } else {
            openSources()
        }
    }

    private func openSources() {
        watchFile()
        watchDirectory()
    }

    private func stop() {
        // fds are owned by the dispatch sources; their cancel handlers will
        // close them. Only fall back to a direct close when no source exists.
        if let fileSource {
            fileSource.cancel()
        } else if fileDescriptor >= 0 {
            close(fileDescriptor)
        }

        if let directorySource {
            directorySource.cancel()
        } else if directoryDescriptor >= 0 {
            close(directoryDescriptor)
        }

        fileSource = nil
        directorySource = nil
        fileDescriptor = -1
        directoryDescriptor = -1
    }

    private func watchFile() {
        fileDescriptor = open(fileURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.handleFileEvent()
        }
        source.setCancelHandler { [fileDescriptor] in
            if fileDescriptor >= 0 {
                close(fileDescriptor)
            }
        }
        fileSource = source
        source.resume()
    }

    private func watchDirectory() {
        directoryDescriptor = open(fileURL.deletingLastPathComponent().path, O_EVTONLY)
        guard directoryDescriptor >= 0 else {
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.handleDirectoryEvent()
        }
        source.setCancelHandler { [directoryDescriptor] in
            if directoryDescriptor >= 0 {
                close(directoryDescriptor)
            }
        }
        directorySource = source
        source.resume()
    }

    private func handleFileEvent() {
        let flags = fileSource?.data ?? []
        if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
            start()
        }

        scheduleReload()
    }

    private func handleDirectoryEvent() {
        if fileSource == nil || !FileManager.default.fileExists(atPath: fileURL.path) {
            start()
        }

        scheduleReload()
    }

    private func scheduleReload() {
        debounceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }
}
