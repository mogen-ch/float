import AppKit
import SwiftTerm

/// A login shell in a SwiftTerm view.
@MainActor
final class TerminalCard: CardContent {
    let kind = CardKind.terminal
    private let terminal = ShellView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
    private(set) var title: String
    /// ⌘+ / ⌘- steps on top of the size set in Settings.
    private var zoomSteps: CGFloat = 0
    private var fontSize: CGFloat {
        min(max(Config.terminalFontSize + zoomSteps, Config.terminalFontRange.lowerBound), Config.terminalFontRange.upperBound)
    }
    var onTitleChange: ((String) -> Void)?
    var onRequestClose: (() -> Void)?

    /// Wrapper that gives the text a small margin from the card edge.
    let view = NSView()

    /// Remembered so new terminals open where you last were.
    static var lastDirectory: String {
        get { UserDefaults.standard.string(forKey: "lastDirectory") ?? NSHomeDirectory() }
        set { UserDefaults.standard.set(newValue, forKey: "lastDirectory") }
    }

    init(directory: String = TerminalCard.lastDirectory, command: String? = nil) {
        title = (directory as NSString).lastPathComponent
        terminal.processDelegate = self
        view.wantsLayer = true
        view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        terminal.frame = view.bounds.insetBy(dx: Config.terminalInset, dy: Config.terminalInset)
        terminal.autoresizingMask = [.width, .height]
        view.addSubview(terminal)
        applyTheme()

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        terminal.startProcess(
            executable: shell, args: ["-l"], environment: Self.environment(),
            execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: directory)
        TerminalCard.lastDirectory = directory
        RecentDirectories.add(directory)
        // Typed ahead before zsh's line editor starts, the command would be echoed twice; wait for the prompt.
        if let command {
            terminal.onFirstOutput = { [weak self] in self?.send(command + "\n") }
        }
        terminal.onOutput = { [weak self] in self?.scheduleTitleRefresh() }
    }

    private static func environment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Float"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env.map { "\($0.key)=\($0.value)" }
    }

    func send(_ text: String) {
        terminal.send(data: ArraySlice(Array(text.utf8)))
    }

    /// The shell's working directory, read from the kernel (works without OSC 7 support).
    var currentDirectory: String? {
        let pid = terminal.process.shellPid
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    func focus() {
        terminal.window?.makeFirstResponder(terminal)
        if let dir = currentDirectory { TerminalCard.lastDirectory = dir }
    }

    /// True when something other than the shell owns the terminal (vim, claude, a dev server...).
    private var hasForegroundJob: Bool { foregroundJob != nil }

    /// Name of the process group the shell has handed the terminal to (claude, vim…), nil at the prompt.
    private var foregroundJob: String? {
        guard let process = terminal.process, process.running, process.childfd >= 0 else { return nil }
        let group = tcgetpgrp(process.childfd)
        guard group > 0, group != process.shellPid else { return nil }
        var name = [UInt8](repeating: 0, count: 256)
        let length = Int(proc_name(group, &name, UInt32(name.count)))
        guard length > 0 else { return "job" }
        return String(decoding: name.prefix(length), as: UTF8.self)
    }

    /// "float · claude": the working directory's name, plus the foreground job when there is one.
    private func refreshTitle() {
        titleRefreshPending = false
        guard let dir = currentDirectory else { return }
        var newTitle = (dir as NSString).lastPathComponent
        if let job = foregroundJob { newTitle += " · " + job }
        guard newTitle != title else { return }
        title = newTitle
        onTitleChange?(newTitle)
    }

    private var titleRefreshPending = false

    /// Output is the cheap signal that the directory or foreground job may have changed; coalesce it.
    private func scheduleTitleRefresh() {
        guard !titleRefreshPending else { return }
        titleRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refreshTitle() }
    }

    func confirmClose() -> Bool {
        guard hasForegroundJob else { return true }
        let alert = NSAlert()
        alert.messageText = "Close “\(title)”?"
        alert.informativeText = "A process is still running in this terminal."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func close() {
        terminal.processDelegate = nil
        if let dir = currentDirectory { TerminalCard.lastDirectory = dir }
        terminal.process.terminate()
    }

    func zoom(by step: Int) {
        zoomSteps += CGFloat(step)
        terminal.font = Theme.mono(fontSize)
    }

    /// Colours, ANSI palette and font from the theme; also re-reads the font size from Settings.
    func applyTheme() {
        let t = Theme.current
        terminal.optionAsMetaKey = Config.optionAsMeta
        terminal.font = Theme.mono(fontSize)
        terminal.nativeBackgroundColor = t.terminalBackground
        terminal.nativeForegroundColor = t.terminalForeground
        terminal.caretColor = t.terminalCaret
        terminal.selectedTextBackgroundColor = t.accent.withAlphaComponent(0.3)
        terminal.installColors(t.ansi.map { c in
            let rgb = c.usingColorSpace(.sRGB) ?? c
            return SwiftTerm.Color(red: UInt16(rgb.redComponent * 65535), green: UInt16(rgb.greenComponent * 65535), blue: UInt16(rgb.blueComponent * 65535))
        })
        view.layer?.backgroundColor = t.terminalBackground.cgColor
        // SwiftTerm hard-codes a legacy scroller whose track reads as a grey bar on Night; trackpad scrolling
        // still works without it, and its reserved width becomes right-hand padding.
        for case let scroller as NSScroller in terminal.subviews { scroller.isHidden = true }
    }
}

