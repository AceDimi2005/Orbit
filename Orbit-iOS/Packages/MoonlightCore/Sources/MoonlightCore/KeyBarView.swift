#if os(iOS)
import UIKit

/// The row of PC keys above the software keyboard (the stream surface's input accessory view), in the dark
/// keyboard's style. It scrolls sideways and only draws keys and reports touches; `MoonlightStreamSurfaceView`
/// keeps the `MoonlightModifierLatch` and sends the keys.
///
/// Plain keys go down and up with the finger, so holding an arrow repeats on the PC. Modifiers and shortcuts
/// act when the finger lifts on them, so a drag that scrolls the row never sends them. Alt+F4 asks first.
final class MoonlightKeyBarView: UIInputView, UIInputViewAudioFeedback {
    var onModifierTap: ((MoonlightModifierKey) -> Void)?
    var onModifierLock: ((MoonlightModifierKey) -> Void)?
    var onKeyDown: ((Int16) -> Void)?
    var onKeyUp: ((Int16) -> Void)?
    var onShortcut: ((MoonlightKeyBarShortcut) -> Void)?
    var onHideKeyboard: (() -> Void)?

    /// Key clicks follow the person's Keyboard Clicks setting.
    var enableInputClicksWhenVisible: Bool { true }

    /// What the keys sit on: see `makePanel()`.
    private let panel: UIView
    private let panelContent: UIView
    /// iOS 26 and later: the panel floats above the keyboard with a gap around it.
    private let floatsAboveKeyboard: Bool
    private let scrollView = MoonlightKeyBarScrollView()
    private let stack = UIStackView()
    private let divider = UIView()
    private let hideButton = UIButton(type: .custom)
    private var caps: [MoonlightKeyCap] = []
    private var modifierCaps: [MoonlightModifierKey: MoonlightKeyCap] = [:]
    private var separators: [UIView] = []
    private var barHeight: NSLayoutConstraint?
    private var separatorHeights: [NSLayoutConstraint] = []
    /// One-pixel lines: their width follows the display scale.
    private var hairlines: [NSLayoutConstraint] = []
    private var metrics: MoonlightKeyBarMetrics
    private let tapFeedback = UIImpactFeedbackGenerator(style: .light)
    private let lockFeedback = UIImpactFeedbackGenerator(style: .medium)

