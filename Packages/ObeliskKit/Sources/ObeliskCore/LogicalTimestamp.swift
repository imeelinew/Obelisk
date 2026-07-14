import Foundation

public struct LogicalTimestamp: Codable, Hashable, Comparable, Sendable {
    public var milliseconds: Int64
    public var counter: UInt32
    public var deviceID: UUID

    public init(milliseconds: Int64, counter: UInt32, deviceID: UUID) {
        self.milliseconds = milliseconds
        self.counter = counter
        self.deviceID = deviceID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.milliseconds != rhs.milliseconds {
            return lhs.milliseconds < rhs.milliseconds
        }
        if lhs.counter != rhs.counter {
            return lhs.counter < rhs.counter
        }
        return lhs.deviceID.uuidString < rhs.deviceID.uuidString
    }
}

public struct LogicalClock: Sendable {
    public let deviceID: UUID
    private var lastMilliseconds: Int64
    private var counter: UInt32

    public init(deviceID: UUID, lastMilliseconds: Int64 = 0, counter: UInt32 = 0) {
        self.deviceID = deviceID
        self.lastMilliseconds = lastMilliseconds
        self.counter = counter
    }

    public mutating func tick(now: Date = Date()) -> LogicalTimestamp {
        let milliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        if milliseconds > lastMilliseconds {
            lastMilliseconds = milliseconds
            counter = 0
        } else {
            counter += 1
        }
        return LogicalTimestamp(
            milliseconds: lastMilliseconds,
            counter: counter,
            deviceID: deviceID
        )
    }

    public mutating func observe(_ remote: LogicalTimestamp, now: Date = Date()) -> LogicalTimestamp {
        let localNow = Int64(now.timeIntervalSince1970 * 1_000)
        let maximum = max(localNow, lastMilliseconds, remote.milliseconds)

        switch (maximum == lastMilliseconds, maximum == remote.milliseconds) {
        case (true, true):
            counter = max(counter, remote.counter) + 1
        case (true, false):
            counter += 1
        case (false, true):
            counter = remote.counter + 1
        case (false, false):
            counter = 0
        }

        lastMilliseconds = maximum
        return LogicalTimestamp(
            milliseconds: lastMilliseconds,
            counter: counter,
            deviceID: deviceID
        )
    }
}