extension TerminalCard: @preconcurrency LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    /// OSC titles vary by program; the chrome shows directory and job instead, so just refresh that.
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        scheduleTitleRefresh()
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let path = URL(string: directory)?.path ?? Optional(directory), !path.isEmpty else { return }
        TerminalCard.lastDirectory = path
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in self?.onRequestClose?() }
    }
}

/// Reports the shell's first output (its prompt), so a queued command goes in after the line editor is up.
private final class ShellView: LocalProcessTerminalView, ScrollInterceptor {
    var onFirstOutput: (() -> Void)?
    var onOutput: (() -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?()
        guard let first = onFirstOutput else { return }
        onFirstOutput = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { first() }
    }

    private var wheel = WheelLines(pointsPerLine: Config.terminalScrollPointsPerLine, maxLinesPerEvent: Config.terminalScrollMaxLinesPerEvent)

    /// SwiftTerm 1.11 only scrolls its own scrollback (and its scrollWheel isn't open), so full-screen apps
    /// (claude, vim, less) never see the wheel. Like iTerm2 and Terminal.app: report it as buttons 4/5 when the
    /// app tracks the mouse, otherwise send arrow keys on the alternate screen; the main screen keeps scrollback.
    func interceptScroll(_ event: NSEvent) -> Bool {
        let t = terminal!
        let reportsMouse = allowMouseReporting && [.vt200, .buttonEventTracking, .anyEvent].contains(t.mouseMode)
        guard reportsMouse || t.isCurrentBufferAlternate else { return false }

        if event.phase.contains(.began) { wheel.reset() }
        let lines = wheel.lines(delta: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
        guard lines != 0 else { return true }

        if reportsMouse {
            let flags = event.modifierFlags
            let button = t.encodeButton(button: lines > 0 ? 4 : 5, release: false, shift: flags.contains(.shift),
                                        meta: flags.contains(.option), control: flags.contains(.control))
            let (col, row) = cell(at: convert(event.locationInWindow, from: nil))
            for _ in 0..<abs(lines) { t.sendEvent(buttonFlags: button, x: col, y: row) }
        } else {
            send(data: ArraySlice(WheelLines.arrowKeys(lines: lines, applicationCursor: t.applicationCursor)))
        }
        return true
    }

    /// Grid cell under a point; SwiftTerm's own hit test is internal, and wheel reports only need to be close.
    private func cell(at point: CGPoint) -> (col: Int, row: Int) {
        let t = terminal!
        let width = bounds.width - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let col = Int(point.x / max(1, width / CGFloat(t.cols)))
        let row = Int((bounds.height - point.y) / max(1, bounds.height / CGFloat(t.rows)))
        return (min(max(col, 0), t.cols - 1), min(max(row, 0), t.rows - 1))
    }
}