    init() {
        metrics = MoonlightKeyBarMetrics(traits: UITraitCollection.current)
        (panel, panelContent, floatsAboveKeyboard) = Self.makePanel()
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: metrics.barHeight), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        autoresizingMask = .flexibleHeight
        overrideUserInterfaceStyle = .dark
        build()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitDisplayScale.self]) { (bar: MoonlightKeyBarView, _: UITraitCollection) in
            bar.applyMetrics()
        }
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        applyMetrics()
        tapFeedback.prepare()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: metrics.barHeight + panelInsets.top + panelInsets.bottom)
    }

    /// The panel's distance from the row's edges: none on the keyboard's own background before iOS 26, a
    /// floating gap like the keyboard's own once it is glass.
    private var panelInsets: UIEdgeInsets {
        floatsAboveKeyboard ? UIEdgeInsets(top: 2, left: 8, bottom: 8, right: 8) : .zero
    }

    /// From iOS 26 the keyboard floats as a glass panel and draws nothing above itself, so the row gets a glass
    /// panel of its own; earlier, the input view's keyboard background already matches the keys.
    private static func makePanel() -> (panel: UIView, content: UIView, floats: Bool) {
        if #available(iOS 26.0, *) {
            let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
            glass.cornerConfiguration = .corners(radius: .fixed(Double(MoonlightKeyBarMetrics.panelCornerRadius)))
            return (glass, glass.contentView, true)
        }
        let plain = UIView()
        return (plain, plain, false)
    }

    func cap(for item: MoonlightKeyBarItem) -> MoonlightKeyCap? {
        caps.first { $0.item == item }
    }

    /// Scrolls the row so `item` is in view (the DEBUG preview's script uses it).
    func scrollToShow(_ item: MoonlightKeyBarItem, animated: Bool) {
        guard let cap = cap(for: item) else { return }
        layoutIfNeeded()
        let frame = cap.convert(cap.bounds, to: scrollView).insetBy(dx: -MoonlightKeyBarMetrics.edgeInset, dy: 0)
        let maxOffset = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        scrollView.setContentOffset(CGPoint(x: min(max(0, frame.minX), maxOffset), y: 0), animated: animated)
    }

    /// Shows each modifier's latch; a modifier that just locked gets a firmer tap.
    func show(_ latch: MoonlightModifierLatch) {
        for (modifier, cap) in modifierCaps {
            let state = latch.state(of: modifier)
            if state == .locked, cap.latch != .locked { lockFeedback.impactOccurred() }
            cap.latch = state
        }
    }

    // MARK: Building

    private func build() {
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.semanticContentAttribute = .forceLeftToRight
        if floatsAboveKeyboard {
            // Keys scrolling off the leading end disappear under the panel's rounded corners, not past them.
            scrollView.layer.cornerRadius = MoonlightKeyBarMetrics.panelCornerRadius
            scrollView.layer.cornerCurve = .continuous
            scrollView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        }
        panelContent.addSubview(scrollView)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = MoonlightKeyBarMetrics.keySpacing
        stack.semanticContentAttribute = .forceLeftToRight
        stack.accessibilityContainerType = .semanticGroup
        stack.accessibilityLabel = "PC keys"
        scrollView.addSubview(stack)

        for (index, group) in MoonlightKeyBarLayout.groups.enumerated() {
            if index > 0 {
                let separator = UIView()
                separator.backgroundColor = UIColor(white: 1, alpha: 0.16)
                separator.isAccessibilityElement = false
                separator.translatesAutoresizingMaskIntoConstraints = false
                let width = separator.widthAnchor.constraint(equalToConstant: 1)
                width.isActive = true
                hairlines.append(width)
                let height = separator.heightAnchor.constraint(equalToConstant: metrics.keyHeight * 0.5)
                height.isActive = true
                separatorHeights.append(height)
                if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(MoonlightKeyBarMetrics.groupSpacing, after: last) }
                stack.addArrangedSubview(separator)
                stack.setCustomSpacing(MoonlightKeyBarMetrics.groupSpacing, after: separator)
                separators.append(separator)
            }
            for item in group { stack.addArrangedSubview(makeCap(item)) }
        }

        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.backgroundColor = UIColor(white: 1, alpha: 0.16)
        panelContent.addSubview(divider)

        updateHideButton()
        hideButton.translatesAutoresizingMaskIntoConstraints = false
        hideButton.accessibilityLabel = "Hide Keyboard"
        hideButton.isPointerInteractionEnabled = true
        hideButton.addAction(UIAction { [weak self] _ in self?.onHideKeyboard?() }, for: .touchUpInside)
        panelContent.addSubview(hideButton)

        let guide = safeAreaLayoutGuide
        let insets = panelInsets
        let height = scrollView.heightAnchor.constraint(equalToConstant: metrics.barHeight)
        barHeight = height
        let dividerWidth = divider.widthAnchor.constraint(equalToConstant: 1)
        hairlines.append(dividerWidth)
        NSLayoutConstraint.activate([
            height,
            dividerWidth,
            panel.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            panel.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -insets.bottom),
            panel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: insets.left),
            panel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -insets.right),

            scrollView.topAnchor.constraint(equalTo: panelContent.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: panelContent.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: panelContent.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: divider.leadingAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: MoonlightKeyBarMetrics.edgeInset),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -MoonlightKeyBarMetrics.edgeInset),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),

            divider.heightAnchor.constraint(equalTo: scrollView.heightAnchor, multiplier: 0.5),
            divider.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            divider.trailingAnchor.constraint(equalTo: hideButton.leadingAnchor, constant: -2),

            hideButton.trailingAnchor.constraint(equalTo: panelContent.trailingAnchor, constant: -4),
            hideButton.topAnchor.constraint(equalTo: scrollView.topAnchor),
            hideButton.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            hideButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        let largeContent = UILargeContentViewerInteraction()
        addInteraction(largeContent)
    }

    private func makeCap(_ item: MoonlightKeyBarItem) -> MoonlightKeyCap {
        let cap = MoonlightKeyCap(item: item, metrics: metrics)
        caps.append(cap)
        switch item {
        case .key(let key):
            cap.addAction(UIAction { [weak self] _ in self?.keyDown(key) }, for: .touchDown)
            for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel] {
                cap.addAction(UIAction { [weak self] _ in self?.onKeyUp?(key.virtualKey) }, for: event)
            }
            cap.activate = { [weak self] in
                self?.keyDown(key)
                self?.onKeyUp?(key.virtualKey)
                return true
            }
        case .modifier(let modifier):
            modifierCaps[modifier] = cap
            cap.addAction(UIAction { [weak self] _ in self?.modifierTapped(modifier) }, for: .touchUpInside)
            cap.activate = { [weak self] in self?.modifierTapped(modifier); return true }
            cap.lock = { [weak self] in self?.onModifierLock?(modifier) }
        case .shortcut(let shortcut) where shortcut.needsConfirmation:
            let confirm = UIAction(title: "Close Window", subtitle: shortcut.chord.caption, image: UIImage(systemName: "xmark.square"),
                                   attributes: .destructive) { [weak self] _ in self?.shortcutTapped(shortcut) }
            cap.menu = UIMenu(title: "Close the window in front of you on the PC? Unsaved work there may be lost.", children: [confirm])
            cap.showsMenuAsPrimaryAction = true
            cap.activate = nil   // VoiceOver opens the same menu
        case .shortcut(let shortcut):
            cap.addAction(UIAction { [weak self] _ in self?.shortcutTapped(shortcut) }, for: .touchUpInside)
            cap.activate = { [weak self] in self?.shortcutTapped(shortcut); return true }
        }
        return cap
    }

    private func applyMetrics() {
        metrics = MoonlightKeyBarMetrics(traits: traitCollection)
        barHeight?.constant = metrics.barHeight
        separatorHeights.forEach { $0.constant = metrics.keyHeight * 0.5 }
        let pixel = 1 / max(traitCollection.displayScale, 1)
        hairlines.forEach { $0.constant = pixel }
        caps.forEach { $0.metrics = metrics }
        updateHideButton()
        invalidateIntrinsicContentSize()
    }

    /// The symbol follows the keycaps' capped font; left to itself it would outgrow the row at large text sizes.
    private func updateHideButton() {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "keyboard.chevron.compact.down")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(font: metrics.symbolFont())
        configuration.baseForegroundColor = .white
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
        hideButton.configuration = configuration
        hideButton.adjustsImageSizeForAccessibilityContentSizeCategory = false
        hideButton.largeContentTitle = "Hide Keyboard"
        hideButton.showsLargeContentViewer = true
    }

    // MARK: Touches

    private func keyDown(_ key: MoonlightBarKey) {
        feedback()
        onKeyDown?(key.virtualKey)
    }

    private func modifierTapped(_ modifier: MoonlightModifierKey) {
        feedback()
        onModifierTap?(modifier)
    }

    private func shortcutTapped(_ shortcut: MoonlightKeyBarShortcut) {
        feedback()
        onShortcut?(shortcut)
    }

    private func feedback() {
        UIDevice.current.playInputClick()
        tapFeedback.impactOccurred()
        tapFeedback.prepare()
    }
}

