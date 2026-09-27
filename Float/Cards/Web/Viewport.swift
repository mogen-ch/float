import Foundation

/// Virtual screen a preview lays out at. The page always sees this CSS size and the card shows it
/// scaled, like a live screenshot, so shrinking a card never reflows the page.
enum Viewport: String, CaseIterable {
    case desktop = "Desktop"
    case laptop = "Laptop"
    case tablet = "Tablet"
    case mobile = "Mobile"

    /// Natural CSS size of a common device in this class.
    var size: CGSize {
        switch self {
        case .desktop: CGSize(width: 1440, height: 900)
        case .laptop: CGSize(width: 1280, height: 800)
        case .tablet: CGSize(width: 834, height: 1194)
        case .mobile: CGSize(width: 390, height: 844)
        }
    }

    var width: CGFloat { size.width }

    /// Content aspect (width / height) a card locks to for this viewport.
    var aspect: CGFloat { size.width / size.height }

    /// CSS size the page sees in a content area of `content` points: fixed width, height from the area's shape.
    func virtualSize(for content: CGSize) -> CGSize {
        CGSize(width: width, height: width * content.height / max(content.width, 1))
    }

    /// Screen points per CSS pixel for a content area `cardWidth` points wide.
    func scale(forCardWidth cardWidth: CGFloat) -> CGFloat {
        max(cardWidth, 1) / width
    }

    /// Below this a preview is an unreadable thumbnail.
    var minCardWidth: CGFloat {
        max(Config.minCardSize.width, (width * Config.minPreviewScale).rounded())
    }
}
