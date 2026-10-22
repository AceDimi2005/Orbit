import SwiftUI
import UIKit

/// Multitouch trackpad backed by UIKit gesture recognisers: one finger moves,
/// two fingers scroll, a two-finger tap right-clicks and a long press holds the
/// left button for drag. Movement is coalesced before reaching the network.
struct OrbitTrackpadSurface: UIViewRepresentable {
    var sensitivity: Double
    var onMove: (Int, Int) -> Void
    var onScroll: (Int, Int) -> Void
    var onClick: (String) -> Void
    var onDrag: (Bool) -> Void
    var onTouch: (CGPoint?) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        let coordinator = context.coordinator

        let move = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleMove(_:)))
        move.minimumNumberOfTouches = 1
        move.maximumNumberOfTouches = 1
        move.delegate = coordinator

        let scroll = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleScroll(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        scroll.delegate = coordinator

        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.numberOfTouchesRequired = 1
        tap.delegate = coordinator

        let secondaryTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleSecondaryTap(_:)))
        secondaryTap.numberOfTouchesRequired = 2
        secondaryTap.delegate = coordinator

        let hold = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleHold(_:)))
        hold.minimumPressDuration = 0.38
        hold.allowableMovement = 8
        hold.delegate = coordinator

        [move, scroll, tap, secondaryTap, hold].forEach { view.addGestureRecognizer($0) }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: OrbitTrackpadSurface
        private var lastTranslation: CGPoint = .zero
        private var pendingX = 0.0
        private var pendingY = 0.0
        private var lastFlush = Date.distantPast
        private var scrollTranslation: CGPoint = .zero
        private var scrollRemainderY = 0.0
        private var scrollRemainderX = 0.0
        private var isHolding = false
        private var isPanning = false

        init(parent: OrbitTrackpadSurface) { self.parent = parent }

        /// Only the trackpad's own recognisers run together; the enclosing
        /// ScrollView keeps UIKit's default exclusivity so the page does not
        /// scroll while the cursor is being moved.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer.view === gestureRecognizer.view
        }

        @objc func handleMove(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                isPanning = true
                lastTranslation = .zero
                pendingX = 0; pendingY = 0
                parent.onTouch(recognizer.location(in: view))
            case .changed:
                let translation = recognizer.translation(in: view)
                pendingX += Double(translation.x - lastTranslation.x) * parent.sensitivity
                pendingY += Double(translation.y - lastTranslation.y) * parent.sensitivity
                lastTranslation = translation
                parent.onTouch(recognizer.location(in: view))
                if Date().timeIntervalSince(lastFlush) >= 0.024 { flush() }
            case .ended, .cancelled, .failed:
                flush()
                isPanning = false
                lastTranslation = .zero
                parent.onTouch(nil)
            default:
                break
            }
        }

        private func flush() {
            let dx = Int(pendingX)
            let dy = Int(pendingY)
            guard dx != 0 || dy != 0 else { return }
            pendingX -= Double(dx)
            pendingY -= Double(dy)
            lastFlush = Date()
            parent.onMove(dx, dy)
        }

        @objc func handleScroll(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                scrollTranslation = .zero
                scrollRemainderX = 0; scrollRemainderY = 0
            case .changed:
                let translation = recognizer.translation(in: view)
                scrollRemainderY += Double(translation.y - scrollTranslation.y)
                scrollRemainderX += Double(translation.x - scrollTranslation.x)
                scrollTranslation = translation
                let stepSize = 16.0
                let verticalSteps = Int(scrollRemainderY / stepSize)
                let horizontalSteps = Int(scrollRemainderX / stepSize)
                if verticalSteps != 0 || horizontalSteps != 0 {
                    scrollRemainderY -= Double(verticalSteps) * stepSize
                    scrollRemainderX -= Double(horizontalSteps) * stepSize
                    // Natural scrolling: fingers down moves content down (wheel up).
                    parent.onScroll(max(-8, min(8, verticalSteps)), max(-8, min(8, -horizontalSteps)))
                }
            default:
                break
            }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, !isHolding else { return }
            parent.onClick("left")
        }

        @objc func handleSecondaryTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.onClick("right")
        }

        @objc func handleHold(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                // A slow, precise nudge must stay a plain cursor move.
                guard !isPanning else { return }
                isHolding = true
                parent.onDrag(true)
            case .ended, .cancelled, .failed:
                guard isHolding else { return }
                isHolding = false
                flush()
                parent.onDrag(false)
            default:
                break
            }
        }
    }
}
