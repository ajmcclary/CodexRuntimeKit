import Foundation

/// Pure, deterministic exponential-backoff policy for retrying overloaded
/// (`-32001`) Codex app-server requests. Jitter is injected (no RNG) so the
/// schedule is unit-testable.
public struct CodexBackoffPolicy: Sendable, Equatable {
	/// JSON-RPC error code Codex app-server returns when overloaded; retried with backoff.
	public static let overloadErrorCode = -32001

	public let maxRetries: Int
	public let baseDelay: TimeInterval
	public let multiplier: Double
	public let maxDelay: TimeInterval

	public static let `default` = CodexBackoffPolicy(maxRetries: 3, baseDelay: 0.5, multiplier: 2.0, maxDelay: 8.0)

	public init(maxRetries: Int, baseDelay: TimeInterval, multiplier: Double, maxDelay: TimeInterval) {
		self.maxRetries = maxRetries
		self.baseDelay = baseDelay
		self.multiplier = multiplier
		self.maxDelay = maxDelay
	}

	/// Delay before the given zero-based retry attempt. `jitterFraction` in [0, 1]
	/// adds that fraction of `baseDelay`; pass 0 for a deterministic schedule.
	public func delay(forAttempt attempt: Int, jitterFraction: Double) -> TimeInterval {
		let exponential = baseDelay * pow(multiplier, Double(attempt))
		let capped = min(exponential, maxDelay)
		return min(capped + jitterFraction * baseDelay, maxDelay)
	}

	/// Delay before retrying a failed request, or nil if it should not be retried.
	/// Retries only overloaded (`-32001`) responses while attempts remain.
	public func retryDelay(for error: Error, attempt: Int) -> TimeInterval? {
		guard case let .rpcError(code, _) = error as? CodexClientError,
			code == Self.overloadErrorCode,
			attempt < maxRetries else {
			return nil
		}
		return delay(forAttempt: attempt, jitterFraction: 0)
	}
}