/// Sizes that follow Dynamic Type up to a cap, so the row grows with larger text but never crowds out the
/// video; the Large Content Viewer covers the accessibility sizes beyond it.
struct MoonlightKeyBarMetrics {
    static let keySpacing: CGFloat = 6
    static let groupSpacing: CGFloat = 9
    static let edgeInset: CGFloat = 8
    static let verticalPadding: CGFloat = 6
    static let cornerRadius: CGFloat = 9
    /// The floating panel's corners, concentric with the keycaps inside it.
    static var panelCornerRadius: CGFloat { cornerRadius + verticalPadding }

    let keyHeight: CGFloat
    let minimumKeyWidth: CGFloat
    let labelFont: UIFont
    let captionTitleFont: UIFont
    let captionKeysFont: UIFont

    var barHeight: CGFloat { keyHeight + 2 * Self.verticalPadding }

    /// For SF Symbols: the label's capped size in a plain font. A symbol configured with the Dynamic Type font
    /// itself keeps growing with the text size and ignores the cap.
    func symbolFont(scale: CGFloat = 1) -> UIFont {
        .systemFont(ofSize: (labelFont.pointSize * scale).rounded(), weight: .semibold)
    }

    init(traits: UITraitCollection) {
        let body = UIFontMetrics(forTextStyle: .body)
        keyHeight = min(52, max(38, body.scaledValue(for: 38, compatibleWith: traits).rounded()))
        minimumKeyWidth = 44
        labelFont = body.scaledFont(for: .systemFont(ofSize: 15, weight: .semibold), maximumPointSize: 21, compatibleWith: traits)
        captionTitleFont = body.scaledFont(for: .systemFont(ofSize: 13, weight: .semibold), maximumPointSize: 18, compatibleWith: traits)
        captionKeysFont = body.scaledFont(for: .systemFont(ofSize: 10.5, weight: .medium), maximumPointSize: 14, compatibleWith: traits)
    }
}

