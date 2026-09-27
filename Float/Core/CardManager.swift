import AppKit

/// Owns the cards: add/remove, focus, z-order and snapping.
@MainActor
final class CardManager {
    let canvas: CanvasView
    /// Creation order, used for focus cycling. Z-order lives in `canvas.subviews`.
    private(set) var cards: [CardView] = []
    private(set) var focused: CardView?

    private var trackpad: TrackpadMover?
    /// Shown behind everything while there are no cards.
    private let emptyState = EmptyStateView()
    /// Canvas size the S/M/L presets were last applied for.
    private var canvasSize: CGSize

    init(canvas: CanvasView) {
        self.canvas = canvas
        canvasSize = canvas.bounds.size
        trackpad = TrackpadMover(canvas: canvas) { [weak self] in self?.focus($0) }
        emptyState.frame = canvas.bounds
        emptyState.autoresizingMask = [.width, .height]
        canvas.addSubview(emptyState, positioned: .below, relativeTo: nil)
    }

    private func updateEmptyState() {
        emptyState.setVisible(cards.isEmpty, animated: true)
    }

    /// Re-reads Theme and user settings after they change.
    func applyTheme() {
        for card in cards { card.applyTheme() }
        emptyState.needsDisplay = true
        clampAll()
    }

    /// A card at an S/M/L size for this screen, which it keeps if the canvas later changes size.
    @discardableResult
    func add(_ content: CardContent, preset: SizePreset, aspect: CGFloat, lockAspect: Bool, spawnFrom: CGRect? = nil) -> CardView {
        let size = preset.size(aspect: aspect, in: canvas.bounds)
        let card = add(content, size: size, aspect: lockAspect ? aspect : nil, spawnFrom: spawnFrom)
        card.sizePreset = preset
        return card
    }

    @discardableResult
    /// With `spawnFrom`, the card appears centered there and springs into a free spot.
    func add(_ content: CardContent, size: NSSize, aspect: CGFloat? = nil, spawnFrom: CGRect? = nil) -> CardView {
        let bounds = canvas.bounds
        let step = CGFloat(cards.count % 8) * Config.cascadeOffset
        var start = Snapping.clamp(CGRect(
            x: bounds.minX + Config.padding + step, y: bounds.minY + Config.padding + step,
            width: size.width, height: size.height), in: bounds)
        if let spawnFrom {
            start.origin = CGPoint(x: spawnFrom.midX - size.width / 2, y: spawnFrom.midY - size.height / 2)
        }
        let target = spawnFrom.map { _ in Snapping.freeSpot(for: size, avoiding: cards.map(\.frame), in: bounds) }
        return insert(content, frame: start, aspect: aspect, target: target)
    }

    /// Opens a card next to `source` (right, else left, else below), growing out of its edge.
    @discardableResult
    func add(_ content: CardContent, size: NSSize, aspect: CGFloat? = nil, beside source: CardView) -> CardView {
        let others = cards.filter { $0 !== source }.map { $0.mover.target ?? $0.frame }
        let target = Snapping.besideSpot(for: size, next: source.frame, avoiding: others, in: canvas.bounds)
        let edge = Snapping.edgePoint(of: source.frame, toward: target)
        let start = CGRect(x: edge.x - size.width / 2, y: edge.y - size.height / 2, width: size.width, height: size.height)
        let card = insert(content, frame: start, aspect: aspect, target: target)
        card.animateEntrance()
        return card
    }

    private func insert(_ content: CardContent, frame start: CGRect, aspect: CGFloat?, target: CGRect?) -> CardView {
        let card = CardView(content: content, frame: start)
        card.aspect = aspect
        card.onFocus = { [weak self] in self?.focus($0) }
        card.onMoveEnded = { [weak self] in self?.settle($0, velocity: $1) }
        card.onResizeEnded = { [weak self] card in
            card.sizePreset = nil
            self?.settle(card, velocity: .zero)
        }
        card.onCloseRequested = { [weak self] in self?.close($0) }
        card.onAspectPicked = { [weak self] in self?.setAspect($1, for: $0) }
        card.onSizePicked = { [weak self] in self?.applySize($1, to: $0) }
        content.onRequestClose = { [weak self, weak card] in
            guard let card else { return }
            self?.remove(card)
        }
        canvas.addSubview(card)
        cards.append(card)
        updateEmptyState()
        focus(card)
        if let target { card.mover.animate(to: target) }
        return card
    }

