import SwiftUI

/// ⌘, : a small native form. Everything persists in UserDefaults and FloatApp applies it live.
struct SettingsView: View {
    @AppStorage(Config.Keys.terminalFontSize) private var fontSize = 12.0
    @AppStorage(Config.Keys.defaultViewport) private var viewport = Viewport.desktop.rawValue
    @AppStorage(Config.Keys.springDampingRatio) private var damping = 0.82
    @AppStorage(Config.Keys.padding) private var padding = 16.0
    @AppStorage(Config.Keys.optionAsMeta) private var optionAsMeta = false
    let launcherHotkey: String

    var body: some View {
        Form {
            Section {
                Stepper("Terminal font size  \(Int(fontSize)) pt", value: $fontSize,
                        in: Double(Config.terminalFontRange.lowerBound)...Double(Config.terminalFontRange.upperBound))
                Toggle("Use Option as Meta key", isOn: $optionAsMeta)
                Picker("Default viewport", selection: $viewport) {
                    ForEach(Viewport.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                }
            }
            Section {
                LabeledContent("Spring bounce") {
                    Slider(value: $damping, in: Double(Config.dampingRange.lowerBound)...Double(Config.dampingRange.upperBound)) {
                        EmptyView()
                    } minimumValueLabel: { Text("more") } maximumValueLabel: { Text("none") }
                }
                LabeledContent("Card padding  \(Int(padding)) pt") {
                    Slider(value: $padding, in: Double(Config.paddingRange.lowerBound)...Double(Config.paddingRange.upperBound), step: 4)
                }
            }
            Section {
                LabeledContent("Quick launch", value: launcherHotkey)
                LabeledContent("Site permissions") {
                    Button("Reset") { SitePermissions.resetAll() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
    }
}

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(launcherHotkey: String) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(launcherHotkey: launcherHotkey)))
            w.title = "Float Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    static func orderFrontIfOpen() {
        if let window, window.isVisible { window.makeKeyAndOrderFront(nil) }
    }
}