/// Dragging across keys scrolls the row instead of holding the key that was touched first.
private final class MoonlightKeyBarScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

/// One keycap: gray like the keyboard's function keys; white with dark ink while a modifier is latched, plus a
/// short bar underneath when it is locked (like Caps Lock on the iPhone keyboard).
final class MoonlightKeyCap: UIButton {
    let item: MoonlightKeyBarItem
    var latch: MoonlightLatch = .off {
        didSet {
            guard latch != oldValue else { return }
            setNeedsUpdateConfiguration()
            updateAccessibility()
        }
    }
    var metrics: MoonlightKeyBarMetrics {
        didSet {
            heightConstraint?.constant = metrics.keyHeight
            widthConstraint?.constant = metrics.minimumKeyWidth
            setNeedsUpdateConfiguration()
        }
    }
    /// VoiceOver activation: a full press, since VoiceOver does not deliver touch-down and touch-up.
    var activate: (() -> Bool)?
    /// VoiceOver's "Lock" action on a modifier.
    var lock: (() -> Void)? { didSet { updateAccessibility() } }

    private let lockMark = UIView()
    private var heightConstraint: NSLayoutConstraint?
    private var widthConstraint: NSLayoutConstraint?

    init(item: MoonlightKeyBarItem, metrics: MoonlightKeyBarMetrics) {
        self.item = item
        self.metrics = metrics
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isPointerInteractionEnabled = true
        showsLargeContentViewer = true
        scalesLargeContentImage = true
        largeContentTitle = displayTitle
        largeContentImage = symbolName.flatMap { UIImage(systemName: $0) }

        let height = heightAnchor.constraint(equalToConstant: metrics.keyHeight)
        let width = widthAnchor.constraint(greaterThanOrEqualToConstant: metrics.minimumKeyWidth)
        heightConstraint = height
        widthConstraint = width
        lockMark.translatesAutoresizingMaskIntoConstraints = false
        lockMark.isUserInteractionEnabled = false
        lockMark.backgroundColor = .black
        lockMark.layer.cornerRadius = 1.25
        lockMark.isHidden = true
        addSubview(lockMark)
        NSLayoutConstraint.activate([
            height, width,
            lockMark.centerXAnchor.constraint(equalTo: centerXAnchor),
            lockMark.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            lockMark.widthAnchor.constraint(equalToConstant: 14),
            lockMark.heightAnchor.constraint(equalToConstant: 2.5),
        ])
        setContentCompressionResistancePriority(.required, for: .horizontal)
        // A button only calls updateConfiguration() once it has a configuration to update.
        configuration = .plain()
        setNeedsUpdateConfiguration()
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("Not used") }

