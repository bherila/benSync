import Foundation

public enum RetryPolicy {
    /// Zero failures still uses the minimum delay, avoiding a tight retry loop.
    public static func delay(failures: Int) -> TimeInterval {
        min(1800, 30 * pow(2, Double(min(6, max(0, failures)))))
    }
}
