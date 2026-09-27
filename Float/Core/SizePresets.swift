import Foundation

/// Content aspect ratios offered in the card menu. Picking one locks drag-resizing to it.
enum AspectPreset: String, CaseIterable {
    case free = "Free"
    case wide = "16:9"
    case tall = "9:16"
    case square = "1:1"
    case classic = "4:3"

    var ratio: CGFloat? {
        switch self {
        case .free: nil
        case .wide: 16.0 / 9.0
        case .tall: 9.0 / 16.0
        case .square: 1
        case .classic: 4.0 / 3.0
        }
    }
}

/// Card sizes offered in the card menu, relative to the screen so L stays large on a big display.
enum SizePreset: String, CaseIterable {
    case small = "S"
    case medium = "M"
    case large = "L"

    /// Share of the canvas width a landscape card takes (S/M/L = 400/560/800pt on a 1512pt MacBook).
    var widthFraction: CGFloat {
        switch self {
        case .small: 0.265
        case .medium: 0.37
        case .large: 0.53
        }
    }

    /// Share of the usable height a portrait card's content takes.
    var heightFraction: CGFloat {
        switch self {
        case .small: 0.45
        case .medium: 0.65
        case .large: 0.9
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .small: 360
        case .medium: 480
        case .large: 640
        }
    }

    /// Card size (chrome included) for a content `aspect` (width / height) on a canvas of `bounds`.
    func size(
        aspect: CGFloat, in bounds: CGRect,
        padding: CGFloat = Config.padding, chrome: CGFloat = Theme.chromeHeight
    ) -> CGSize {
        let area = bounds.insetBy(dx: padding, dy: padding)
        var w = aspect >= 1
            ? max(minWidth, widthFraction * bounds.width)
            : max(Config.minCardSize.width, heightFraction * area.height * aspect)
        w = min(w, (area.height * Config.maxCardHeightFraction - chrome) * aspect, area.width)
        return CGSize(width: w, height: w / aspect + chrome)
    }
}