    func focus(_ card: CardView) {
        if canvas.subviews.last !== card {
            canvas.subviews = canvas.subviews.filter { $0 !== card } + [card]
        }
        if focused !== card {
            focused?.isFocused = false
            focused = card
            card.isFocused = true
        }
        card.content.focus()
    }

    /// Finds the card owning a hit view and focuses it.
    func focus(containing view: NSView?) {
        var v = view
        while let current = v {
            if let card = current as? CardView {
                focus(card)
                return
            }
            v = current.superview
        }
    }

    func cycleFocus(by delta: Int) {
        guard !cards.isEmpty else { return }
        let index = focused.flatMap { f in cards.firstIndex { $0 === f } } ?? 0
        let next = (index + delta + cards.count) % cards.count
        focus(cards[next])
    }

    func close(_ card: CardView) {
        guard card.content.confirmClose() else { return }
        remove(card)
    }

    func closeFocused() {
        if let focused { close(focused) }
    }

    private func remove(_ card: CardView) {
        guard cards.contains(where: { $0 === card }) else { return }
        cards.removeAll { $0 === card }
        updateEmptyState()
        card.content.close()
        card.mover.stop()
        card.animateExit { card.removeFromSuperview() }
        if focused === card {
            focused = nil
            if let top = canvas.subviews.last(where: { v in cards.contains { $0 === v } }) as? CardView { focus(top) }
        }
    }

    /// PiP-style release: a fling docks at the anchor nearest the projected point; a slow drop stays, clamped.
    func settle(_ card: CardView, velocity: CGVector) {
        let target = Fling.target(for: card.frame, velocity: velocity, in: canvas.bounds)
        guard target != card.frame else { return }
        let spring: Spring = Fling.isFling(velocity) ? .standard : .rubberBand
        card.mover.animate(to: target, velocity: velocity, spring: spring)
    }

    /// Previews in a column on the right, as large as fits; terminals in a grid in the rest.
    func arrangeAll() {
        let terminals = cards.filter { $0.content.kind == .terminal }
        let previews = cards.filter { $0.content.kind == .web }
        let specs = previews.map { card in
            Snapping.PreviewSpec(aspect: contentAspect(of: card), maxWidth: (card.content as? WebCard)?.viewport.width ?? .infinity)
        }
        let layout = Snapping.arrange(terminals: terminals.count, previews: specs, in: canvas.bounds)
        for (card, frame) in zip(terminals + previews, layout.terminals + layout.previews) {
            card.sizePreset = nil
            setFrame(frame, for: card)
        }
    }

    /// The locked aspect, else the current proportions of the area below the chrome.
    private func contentAspect(of card: CardView) -> CGFloat {
        card.aspect ?? card.frame.width / max(card.frame.height - Theme.chromeHeight, 1)
    }

    /// Applies an S/M/L size for this screen, keeping the locked aspect or the current proportions.
    func applySize(_ preset: SizePreset, to card: CardView, animated: Bool = true) {
        let aspect = contentAspect(of: card)
        var f = card.mover.target ?? card.frame
        f.size = preset.size(aspect: aspect, in: canvas.bounds)
        card.sizePreset = preset
        setFrame(Snapping.clamp(f, in: canvas.bounds, aspect: aspect), for: card, animated: animated)
    }

    /// Locks (or frees) a card's content aspect and resizes it to match: its S/M/L size if it has one, else its width.
    func setAspect(_ aspect: CGFloat?, for card: CardView) {
        card.aspect = aspect
        guard let aspect else { return }
        if let preset = card.sizePreset { return applySize(preset, to: card) }
        var f = card.frame
        f.size.height = f.width / aspect + Theme.chromeHeight
        setFrame(Snapping.clamp(f, in: canvas.bounds, aspect: aspect), for: card)
    }

    /// After the canvas moves or resizes (another screen, Stage Manager): cards with an S/M/L size
    /// take it for the new screen, and every card is pulled back on screen.
    func canvasGeometryChanged() {
        if canvas.bounds.size != canvasSize {
            canvasSize = canvas.bounds.size
            for card in cards { if let preset = card.sizePreset { applySize(preset, to: card, animated: false) } }
        }
        clampAll()
    }

    /// Pulls every card back on screen, e.g. after Stage Manager shifts the window.
    func clampAll() {
        for card in cards where !card.mover.isRunning {
            card.frame = Snapping.clamp(card.frame, in: canvas.bounds, aspect: card.aspect)
        }
    }

    func setFrame(_ frame: CGRect, for card: CardView, animated: Bool = true) {
        guard animated else { card.mover.stop(); card.frame = frame; return }
        card.mover.animate(to: frame)
    }
}
