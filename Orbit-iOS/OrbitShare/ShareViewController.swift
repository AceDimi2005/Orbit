import SwiftUI
import UIKit

/// Principal class of the "Send to PC" Share Extension (`NSExtensionPrincipalClass` in Info.plist).
///
/// UIKit owns the extension request; the sheet itself is SwiftUI. The view controller hands the
/// SwiftUI view two closures so it never touches `NSExtensionContext` directly.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        // Orbit is dark-only, like the app.
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black

        let root = SendToPCView(onCancel: { [weak self] in self?.cancel() })
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }

    /// Ends the request after the items were sent. The host app sees the share as completed.
    func finish() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    /// Ends the request without sending anything. The host app sees the share as cancelled.
    func cancel() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}

/// Placeholder sheet. The PC picker, item preview and send actions replace the body later.
struct SendToPCView: View {
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Image(systemName: "paperplane.circle.fill")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Send to PC")
                    .font(.title2.weight(.semibold))
                Text("Open links, copy text and save files on your Windows PC.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Orbit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
