import Foundation
import StoreKit
import SwiftUI
#if os(iOS)
import WidgetKit
#endif

/// Orbit Pro: one non-consumable (`com.dimitrie.orbit.pro`), shared by the iPhone, iPad, Apple TV and
/// Mac apps through universal purchase (same bundle identifier and App Store record).
///
/// Rules:
/// - Everything Pro starts locked; only a StoreKit-verified, non-revoked transaction unlocks it.
/// - Entitlements are re-read from `Transaction.currentEntitlements` on launch and whenever the app
///   becomes active, so a refund or Family Sharing revocation locks Pro again.
/// - `Transaction.updates` is observed for the app's whole lifetime (Ask to Buy approvals, purchases
///   on another device, refunds) and every verified transaction is finished.
@MainActor
final class OrbitProStore: ObservableObject {
    static let shared = OrbitProStore()
    static let productID = OrbitProEntitlement.productID

    enum ProductState: Equatable { case idle, loading, loaded, unavailable }

    @Published private(set) var isProUnlocked: Bool
    /// `true` once the current launch has read the entitlements from StoreKit.
    @Published private(set) var hasVerifiedEntitlements = false
    @Published private(set) var product: Product?
    @Published private(set) var productState: ProductState = .idle
    @Published private(set) var isPurchasing = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    private var updatesTask: Task<Void, Never>?
    private var isStarted = false
    private var lastRefresh: Date = .distantPast

    private init() {
        // Only used to avoid a locked/unlocked flicker before StoreKit answers; `start()` replaces it.
        isProUnlocked = OrbitProEntitlement.cachedIsUnlocked
    }

    /// Localised price from the App Store for the customer's storefront, e.g. "24,99 lei" or "$4.99".
    var displayPrice: String? { product?.displayPrice }

    /// Call once at launch. Safe to call repeatedly.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task {
            await refreshEntitlements()
            await loadProducts()
        }
    }

    /// Re-verify when the app returns to the foreground (throttled to once every few seconds).
    func refreshIfNeeded() {
        guard isStarted, Date().timeIntervalSince(lastRefresh) > 5 else { return }
        Task { await refreshEntitlements() }
    }

    func loadProducts() async {
        guard productState != .loading else { return }
        productState = .loading
        do {
            let products = try await Product.products(for: [Self.productID])
            product = products.first
            productState = product == nil ? .unavailable : .loaded
        } catch {
            productState = .unavailable
        }
    }

    func refreshEntitlements() async {
        lastRefresh = Date()
        var unlocked = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.productID,
                  transaction.revocationDate == nil else { continue }
            unlocked = true
        }
        apply(unlocked)
        hasVerifiedEntitlements = true
    }

    func purchase() async {
        guard !isPurchasing else { return }
        errorMessage = nil
        statusMessage = nil
        if product == nil { await loadProducts() }
        guard let product else {
            errorMessage = "Orbit Pro is not available right now. Check your internet connection and try again."
            return
        }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    await refreshEntitlements()
                    statusMessage = isProUnlocked ? "Orbit Pro is unlocked on all your devices. Thank you!" : nil
                case .unverified(_, let error):
                    errorMessage = "The App Store could not verify this purchase: \(error.localizedDescription)"
                }
            case .pending:
                statusMessage = "The purchase is waiting for approval. Orbit Pro unlocks automatically once it is approved."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restorePurchases() async {
        guard !isPurchasing else { return }
        errorMessage = nil
        statusMessage = nil
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            return
        } catch {
            errorMessage = "Could not reach the App Store: \(error.localizedDescription)"
        }
        await refreshEntitlements()
        statusMessage = isProUnlocked
            ? "Orbit Pro restored."
            : "No Orbit Pro purchase was found for this Apple Account."
    }

    private func handle(_ update: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let transaction) = update else { return }
        await transaction.finish()
        if transaction.productID == Self.productID { await refreshEntitlements() }
    }

    private func apply(_ unlocked: Bool) {
        var unlocked = unlocked
        #if DEBUG
        if let forced = UserDefaults.standard.object(forKey: "orbit.pro.debugOverride") as? Bool { unlocked = forced }
        #endif
        let changed = unlocked != isProUnlocked || unlocked != OrbitProEntitlement.cachedIsUnlocked
        isProUnlocked = unlocked
        OrbitProEntitlement.storeVerifiedState(unlocked)
        #if os(iOS)
        if changed {
            WidgetCenter.shared.reloadAllTimelines()
            if #available(iOS 18.0, *) { ControlCenter.shared.reloadAllControls() }
        }
        #endif
    }

    // MARK: - Testing support

    #if DEBUG
    /// Resets in-memory state so a test can start from a clean StoreKit session.
    func resetForTesting() {
        updatesTask?.cancel()
        updatesTask = nil
        isStarted = false
        isProUnlocked = false
        hasVerifiedEntitlements = false
        product = nil
        productState = .idle
        statusMessage = nil
        errorMessage = nil
    }
    #endif
}

