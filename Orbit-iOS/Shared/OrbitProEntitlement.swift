import Foundation

/// Lightweight, StoreKit-free view of the Orbit Pro entitlement.
///
/// The app (iOS, tvOS, macOS) verifies the purchase with StoreKit 2 in `OrbitProStore` every time it
/// launches or becomes active, and mirrors the result into the shared App Group so that widgets,
/// Control Center controls and Siri intents (which run in other processes) can honour it.
/// The cached flag is never treated as proof of purchase by the app itself.
enum OrbitProEntitlement {
    static let productID = "com.dimitrie.orbit.pro"
    static let appGroupID = "group.com.dimitrie.orbit"
    static let cacheKey = "orbit.pro.unlocked"
    /// Saved PC profiles allowed without Orbit Pro.
    static let freePCLimit = 1
    static let upgradeURL = URL(string: "orbit://pro")!
    static let requiredMessage = "This action needs Orbit Pro. Open Orbit to unlock it."

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupID) }

    /// Last verified state, as written by the app. `false` when unknown.
    static var cachedIsUnlocked: Bool {
        #if DEBUG
        if let forced = UserDefaults.standard.object(forKey: "orbit.pro.debugOverride") as? Bool { return forced }
        #endif
        return defaults?.bool(forKey: cacheKey) ?? false
    }

    static func storeVerifiedState(_ unlocked: Bool) {
        defaults?.set(unlocked, forKey: cacheKey)
    }

    /// Whether another PC may be added when `existingCount` profiles are already saved.
    static func canAddPC(existingCount: Int, isUnlocked: Bool) -> Bool {
        isUnlocked || existingCount < freePCLimit
    }
}

struct OrbitProRequiredError: LocalizedError {
    var errorDescription: String? { OrbitProEntitlement.requiredMessage }
}

/// Thrown when a free user tries to save a second PC.
struct OrbitProPCLimitError: LocalizedError {
    var errorDescription: String? {
        "Orbit Pro lets you save more than one PC. Remove the saved PC, or unlock Orbit Pro to add another."
    }
}
