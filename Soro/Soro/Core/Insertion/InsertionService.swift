import Foundation

/// Result of a text-insertion attempt (brief §3e, App C).
enum InsertionResult: Sendable {
    case pasted, typed, failedSecureInput, failed
}

/// Inserts text at the cursor via pasteboard ⌘V with restore; typing fallback.
/// Implemented in M3.
protocol InsertionService: AnyObject {
    @discardableResult func insert(_ text: String) async -> InsertionResult
    func reinsertLast() async -> InsertionResult
}

/// M1 stub — no-ops and reports failure (nothing to insert into yet).
final class StubInsertionService: InsertionService {
    private var last: String?

    @discardableResult
    func insert(_ text: String) async -> InsertionResult {
        last = text
        return .failed
    }

    func reinsertLast() async -> InsertionResult {
        last != nil ? .failed : .failed
    }
}
