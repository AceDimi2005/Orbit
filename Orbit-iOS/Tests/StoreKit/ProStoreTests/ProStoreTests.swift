import StoreKit
import StoreKitTest
import XCTest
@testable import ProHost

/// Exercises the real `OrbitProStore` against Xcode's local StoreKit environment (Orbit.storekit).
@MainActor
final class ProStoreTests: XCTestCase {
    private var session: SKTestSession!
    private var store: OrbitProStore { OrbitProStore.shared }

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "Orbit")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.askToBuyEnabled = false
        session.clearTransactions()
        // Give the local StoreKit service time to drop the previous test's transactions.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        UserDefaults(suiteName: OrbitProEntitlement.appGroupID)?.removeObject(forKey: OrbitProEntitlement.cacheKey)
        UserDefaults.standard.removeObject(forKey: "orbit.pro.debugOverride")
        store.resetForTesting()
    }

    override func tearDown() async throws {
        session.clearTransactions()
        store.resetForTesting()
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
    }

    /// Completes a purchase in the local StoreKit environment without the system sheet (the simulator
    /// here asks for an Apple Account on `product.purchase()`); the store then receives it exactly like a
    /// real purchase, through `Transaction.updates`.
    private func buy() async throws {
        _ = try await session.buyProduct(identifier: OrbitProEntitlement.productID)
        await waitUntil { store.isProUnlocked }
        // The listener-specific behaviour is covered by test09; here we only need to own Pro.
        if !store.isProUnlocked { await store.refreshEntitlements() }
    }

    func test01_freshInstallIsLocked() async {
        store.start()
        await store.refreshEntitlements()
        XCTAssertTrue(store.hasVerifiedEntitlements)
        XCTAssertFalse(store.isProUnlocked, "Pro must start locked without a purchase")
        XCTAssertFalse(OrbitProEntitlement.cachedIsUnlocked, "widgets must see Pro as locked")
        XCTAssertTrue(OrbitProEntitlement.canAddPC(existingCount: 0, isUnlocked: false), "first PC is free")
        XCTAssertFalse(OrbitProEntitlement.canAddPC(existingCount: 1, isUnlocked: false), "second PC needs Pro")
        XCTAssertTrue(OrbitProEntitlement.canAddPC(existingCount: 5, isUnlocked: true))
    }

    func test02_productLoadsWithStorefrontPrice() async {
        await store.loadProducts()
        XCTAssertEqual(store.productState, .loaded)
        XCTAssertEqual(store.product?.id, OrbitProEntitlement.productID)
        XCTAssertEqual(store.product?.type, .nonConsumable)
        let price = store.displayPrice ?? ""
        XCTAssertFalse(price.isEmpty)
        print("ORBIT_TEST displayPrice=\(price) storefront=\(session.storefront)")
    }

    func test03_purchaseUnlocksAndFinishes() async throws {
        store.start()
        try await buy()
        XCTAssertTrue(store.isProUnlocked)
        XCTAssertTrue(OrbitProEntitlement.cachedIsUnlocked)
        let transactions = session.allTransactions()
        XCTAssertEqual(transactions.count, 1)
        XCTAssertEqual(transactions.first?.productIdentifier, OrbitProEntitlement.productID)
        var unfinished = 0
        for await _ in Transaction.unfinished { unfinished += 1 }
        XCTAssertEqual(unfinished, 0, "every verified transaction must be finished")
    }

    func test04_refundLocksAgain() async throws {
        store.start()
        try await buy()
        XCTAssertTrue(store.isProUnlocked)
        let id = try XCTUnwrap(session.allTransactions().first?.identifier)
        try session.refundTransaction(identifier: id)
        await waitUntil { !store.isProUnlocked }
        XCTAssertFalse(store.isProUnlocked, "a refund delivered through Transaction.updates must relock Pro")
        XCTAssertFalse(OrbitProEntitlement.cachedIsUnlocked)
    }

    func test05_refundWhileClosedIsCaughtAtNextLaunch() async throws {
        store.start()
        try await buy()
        let id = try XCTUnwrap(session.allTransactions().first?.identifier)
        store.resetForTesting()                       // app quits
        UserDefaults(suiteName: OrbitProEntitlement.appGroupID)?.set(true, forKey: OrbitProEntitlement.cacheKey)
        try session.refundTransaction(identifier: id) // refunded while closed
        try await Task.sleep(nanoseconds: 1_000_000_000) // let the local StoreKit service record the refund
        store.resetForTesting()
        await store.refreshEntitlements()             // next launch verifies again
        XCTAssertFalse(store.isProUnlocked, "launch-time verification must ignore a stale cache")
        XCTAssertFalse(OrbitProEntitlement.cachedIsUnlocked)
    }

    func test06_relaunchKeepsPurchase() async throws {
        store.start()
        try await buy()
        store.resetForTesting()
        UserDefaults(suiteName: OrbitProEntitlement.appGroupID)?.removeObject(forKey: OrbitProEntitlement.cacheKey)
        store.start()
        await store.refreshEntitlements()
        XCTAssertTrue(store.isProUnlocked, "an owned purchase must be found again at launch without any cache")
    }

    func test07_restorePurchases() async throws {
        store.start()
        try await buy()
        store.resetForTesting()
        UserDefaults(suiteName: OrbitProEntitlement.appGroupID)?.removeObject(forKey: OrbitProEntitlement.cacheKey)
        await store.restorePurchases()
        XCTAssertTrue(store.isProUnlocked)
        XCTAssertEqual(store.statusMessage, "Orbit Pro restored.")
    }

    func test08_restoreWithoutPurchaseStaysLocked() async {
        await store.restorePurchases()
        XCTAssertFalse(store.isProUnlocked)
        XCTAssertEqual(store.statusMessage, "No Orbit Pro purchase was found for this Apple Account.")
    }

    func test09_purchaseMadeElsewhereArrivesThroughUpdates() async throws {
        store.start()
        await store.refreshEntitlements()
        XCTAssertFalse(store.isProUnlocked)
        try await session.buyProduct(identifier: OrbitProEntitlement.productID)   // e.g. bought on Apple TV or Mac
        await waitUntil { store.isProUnlocked }
        XCTAssertTrue(store.isProUnlocked, "Transaction.updates must unlock purchases made outside this screen")
    }
}
