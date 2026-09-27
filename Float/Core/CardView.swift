import AppKit

/// Rounded, shadowed container for one card: chrome strip, drag to move, edges to resize.
@MainActor
final class CardView: NSView {
    let content: CardContent
    /// Locked content aspect ratio (width / height of the area below the chrome).
    var aspect: CGFloat?
    /// The S/M/L size last picked, re-applied when the canvas changes size; nil once resized by hand.
    var sizePreset: SizePreset?
    var isFocused = false { didSet { updateBorder(); updateGrabber() } }

    var onFocus: ((CardView) -> Void)?
    /// Drag released, with the release velocity in canvas points per second.
    var onMoveEnded: ((CardView, CGVector) -> Void)?
    var onResizeEnded: ((CardView) -> Void)?
    var onAspectPicked: ((CardView, CGFloat?) -> Void)?
    var onSizePicked: ((CardView, SizePreset) -> Void)?
    var onCloseRequested: ((CardView) -> Void)?

    private let container = FlippedView()
    private let chrome = FlippedView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let presetButton = NSButton()
    /// Hairline under the chrome strip.
    private let chromeRule = NSView()
    private let grabber = GrabberView()
    private var isHovered = false
    private var isMoving = false
    private var moveOffset = CGVector.zero
    /// Set while the exit animation runs so the fading card ignores clicks.
    private var isClosing = false

