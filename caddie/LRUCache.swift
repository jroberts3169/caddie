//
//  LRUCache.swift
//  caddie
//

import Foundation

/// A small, bounded least-recently-used cache.
///
/// Held in SwiftUI `@State` as a **reference type** on purpose: every read updates
/// recency (an LRU touch), and a value-type cache would reassign the `@State` on each
/// touch and needlessly invalidate the view. A class is mutated in place, so the
/// stored reference never changes and SwiftUI is not redrawn by a lookup. `@State`
/// here only gives the instance a stable lifetime across body recomputations.
///
/// MainActor-isolated (the project default, `SWIFT_DEFAULT_ACTOR_ISOLATION =
/// MainActor`), so all access is serialized on the main actor and the cache needs no
/// locking. Ordering is a plain array (LRU at index 0, MRU at the end); touch/insert
/// are O(n), which is negligible at the capacities used here.
@MainActor
final class LRUCache<Key: Hashable, Value> {
    private var storage: [Key: Value] = [:]
    private var order: [Key] = []
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { storage.count }

    /// Look up (touching recency on a hit) or insert/update. Assigning `nil` removes
    /// the key. Inserting past `capacity` evicts the least-recently-used entries.
    subscript(key: Key) -> Value? {
        get {
            guard let value = storage[key] else { return nil }
            touch(key)
            return value
        }
        set {
            guard let newValue else {
                removeValue(forKey: key)
                return
            }
            storage[key] = newValue
            touch(key)
            evictIfNeeded()
        }
    }

    @discardableResult
    func removeValue(forKey key: Key) -> Value? {
        order.removeAll { $0 == key }
        return storage.removeValue(forKey: key)
    }

    func removeAll() {
        storage.removeAll()
        order.removeAll()
    }

    private func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
    }

    private func evictIfNeeded() {
        while storage.count > capacity, let oldest = order.first {
            order.removeFirst()
            storage.removeValue(forKey: oldest)
            osmLog("L1 evict \(oldest); size→\(storage.count)")
        }
    }
}
