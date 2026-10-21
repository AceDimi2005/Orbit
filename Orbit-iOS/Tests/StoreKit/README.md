# Orbit Pro StoreKit tests

Runs the real `Shared/OrbitProStore.swift` against Xcode's local StoreKit environment (`Orbit-iOS/Orbit.storekit`) with `SKTestSession`.

```bash
xcodebuild test -project Orbit-iOS/Tests/StoreKit/ProStoreTests.xcodeproj -scheme ProStoreTests -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

Covered: fresh install locked, free PC limit, product + storefront price, purchase unlocks and every transaction is finished, refund relocks (live and while the app is closed), relaunch keeps the purchase, Restore Purchases (with and without a purchase), purchase made on another device arrives through `Transaction.updates`.

Not automatable here: the system purchase sheet itself (`product.purchase()` asks for an Apple Account in the simulator) and Ask to Buy approval; test those with a Sandbox account on a device. On macOS the local StoreKit environment does not serve products to an unsigned test host.
