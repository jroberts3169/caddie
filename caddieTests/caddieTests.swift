//
//  caddieTests.swift
//  caddieTests
//
//  Created by Jeff Roberts on 7/1/26.
//

import Testing
@testable import caddie

@MainActor
struct LRUCacheTests {

    @Test func storesAndReadsValues() {
        let cache = LRUCache<String, Int>(capacity: 3)
        cache["a"] = 1
        cache["b"] = 2
        #expect(cache["a"] == 1)
        #expect(cache["b"] == 2)
        #expect(cache.count == 2)
    }

    @Test func evictsLeastRecentlyUsed() {
        let cache = LRUCache<String, Int>(capacity: 2)
        cache["a"] = 1
        cache["b"] = 2
        _ = cache["a"]   // touch "a" → "b" becomes least-recently-used
        cache["c"] = 3   // over capacity → evicts "b"
        #expect(cache["b"] == nil)
        #expect(cache["a"] == 1)
        #expect(cache["c"] == 3)
        #expect(cache.count == 2)
    }

    @Test func capacityOneAlwaysEvictsPrevious() {
        let cache = LRUCache<String, Int>(capacity: 1)
        cache["a"] = 1
        cache["b"] = 2
        #expect(cache["a"] == nil)
        #expect(cache["b"] == 2)
        #expect(cache.count == 1)
    }

    @Test func assigningNilRemovesKey() {
        let cache = LRUCache<String, Int>(capacity: 5)
        cache["x"] = 42
        cache["x"] = nil
        #expect(cache["x"] == nil)
        #expect(cache.count == 0)
    }

    @Test func updatingExistingKeyKeepsSingleEntry() {
        let cache = LRUCache<String, Int>(capacity: 5)
        cache["x"] = 1
        cache["x"] = 2
        #expect(cache["x"] == 2)
        #expect(cache.count == 1)
    }

    @Test func removeValueReturnsAndClearsEntry() {
        let cache = LRUCache<String, Int>(capacity: 5)
        cache["x"] = 7
        #expect(cache.removeValue(forKey: "x") == 7)
        #expect(cache["x"] == nil)
    }

    @Test func removeAllClearsCache() {
        let cache = LRUCache<String, Int>(capacity: 5)
        cache["a"] = 1
        cache["b"] = 2
        cache.removeAll()
        #expect(cache.count == 0)
        #expect(cache["a"] == nil)
    }
}
