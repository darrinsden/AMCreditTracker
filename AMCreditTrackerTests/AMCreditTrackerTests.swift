//
//  AMCreditTrackerTests.swift
//  AMCreditTrackerTests
//
//  Created by Darrin horn on 4/18/26.
//

import Testing
import Foundation
@testable import AMCreditTracker

struct AMCreditTrackerTests {

    private func makeItem(upc: String = "012345678905",
                          price: Decimal = 9.99,
                          quantity: Int = 1) -> ScanSessionStore.InMemoryItem {
        ScanSessionStore.InMemoryItem(
            upc: upc,
            name: "Test item",
            price: price,
            quantity: quantity,
            manualOverride: false,
            overrideNote: nil,
            scannedAt: Date()
        )
    }

    // MARK: Store/store-number lock drives off items.isEmpty

    @Test func storeStateIsEmptyByDefault() {
        let store = ScanSessionStore()
        #expect(store.items.isEmpty)
    }

    @Test func addingItemMakesListNonEmpty() {
        let store = ScanSessionStore()
        store.add(makeItem())
        #expect(!store.items.isEmpty)
        #expect(store.items.count == 1)
    }

    @Test func clearingRestoresEmptyList() {
        let store = ScanSessionStore()
        store.add(makeItem())
        store.add(makeItem(upc: "012345678912"))
        #expect(!store.items.isEmpty)
        store.clear()
        #expect(store.items.isEmpty)
    }

    @Test func removingLastItemRestoresEmptyList() {
        let store = ScanSessionStore()
        let item = makeItem()
        store.add(item)
        store.remove(item)
        #expect(store.items.isEmpty)
    }

    @Test func removingOneOfManyKeepsListNonEmpty() {
        let store = ScanSessionStore()
        let first = makeItem(upc: "012345678905")
        let second = makeItem(upc: "012345678912")
        store.add(first)
        store.add(second)
        store.remove(first)
        #expect(!store.items.isEmpty)
        #expect(store.items.count == 1)
    }

    // MARK: Subtotal math

    @Test func subtotalSumsLineTotals() {
        let store = ScanSessionStore()
        store.add(makeItem(price: 10.00, quantity: 2))
        store.add(makeItem(upc: "012345678912", price: 5.50, quantity: 1))
        #expect(store.subtotal == Decimal(25.50))
    }

    @Test func overLimitFlagsAtThreshold() {
        let store = ScanSessionStore()
        store.add(makeItem(price: 200.00, quantity: 1))
        #expect(store.isOverLimit)
    }
}
