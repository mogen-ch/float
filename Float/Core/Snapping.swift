import Foundation

/// Pure geometry: keep cards inside the padded canvas and find docking spots.
enum Snapping {
    /// The usable area: the canvas inset by the padding.
    static func area(_ bounds: CGRect, padding: CGFloat = Config.padding) -> CGRect {
        bounds.insetBy(dx: padding, dy: padding)
    }

    /// Moves (and if needed shrinks) a rect so it sits fully inside the padded area.
    /// With a content `aspect`, shrinking keeps it (the chrome strip stays full height).
    static func clamp(
        _ rect: CGRect, in bounds: CGRect, aspect: CGFloat? = nil,
        padding: CGFloat = Config.padding, chrome: CGFloat = Theme.chromeHeight
    ) -> CGRect {
        let a = area(bounds, padding: padding)
        var r = rect
        if let aspect, r.width > a.width || r.height > a.height {
            r.size.width = min(r.width, a.width, (a.height - chrome) * aspect)
            r.size.height = r.width / aspect + chrome
        }
        r.size.width = min(r.width, a.width)
        r.size.height = min(r.height, a.height)
        r.origin.x = min(max(r.minX, a.minX), a.maxX - r.width)
        r.origin.y = min(max(r.minY, a.minY), a.maxY - r.height)
        return r
    }

    /// The 8 docking frames for a card of `size`: 4 corners + 4 edge midpoints of the padded area.
    static func anchors(for size: CGSize, in bounds: CGRect, padding: CGFloat = Config.padding) -> [CGRect] {
        let a = area(bounds, padding: padding)
        let w = min(size.width, a.width), h = min(size.height, a.height)
        let xs = [a.minX, a.midX - w / 2, a.maxX - w]
        let ys = [a.minY, a.midY - h / 2, a.maxY - h]
        var result: [CGRect] = []
        for (i, x) in xs.enumerated() {
            for (j, y) in ys.enumerated() where !(i == 1 && j == 1) {
                result.append(CGRect(x: x, y: y, width: w, height: h))
            }
        }
        return result
    }

    /// The anchor whose center is closest to `point`.
    static func nearestAnchor(to point: CGPoint, size: CGSize, in bounds: CGRect) -> CGRect {
        anchors(for: size, in: bounds).min { distance($0.center, point) < distance($1.center, point) }!
    }