    private var symbolName: String? {
        switch item {
        case .modifier(.windows): return "square.split.2x2.fill"
        case .key(let key): return key.symbol
        default: return nil
        }
    }

    private var displayTitle: String {
        switch item {
        case .modifier(let modifier): return modifier.title
        case .key(let key): return key.title
        case .shortcut(let shortcut): return shortcut.title
        }
    }

    override func updateConfiguration() {
        var configuration = UIButton.Configuration.plain()
        let lit = latch != .off
        let ink: UIColor = lit ? .black : .white
        let fill: UIColor
        if lit {
            fill = isHighlighted ? UIColor(white: 0.8, alpha: 1) : .white
        } else {
            fill = isHighlighted ? UIColor(white: 1, alpha: 0.42) : UIColor(white: 1, alpha: 0.2)
        }
        configuration.background.backgroundColor = fill
        configuration.background.cornerRadius = MoonlightKeyBarMetrics.cornerRadius
        configuration.cornerStyle = .fixed
        configuration.baseForegroundColor = ink
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
        configuration.titleLineBreakMode = .byClipping

        if let symbolName {
            configuration.image = UIImage(systemName: symbolName)
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
                font: metrics.symbolFont(scale: item == .modifier(.windows) ? 0.9 : 1))
        } else if case .shortcut(let shortcut) = item {
            let titleColor: UIColor = shortcut.needsConfirmation && !lit ? UIColor(red: 1, green: 0.45, blue: 0.42, alpha: 1) : ink
            configuration.attributedTitle = AttributedString(shortcut.title, attributes: AttributeContainer([
                .font: metrics.captionTitleFont, .foregroundColor: titleColor,
            ]))
            configuration.attributedSubtitle = AttributedString(shortcut.chord.caption, attributes: AttributeContainer([
                .font: metrics.captionKeysFont, .foregroundColor: ink.withAlphaComponent(0.62),
            ]))
            configuration.titleAlignment = .center
            configuration.titlePadding = 1
        } else {
            configuration.attributedTitle = AttributedString(displayTitle, attributes: AttributeContainer([
                .font: metrics.labelFont, .foregroundColor: ink,
            ]))
        }
        self.configuration = configuration
        lockMark.isHidden = latch != .locked
        bringSubviewToFront(lockMark)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        bringSubviewToFront(lockMark)
    }

    /// The whole height of the row and half the gap on each side count as the key, so the target is larger
    /// than the cap that is drawn.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -MoonlightKeyBarMetrics.keySpacing / 2, dy: -MoonlightKeyBarMetrics.verticalPadding).contains(point)
    }

    override func accessibilityActivate() -> Bool {
        activate?() ?? false
    }

    private func updateAccessibility() {
        var traits: UIAccessibilityTraits = .button
        switch item {
        case .modifier(let modifier):
            accessibilityLabel = modifier.spokenName
            accessibilityHint = "Applies to the next key you press."
            switch latch {
            case .off: accessibilityValue = nil
            case .oneShot: accessibilityValue = "On for the next key"; traits.insert(.selected)
            case .locked: accessibilityValue = "Locked"; traits.insert(.selected)
            }
            if latch != .locked, let lock {
                accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Lock \(modifier.title)") { _ in lock(); return true }]
            } else {
                accessibilityCustomActions = nil
            }
        case .key(let key):
            accessibilityLabel = key.spokenName
            traits = .keyboardKey
        case .shortcut(let shortcut):
            accessibilityLabel = shortcut.spokenName
            accessibilityHint = shortcut.needsConfirmation ? "Sends \(shortcut.chord.caption) after you confirm." : "Sends \(shortcut.chord.caption)."
        }
        accessibilityTraits = traits
    }
}
#endif
