import AppKit
import Carbon.HIToolbox

/// Physics, layout and behaviour constants. Colours, type and shape live in Theme.
enum Config {
    // MARK: User settings (Settings window, persisted in UserDefaults, read live)

    enum Keys {
        static let terminalFontSize = "terminalFontSize"
        static let defaultViewport = "defaultViewport"
        static let springDampingRatio = "springDampingRatio"
        static let padding = "cardPadding"
        static let optionAsMeta = "optionAsMeta"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Keys.terminalFontSize: 12.0,
            Keys.defaultViewport: Viewport.desktop.rawValue,
            Keys.springDampingRatio: 0.82,
            Keys.padding: 16.0,
            Keys.optionAsMeta: false,
        ])
    }

    static var padding: CGFloat { CGFloat(UserDefaults.standard.double(forKey: Keys.padding)) }
    static var terminalFontSize: CGFloat { CGFloat(UserDefaults.standard.double(forKey: Keys.terminalFontSize)) }
    /// Off, ⌥ types the layout's character (⌥G = @ on Swiss German), like Terminal.app. On, it sends ESC+key for emacs/vim.
    static var optionAsMeta: Bool { UserDefaults.standard.bool(forKey: Keys.optionAsMeta) }
    static var springDampingRatio: CGFloat { CGFloat(UserDefaults.standard.double(forKey: Keys.springDampingRatio)) }
    static var defaultViewport: Viewport {
        Viewport(rawValue: UserDefaults.standard.string(forKey: Keys.defaultViewport) ?? "") ?? .desktop
    }

    static let paddingRange: ClosedRange<CGFloat> = 8...48
    static let dampingRange: ClosedRange<CGFloat> = 0.5...1

    // MARK: Layout

    static let gap: CGFloat = 16
    static let canvasBackgroundAlpha: CGFloat = 0.01
    static let cascadeOffset: CGFloat = 28
    static let resizeZone: CGFloat = 6
    static let minCardSize = NSSize(width: 220, height: 140)

    // Drag lift
    static let liftScale: CGFloat = 1.02

    // Fling + spring (WWDC18 session 803)
    static let velocityWindow: TimeInterval = 0.08
    static let flingDecelerationRate: CGFloat = 0.998
    static let flingMinSpeed: CGFloat = 150
    static let springResponse: CGFloat = 0.4
    static let springRestDistance: CGFloat = 0.5
    static let springRestSpeed: CGFloat = 20
    static let rubberBandExponent: CGFloat = 0.7
    static let rubberBandDampingRatio: CGFloat = 0.6
    static let rubberBandResponse: CGFloat = 0.3
    static let reducedMotionDuration: TimeInterval = 0.15

    /// The terminal shape Arrange All aims its grid cells at.
    static let terminalSize = NSSize(width: 560, height: 360)
    /// Arrange All never squeezes a terminal below this, even to give previews room.
    static let terminalFloor = NSSize(width: 400, height: 220)
    /// Most of the canvas width Arrange All gives previews when terminals share the screen.
    static let previewShare: CGFloat = 0.5
    /// S/M/L never make a card taller than this share of the usable height.
    static let maxCardHeightFraction: CGFloat = 0.9
    /// Smallest preview scale a card can be resized to, and the scale below which its label dims.
    static let minPreviewScale: CGFloat = 0.25
    static let dimPreviewScale: CGFloat = 0.4

    static let terminalInset: CGFloat = 10
    static let terminalFontRange: ClosedRange<CGFloat> = 8...32
    /// Precise trackpad travel per line when the wheel is sent to a full-screen app (claude, vim, less).
    static let terminalScrollPointsPerLine: CGFloat = 16
    /// Cap per event so a hard fling doesn't flood the app with keystrokes.
    static let terminalScrollMaxLinesPerEvent = 8

    static let defaultURL = "localhost:3000"
    static let localRetryInterval: TimeInterval = 2
    /// Schemes a web card loads itself; anything else (mailto:, zoommtg:, …) goes to its own app.
    static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "javascript"]
    static let popupWidthRange: ClosedRange<CGFloat> = 400...800
    static let popupHeightRange: ClosedRange<CGFloat> = 250...800
    static let toastHeight: CGFloat = 28
    static let toastDuration: TimeInterval = 4
    static let promptMaxWidth: CGFloat = 460
    // Empty state: black Helvetia with a white outline
    static let emptyGlyph: CGFloat = 7
    static let emptyOutline: CGFloat = 2
    static let cardEntranceScale: CGFloat = 0.92
    static let cardExitDuration: TimeInterval = 0.2

    // Global hotkeys (⌥⌘)
    private static let optCmd = UInt32(optionKey | cmdKey)
    static let hotkeyNewTerminal = Hotkey(keyCode: UInt32(kVK_ANSI_T), modifiers: optCmd)
    static let hotkeyNewPreview = Hotkey(keyCode: UInt32(kVK_ANSI_P), modifiers: optCmd)
    static let hotkeyArrange = Hotkey(keyCode: UInt32(kVK_ANSI_A), modifiers: optCmd)
    static let hotkeyNext = Hotkey(keyCode: UInt32(kVK_RightArrow), modifiers: optCmd)
    static let hotkeyPrevious = Hotkey(keyCode: UInt32(kVK_LeftArrow), modifiers: optCmd)

    // ⌥Space launcher; falls back to ⌥⌘Space if another app owns ⌥Space.
    static let hotkeyLauncher = Hotkey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
    static let hotkeyLauncherFallback = Hotkey(keyCode: UInt32(kVK_Space), modifiers: optCmd)
    static let launcherWidth: CGFloat = 520
}
