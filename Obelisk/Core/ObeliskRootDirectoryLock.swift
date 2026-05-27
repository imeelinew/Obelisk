import Foundation

public enum ObeliskStorageLockError: Error {
    case lockFailed
}

/// Cross-process exclusive access to a data root via `flock` on `rootDirectory/.lock`.
/// Reentrant on the same thread so nested store writes (e.g. bookmark + state) do not deadlock.
public enum ObeliskRootDirectoryLock {
    private final class ThreadDepth: @unchecked Sendable {
        var depthByPath: [String: Int] = [:]
    }

    private static let threadDepthKey = "ObeliskRootDirectoryLock.depth"

    private static var currentThreadDepth: ThreadDepth {
        if let existing = Thread.current.threadDictionary[threadDepthKey] as? ThreadDepth {
            return existing
        }
        let depth = ThreadDepth()
        Thread.current.threadDictionary[threadDepthKey] = depth
        return depth
    }

    public static func withExclusiveAccess<T>(
        rootDirectory: URL,
        _ body: () throws -> T
    ) throws -> T {
        let key = rootDirectory.standardizedFileURL.path
        let depths = currentThreadDepth
        if (depths.depthByPath[key] ?? 0) > 0 {
            depths.depthByPath[key, default: 0] += 1
            defer {
                depths.depthByPath[key, default: 1] -= 1
                if depths.depthByPath[key] == 0 {
                    depths.depthByPath.removeValue(forKey: key)
                }
            }
            return try body()
        }

        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let lockURL = rootDirectory.appendingPathComponent(".lock")
        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw ObeliskStorageLockError.lockFailed
        }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {
            throw ObeliskStorageLockError.lockFailed
        }
        defer { _ = flock(fd, LOCK_UN) }

        depths.depthByPath[key] = 1
        defer { depths.depthByPath.removeValue(forKey: key) }
        return try body()
    }
}
