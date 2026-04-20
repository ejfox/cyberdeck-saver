import Foundation

/// Process-global cache for stream fetch results. Coalesces duplicate requests
/// across display instances — with N monitors driving N parallel TextEngines,
/// each asking for the same URL at roughly the same time, only one network
/// round-trip actually fires.
///
/// Semantics:
///   - `get(url:maxAge:)` — returns a cached result if its age is ≤ maxAge.
///     Callers pass `refreshInterval * 0.9` or similar so the cache naturally
///     expires slightly before the panel would refetch anyway.
///   - `put(url:result:)` — stores a result with `Date()` timestamp.
///   - Entries are never manually evicted; we just let stale ones sit (they'll
///     be overwritten on the next real fetch). Memory footprint is trivial
///     (~20 URLs × a few KB of JSON each).
///
/// Thread-safe via `NSLock`. Get/put are both O(1) hash lookups.
enum StreamCache {
    private struct Entry {
        let timestamp: Date
        let result: FetchResult
    }

    private static let lock = NSLock()
    private static var entries: [String: Entry] = [:]

    static func get(url: String, maxAge: TimeInterval) -> FetchResult? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[url] else { return nil }
        let age = Date().timeIntervalSince(entry.timestamp)
        return age <= maxAge ? entry.result : nil
    }

    static func put(url: String, result: FetchResult) {
        lock.lock()
        defer { lock.unlock() }
        entries[url] = Entry(timestamp: Date(), result: result)
    }
}
