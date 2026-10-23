import SwiftUI
import UIKit

/// Principal class of the "Send to PC" Share Extension (`NSExtensionPrincipalClass` in Info.plist).
///
/// UIKit owns the extension request; the sheet itself is SwiftUI (`SendToPCView`). The model gets
/// the shared items and two closures, so it never touches `NSExtensionContext` directly, and the
/// request is ended exactly once: completed after a send, cancelled otherwise.
final class ShareViewController: UIViewController {
    private var model: SendToPCModel?
    private var requestEnded = false

    override func viewDidLoad() {
        super.viewDidLoad()
        // Orbit is dark-only, like the app.
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        // Swiping the sheet down would leave the request open (and an upload running); the sheet
        // closes through Cancel, Done or a finished send instead.
        isModalInPresentation = true

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let model = SendToPCModel(items: items,
                                  finish: { [weak self] in self?.finish() },
                                  cancel: { [weak self] in self?.cancel() })
        self.model = model

        let host = UIHostingController(rootView: SendToPCView(model: model))
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
        model.start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // If the host closed the sheet some other way, end the request so the extension does not
        // linger (and come back blank next time). Only when the view really left its window:
        // the host app going to the background must not stop an upload.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.requestEnded, self.view.window == nil else { return }
            self.model?.cancel()
        }
    }

    /// Ends the request after the items were sent. The host app sees the share as completed.
    func finish() {
        guard !requestEnded else { return }
        requestEnded = true
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    /// Ends the request without sending anything. The host app sees the share as cancelled.
    func cancel() {
        guard !requestEnded else { return }
        requestEnded = true
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}