    private enum Gesture { case move, resize(Edges) }
    private var gesture: Gesture?
    private var startFrame = CGRect.zero
    private var startMouse = CGPoint.zero
    private var tracker = VelocityTracker()
    private(set) lazy var mover = SpringAnimator(view: self)

    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let top = Edges(rawValue: 4)
        static let bottom = Edges(rawValue: 8)
    }

    init(content: CardContent, frame: CGRect) {
        self.content = content
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor

        container.wantsLayer = true
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        addSubview(container)

        chrome.wantsLayer = true
        chromeRule.wantsLayer = true
        chrome.addSubview(chromeRule)
        container.addSubview(chrome)

        titleLabel.lineBreakMode = .byTruncatingMiddle
        chrome.addSubview(titleLabel)

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        chrome.addSubview(closeButton)

        presetButton.image = NSImage(systemSymbolName: "aspectratio", accessibilityDescription: "Size")
        presetButton.isBordered = false
        presetButton.target = self
        presetButton.action = #selector(showPresets)
        chrome.addSubview(presetButton)

        if let accessory = content.accessory { chrome.addSubview(accessory) }
        chrome.addSubview(grabber)
        container.addSubview(content.view)

        content.onTitleChange = { [weak self] title in self?.setTitle(title) }
        applyTheme()
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        setHovered(false, animated: false)
    }

    // MARK: - Theme

    /// Re-reads every visual token from Theme.current; also themes the card's content.
    func applyTheme() {
        let t = Theme.current
        layer?.shadowOpacity = t.shadowOpacity
        layer?.shadowRadius = t.shadowRadius
        layer?.shadowOffset = t.shadowOffset
        container.layer?.cornerRadius = t.cardRadius
        container.layer?.backgroundColor = t.cardBackground.cgColor
        container.layer?.borderWidth = t.borderWidth
        chrome.layer?.backgroundColor = t.chromeBackground.cgColor
        chromeRule.layer?.backgroundColor = t.chromeRule.cgColor
        for b in [closeButton, presetButton] {
            b.contentTintColor = t.controlTint
            b.image?.isTemplate = true
            b.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        }
        grabber.applyTheme()
        setTitle(content.title)
        updateBorder()
        content.applyTheme()
        needsLayout = true
    }

    private func setTitle(_ title: String) {
        titleLabel.attributedStringValue = Theme.label(title, color: Theme.current.chromeText)
    }

    // MARK: - Hover

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    /// Chrome buttons stay quiet until the pointer is over the card.
    private func setHovered(_ hovered: Bool, animated: Bool = true) {
        isHovered = hovered
        let alpha: CGFloat = hovered ? 1 : Theme.current.idleControlAlpha
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.15 : 0
            for button in [closeButton, presetButton] { button.animator().alphaValue = alpha }
        }
        updateGrabber()
    }

    /// Always shown on the focused card, fades in on hover for others, brightens while moving.
    private func updateGrabber() {
        grabber.emphasis = isMoving || (isHovered && isFocused) ? .active : (isFocused || isHovered ? .idle : .hidden)
    }

    /// The top strip, where a plain two-finger swipe or a drag moves the card.
    func isInStrip(_ local: CGPoint) -> Bool {
        local.y >= 0 && local.y < Theme.chromeHeight && local.x >= 0 && local.x <= bounds.width
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        container.frame = bounds
        layer?.shadowPath = CGPath(
            roundedRect: bounds, cornerWidth: Theme.current.cardRadius, cornerHeight: Theme.current.cardRadius, transform: nil)

        let h = Theme.chromeHeight
        chrome.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
        let button: CGFloat = 22
        closeButton.frame = CGRect(x: bounds.width - button - 6, y: (h - button) / 2, width: button, height: button)
        presetButton.frame = closeButton.frame.offsetBy(dx: -button, dy: 0)
        let trailing = presetButton.frame.minX - 4
        let t = Theme.current
        let pill = t.grabberSize
        grabber.frame = CGRect(x: (bounds.width - pill.width) / 2, y: t.grabberTopInset, width: pill.width, height: pill.height)
        chromeRule.frame = CGRect(x: 0, y: h - t.borderWidth, width: bounds.width, height: t.borderWidth)

        if let accessory = content.accessory {
            titleLabel.isHidden = true
            // Sits below the grabber pill.
            let top = grabber.frame.maxY
            accessory.frame = CGRect(x: 8, y: top, width: max(0, trailing - 8), height: h - top)
        } else {
            titleLabel.sizeToFit()
            let labelH = titleLabel.frame.height
            titleLabel.frame = CGRect(x: 12, y: (h - labelH) / 2 + 1, width: max(0, trailing - 12), height: labelH)
        }
        content.view.frame = CGRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
    }

    private func updateBorder() {
        let t = Theme.current
        container.layer?.borderColor = (isFocused ? t.focusHairline : t.hairline).cgColor
    }

    @objc private func closeClicked() { onCloseRequested?(self) }

    // MARK: - Presets

    @objc private func showPresets() {
        let menu = NSMenu()
        menu.font = Theme.mono(12)
        menu.addItem(withTitle: "Aspect", action: nil, keyEquivalent: "").isEnabled = false
        for preset in AspectPreset.allCases {
            let item = menu.addItem(withTitle: preset.rawValue, action: #selector(aspectPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
            item.state = preset.ratio == aspect ? .on : .off
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Size", action: nil, keyEquivalent: "").isEnabled = false
        for preset in SizePreset.allCases {
            let item = menu.addItem(withTitle: preset.rawValue, action: #selector(sizePicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
        }
        menu.popUp(positioning: nil, at: CGPoint(x: presetButton.frame.minX, y: presetButton.frame.maxY), in: chrome)
    }

    @objc private func aspectPicked(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let preset = AspectPreset(rawValue: raw) else { return }
        onAspectPicked?(self, preset.ratio)
    }

    @objc private func sizePicked(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let preset = SizePreset(rawValue: raw) else { return }
        onSizePicked?(self, preset)
    }

    // MARK: - Hit testing

    private func edges(at p: CGPoint) -> Edges {
        let z = Config.resizeZone
        var e: Edges = []
        if p.x < z { e.insert(.left) }
        if p.x > bounds.width - z { e.insert(.right) }
        if p.y < z { e.insert(.top) }
        if p.y > bounds.height - z { e.insert(.bottom) }
        return e
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isClosing, let hit = super.hitTest(point) else { return nil }
        let local = convert(point, from: superview)
        let commandDrag = NSApp.currentEvent?.type == .leftMouseDown
            && NSEvent.modifierFlags.contains(.command)
        let onChrome = hit === chrome || hit === titleLabel || hit === container || hit === content.accessory
        if !edges(at: local).isEmpty || commandDrag || onChrome {
            return self
        }
        return hit
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Move / resize

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let e = edges(at: local)
        gesture = e.isEmpty ? .move : .resize(e)
        startMouse = superview?.convert(event.locationInWindow, from: nil) ?? .zero
        onFocus?(self)
        if e.isEmpty { beginMove(at: event.timestamp) } else { mover.stop(); startFrame = frame }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let gesture, let superview else { return }
        let p = superview.convert(event.locationInWindow, from: nil)
        let d = CGVector(dx: p.x - startMouse.x, dy: p.y - startMouse.y)
        switch gesture {
        case .move: updateMove(offset: d, at: event.timestamp)
        case .resize(let e): frame = resized(edges: e, dx: d.dx, dy: d.dy)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let ended = gesture else { return }
        gesture = nil
        switch ended {
        case .move: endMove(at: event.timestamp)
        case .resize: onResizeEnded?(self)
        }
    }

    // MARK: - Move (shared by mouse drag and TrackpadMover)

    func beginMove(at time: TimeInterval) {
        mover.stop()
        startFrame = frame
        moveOffset = .zero
        tracker.reset()
        tracker.add(.zero, at: time)
        isMoving = true
        updateGrabber()
        NSCursor.closedHand.push()
        setLifted(true)
    }

    /// `offset` is the total pointer/finger travel since `beginMove`, in canvas points.
    func updateMove(offset: CGVector, at time: TimeInterval) {
        guard isMoving, let superview else { return }
        moveOffset = offset
        tracker.add(CGPoint(x: offset.dx, y: offset.dy), at: time)
        let bounds = superview.bounds
        frame = Snapping.rubberBand(startFrame.offsetBy(dx: offset.dx, dy: offset.dy), in: bounds)
    }

    func endMove(at time: TimeInterval, cancelled: Bool = false) {
        guard isMoving else { return }
        isMoving = false
        NSCursor.pop()
        updateGrabber()
        setLifted(false)
        onMoveEnded?(self, cancelled ? .zero : tracker.velocity(at: time))
    }

    // MARK: - Lift

    /// Scales the card up slightly and deepens its shadow while it is being dragged.
    private func setLifted(_ lifted: Bool) {
        guard let layer else { return }
        let t = Theme.current
        let values: [(String, Any)] = [
            ("transform", NSValue(caTransform3D: centerScale(lifted ? Config.liftScale : 1))),
            ("shadowRadius", lifted ? t.liftShadowRadius : t.shadowRadius),
            ("shadowOpacity", lifted ? t.liftShadowOpacity : t.shadowOpacity),
            ("shadowOffset", NSValue(size: lifted ? t.liftShadowOffset : t.shadowOffset)),
        ]
        for (key, value) in values {
            let anim = CASpringAnimation(perceptualDuration: 0.3, bounce: lifted ? 0 : 0.25)
            anim.keyPath = key
            anim.fromValue = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
            anim.toValue = value
            layer.add(anim, forKey: key)
            layer.setValue(value, forKeyPath: key)
        }
    }

    /// AppKit-backed layers anchor at (0,0), so scale around the center explicitly.
    private func centerScale(_ scale: CGFloat) -> CATransform3D {
        var t = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        return CATransform3DTranslate(t, -bounds.midX, -bounds.midY, 0)
    }

    // MARK: - Entrance / exit

    /// Scale 0.92 → 1 and fade in on the card spring (fade only with Reduce Motion).
    func animateEntrance() {
        guard let layer else { return }
        let spring = Spring.standard
        var animations: [(String, Any, Any)] = [("opacity", 0, 1)]
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            animations.append(("transform", NSValue(caTransform3D: centerScale(Config.cardEntranceScale)),
                               NSValue(caTransform3D: CATransform3DIdentity)))
        }
        for (key, from, to) in animations {
            let anim = CASpringAnimation(keyPath: key)
            anim.mass = 1
            anim.stiffness = spring.stiffness
            anim.damping = spring.damping
            anim.fromValue = from
            anim.toValue = to
            anim.duration = anim.settlingDuration
            layer.add(anim, forKey: "entrance-\(key)")
        }
    }

    /// The reverse of the entrance; `completion` runs once the card is invisible.
    func animateExit(completion: @escaping @MainActor () -> Void) {
        isClosing = true
        guard let layer else { completion(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        for (key, to) in [("opacity", 0 as Any), ("transform", NSValue(caTransform3D: centerScale(Config.cardEntranceScale)))] {
            let anim = CABasicAnimation(keyPath: key)
            anim.toValue = to
            anim.duration = Config.cardExitDuration
            anim.timingFunction = CAMediaTimingFunction(name: .easeIn)
            anim.fillMode = .forwards
            anim.isRemovedOnCompletion = false
            layer.add(anim, forKey: "exit-\(key)")
        }
        CATransaction.commit()
    }

    private func resized(edges e: Edges, dx: CGFloat, dy: CGFloat) -> CGRect {
        let min = Config.minCardSize
        var w = startFrame.width, h = startFrame.height
        if e.contains(.left) { w -= dx }
        if e.contains(.right) { w += dx }
        if e.contains(.top) { h -= dy }
        if e.contains(.bottom) { h += dy }
        let minW = max(min.width, content.minWidth)
        w = max(w, minW)
        h = max(h, min.height)

        if let aspect {
            let chromeH = Theme.chromeHeight
            if e.isDisjoint(with: [.left, .right]) {
                w = max((h - chromeH) * aspect, minW)
            }
            h = w / aspect + chromeH
        }

        let x = e.contains(.left) ? startFrame.maxX - w : startFrame.minX
        let y = e.contains(.top) ? startFrame.maxY - h : startFrame.minY
        return CGRect(x: x, y: y, width: w, height: h)
    }

    override func resetCursorRects() {
        let z = Config.resizeZone
        let b = bounds
        // Open hand over the strip's empty area (left of the buttons; the web card's controls cover it).
        if content.accessory == nil {
            addCursorRect(CGRect(x: z, y: z, width: presetButton.frame.minX - z, height: Theme.chromeHeight - z), cursor: .openHand)
        }
        addCursorRect(CGRect(x: 0, y: z, width: z, height: b.height - 2 * z), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: b.width - z, y: z, width: z, height: b.height - 2 * z), cursor: .resizeLeftRight)
        addCursorRect(CGRect(x: z, y: 0, width: b.width - 2 * z, height: z), cursor: .resizeUpDown)
        addCursorRect(CGRect(x: z, y: b.height - z, width: b.width - 2 * z, height: z), cursor: .resizeUpDown)
        for corner in [CGPoint(x: 0, y: 0), CGPoint(x: b.width - z, y: 0),
                       CGPoint(x: 0, y: b.height - z), CGPoint(x: b.width - z, y: b.height - z)] {
            addCursorRect(CGRect(origin: corner, size: CGSize(width: z, height: z)), cursor: .crosshair)
        }
    }
}

/// Top-left origin, so chrome/content layout matches the card's own coordinates.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