    /// First docking anchor not overlapping any occupied frame; otherwise the center.
    static func freeSpot(for size: CGSize, avoiding occupied: [CGRect], in bounds: CGRect) -> CGRect {
        let spot = anchors(for: size, in: bounds).first { a in
            !occupied.contains { $0.insetBy(dx: -Config.gap / 2, dy: -Config.gap / 2).intersects(a) }
        }
        return spot ?? clamp(CGRect(origin: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), size: size), in: bounds)
    }

    /// Spot for a card opened from `source`: to its right if it fits, else left, else below, preferring
    /// spots no other card covers; if all are taken, cascade from the first one. Clamped to the canvas.
    static func besideSpot(for size: CGSize, next source: CGRect, avoiding occupied: [CGRect], in bounds: CGRect) -> CGRect {
        let a = area(bounds), g = Config.gap
        let candidates = [
            CGRect(x: source.maxX + g, y: source.minY, width: size.width, height: size.height),
            CGRect(x: source.minX - g - size.width, y: source.minY, width: size.width, height: size.height),
            CGRect(x: source.minX, y: source.maxY + g, width: size.width, height: size.height),
        ].filter { a.contains($0) }
        func free(_ r: CGRect) -> Bool { !occupied.contains { $0.intersects(r) } }
        if let spot = candidates.first(where: free) { return spot }
        var spot = clamp(candidates.first ?? CGRect(origin: CGPoint(x: source.maxX + g, y: source.minY), size: size), in: bounds)
        for _ in 0..<8 where !free(spot) {
            spot = clamp(spot.offsetBy(dx: Config.cascadeOffset, dy: Config.cascadeOffset), in: bounds)
        }
        return spot
    }

    /// Midpoint of the side of `source` that faces `target`, where a spawned card grows from.
    static func edgePoint(of source: CGRect, toward target: CGRect) -> CGPoint {
        if target.minX >= source.maxX { return CGPoint(x: source.maxX, y: source.midY) }
        if target.maxX <= source.minX { return CGPoint(x: source.minX, y: source.midY) }
        return CGPoint(x: source.midX, y: target.minY >= source.midY ? source.maxY : source.minY)
    }

    /// While dragging past the edge, the overshoot is damped to sign(d)·|d|^exponent.
    static func rubberBand(_ rect: CGRect, in bounds: CGRect, exponent: CGFloat = Config.rubberBandExponent) -> CGRect {
        let clamped = clamp(rect, in: bounds)
        func band(_ d: CGFloat) -> CGFloat { d == 0 ? 0 : (d < 0 ? -1 : 1) * pow(abs(d), exponent) }
        return clamped.offsetBy(dx: band(rect.minX - clamped.minX), dy: band(rect.minY - clamped.minY))
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

// MARK: - Arrange All

extension Snapping {
    /// A preview for Arrange All: its locked content aspect and the widest it should get (scale 1).
    struct PreviewSpec {
        var aspect: CGFloat
        var maxWidth: CGFloat
    }

    /// Previews first: one column on the right, as wide as fits the height, capped at `Config.previewShare`
    /// of the width and at whatever keeps terminals above `Config.terminalFloor`. Terminals grid in the rest,
    /// the last row stretched. With no terminals the previews take the whole area in the best column count.
    static func arrange(
        terminals: Int, previews: [PreviewSpec], in bounds: CGRect,
        padding: CGFloat = Config.padding, gap: CGFloat = Config.gap, chrome: CGFloat = Theme.chromeHeight
    ) -> (terminals: [CGRect], previews: [CGRect]) {
        let a = area(bounds, padding: padding)
        let maxWidth = previews.map(\.maxWidth).min() ?? .infinity

        /// Widest shared width at which `column` stacked top to bottom fits the height.
        func stackFit(_ column: [PreviewSpec]) -> CGFloat {
            let n = CGFloat(column.count)
            return (a.height - gap * (n - 1) - chrome * n) / column.reduce(0) { $0 + 1 / $1.aspect }
        }
        func columns(_ count: Int) -> [[PreviewSpec]] {
            (0..<count).map { c in stride(from: c, to: previews.count, by: count).map { previews[$0] } }
        }

        var previewCols = 1
        var w: CGFloat = 0
        if !previews.isEmpty && terminals == 0 {
            for count in 1...previews.count {
                let fit = min(columns(count).map(stackFit).min()!, (a.width - gap * CGFloat(count - 1)) / CGFloat(count))
                if fit > w { w = fit; previewCols = count }
            }
        } else if !previews.isEmpty {
            let floor = Config.terminalFloor
            let maxRows = max(1, Int((a.height + gap) / (floor.height + gap)))
            let cols = CGFloat((terminals + maxRows - 1) / maxRows)
            let terminalMin = cols * floor.width + gap * (cols - 1)
            w = min(stackFit(previews), a.width * Config.previewShare, a.width - gap - terminalMin)
        }
        w = max(min(w, maxWidth), Config.minCardSize.width).rounded(.down)

        // Previews: `previewCols` columns of width w, right-aligned, each stacked from the top.
        var previewFrames: [CGRect] = []
        let blockWidth = previews.isEmpty ? 0 : CGFloat(previewCols) * w + gap * CGFloat(previewCols - 1)
        var ys = Array(repeating: a.minY, count: previewCols)
        for (i, p) in previews.enumerated() {
            let col = i % previewCols
            let h = (w / p.aspect + chrome).rounded()
            let x = a.maxX - blockWidth + CGFloat(col) * (w + gap)
            previewFrames.append(CGRect(x: x, y: ys[col], width: w, height: h))
            ys[col] += h + gap
        }

        // Terminals: grid shaped like the default terminal in what's left; the last row shares its width.
        var terminalFrames: [CGRect] = []
        if terminals > 0 {
            let rect = CGRect(x: a.minX, y: a.minY, width: a.width - (blockWidth > 0 ? blockWidth + gap : 0), height: a.height)
            let target = Config.terminalSize.width / Config.terminalSize.height
            let cols = (1...terminals).min { c1, c2 in
                abs(log(cellAspect(terminals, c1, rect, gap) / target)) < abs(log(cellAspect(terminals, c2, rect, gap) / target))
            }!
            let rows = (terminals + cols - 1) / cols
            let cellH = ((rect.height - gap * CGFloat(rows - 1)) / CGFloat(rows)).rounded(.down)
            for i in 0..<terminals {
                let row = i / cols, col = i % cols
                let inRow = CGFloat(min(cols, terminals - row * cols))
                let cellW = ((rect.width - gap * (inRow - 1)) / inRow).rounded(.down)
                terminalFrames.append(CGRect(
                    x: rect.minX + CGFloat(col) * (cellW + gap), y: rect.minY + CGFloat(row) * (cellH + gap),
                    width: cellW, height: cellH))
            }
        }
        return (terminalFrames, previewFrames)
    }

    private static func cellAspect(_ n: Int, _ cols: Int, _ rect: CGRect, _ gap: CGFloat) -> CGFloat {
        let rows = (n + cols - 1) / cols
        let w = (rect.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let h = (rect.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        return max(w, 1) / max(h, 1)
    }
}
