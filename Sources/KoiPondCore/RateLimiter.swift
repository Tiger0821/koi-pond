/// Lets an action through at most once per `interval`, whatever the rate it's asked for.
public struct RateLimiter: Sendable {
    public let interval: Double
    private var last: Double?

    public init(interval: Double) {
        self.interval = interval
    }

    /// Whether the action may happen at `time` (seconds, any clock); if so, it counts as done.
    public mutating func allow(at time: Double) -> Bool {
        if let last, time - last < interval { return false }
        last = time
        return true
    }
}