// MARK: - Shared paywall (tvOS and macOS; iOS has its own richer sheet)

#if os(tvOS) || os(macOS)
struct OrbitProUnlockView: View {
    @ObservedObject private var store = OrbitProStore.shared
    var accent: Color = .yellow
    var reason: String? = nil
    var onClose: () -> Void

    private let features: [(String, String, String)] = [
        ("paintpalette.fill", "6 exclusive themes", "Cyberpunk, Solar Gold, Crimson, Matrix, Arctic and Sakura."),
        ("app.badge.checkmark", "5 alternate app icons", "On iPhone and iPad."),
        ("power.circle.fill", "Power widgets & Siri", "Wake, sleep and shut down from widgets, Control Center and Siri."),
        ("desktopcomputer", "Unlimited PCs", "Save and switch between every PC you own."),
        ("chart.xyaxis.line", "Session graphs", "History of FPS, temperatures and power."),
        ("square.grid.3x2.fill", "Unlimited buttons", "More than 6 one-tap buttons per PC, up to 64.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Orbit Pro").font(.title2.weight(.bold))
                    Text("One-time purchase · works on iPhone, iPad, Apple TV and Mac")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let reason {
                Label(reason, systemImage: "lock.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.yellow)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(features, id: \.1) { icon, title, detail in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: icon).foregroundStyle(accent).frame(width: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title).font(.headline)
                            Text(detail).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if store.isProUnlocked {
                Label("Orbit Pro is active on this Apple Account.", systemImage: "checkmark.seal.fill")
                    .font(.headline).foregroundStyle(.green)
            }
            if let message = store.errorMessage {
                Text(message).font(.callout).foregroundStyle(.red)
            } else if let message = store.statusMessage {
                Text(message).font(.callout).foregroundStyle(.yellow)
            }
            HStack(spacing: 14) {
                if !store.isProUnlocked {
                    Button {
                        Task { await store.purchase() }
                    } label: {
                        Label(purchaseTitle, systemImage: "crown.fill")
                    }
                    .disabled(store.isPurchasing || store.product == nil)
                    #if os(macOS)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    #endif
                }
                Button {
                    Task { await store.restorePurchases() }
                } label: {
                    Label("Restore Purchases", systemImage: "arrow.clockwise")
                }
                .disabled(store.isPurchasing)
                Spacer(minLength: 0)
                Button("Close") { onClose() }
                    #if os(macOS)
                    .keyboardShortcut(.cancelAction)
                    #endif
            }
        }
        .padding(28)
        #if os(macOS)
        .frame(width: 520)
        #else
        .frame(maxWidth: 1100)
        #endif
        .task {
            if store.product == nil { await store.loadProducts() }
        }
    }

    private var purchaseTitle: String {
        if store.isPurchasing { return "Purchasing…" }
        switch store.productState {
        case .loaded: return "Unlock Orbit Pro · \(store.displayPrice ?? "")"
        case .unavailable: return "Orbit Pro unavailable"
        default: return "Loading price…"
        }
    }
}
#endif
