import Cocoa
import ApplicationServices
import CoreGraphics
import CoreText
import SwiftTerm

/// `Color`'s public initializer takes 16-bit (0...65535) components; this
/// takes the familiar 8-bit (0...255) form and scales up (`* 257` maps
/// 0...255 onto 0...65535 exactly, since 255 * 257 == 65535).
private func ansiColor(_ red: UInt16, _ green: UInt16, _ blue: UInt16) -> Color {
    Color(red: red * 257, green: green * 257, blue: blue * 257)
}

/// Tag on every menu item Starboard owns.
///
/// Filtering by title would be wrong: AppKit's additions are localised, so
/// "AutoFill" is "Automatisch ausfüllen" on a German system and the match would
/// silently stop working. Marking our own items and dropping everything else is
/// locale-proof and also survives macOS adding new entries later.
let starboardMenuTag = 0x5342 // 'SB'

/// The panel's terminal, with AppKit's context-menu additions removed.
///
/// SwiftTerm's TerminalView conforms to NSTextInputClient, which is what makes
/// macOS treat the panel as a text field and append AutoFill, Services and
/// Spelling to any menu shown on it. Those belong to a form, not to a terminal.
final class PanelTerminalView: LocalProcessTerminalView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        PanelTerminalView.stripForeignItems(from: menu)
    }

    /// Removes every item Starboard did not add. Static and internal so the
    /// --dump-menu self-check can exercise exactly this code.
    static func stripForeignItems(from menu: NSMenu) {
        for item in menu.items.reversed() where item.tag != starboardMenuTag {
            menu.removeItem(item)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var terminalView: PanelTerminalView!
    /// Kept so the colour selector can repaint it live.
    private var tintView: NSView!
    private var trackingTimer: Timer!
    /// Toggled by the hidden Cmd+E menu item. When true, `currentFrame()`
    /// grows the panel upward to the top of the screen instead of matching
    /// the Dock's height — the bottom edge (and x/width) still track the
    /// Dock live, only the top edge changes.
    private var isExpanded = false

    /// Read once at launch from ~/.config/starboard/config.json. Everything
    /// below used to be a compile-time constant; the defaults still live in
    /// StarboardConfig, the file only overrides them. See config.example.json.
    private let config: StarboardConfig

    private var fallbackWidth: CGFloat { config.fallbackWidth }
    private var fallbackHeight: CGFloat { config.fallbackHeight }
    private var fallbackRightMargin: CGFloat { config.fallbackRightMargin }
    private var cornerRadius: CGFloat { config.cornerRadius }
    /// `com.apple.dock`'s preferences domain -- read directly (not via
    /// Accessibility) to detect orientation/auto-hide, since both are
    /// meaningful even before Accessibility permission is granted.
    private let dockPreferencesDomain = "com.apple.dock" as CFString
    private var panelTintColor: NSColor { config.tint }
    private var dockTrackingInterval: TimeInterval { config.dockTrackingInterval }
    /// Empirical corrections for the gap between the Dock's AXList (icon
    /// row) bounding box and its actual painted chrome, which Accessibility
    /// doesn't expose directly. Tuned against a real Dock; nudge these via
    /// dockCorrection in the config if the panel's edges drift on other
    /// displays or tile sizes.
    private var dockBottomCorrection: CGFloat { config.dockBottomCorrection }
    private var dockTopCorrection: CGFloat { config.dockTopCorrection }
    /// Inset between the panel's edge and the terminal content. Together with
    /// fontSize this decides how many rows fit: at a Dock height around
    /// 57-60pt the defaults give exactly two — the current line and the one
    /// before it. Smaller font or padding buys more rows in the same height.
    private var terminalPadding: CGFloat { config.padding }
    /// The shell launched in the panel's pseudo-terminal, and the value
    /// exported as `SHELL` to it (see `childEnvironment`) — kept as one
    /// constant so those two can't drift apart.
    private static let shellExecutable = "/bin/zsh"
    /// Mutable (unlike everything else read from the config) because the
    /// font-size menu items change it at runtime; resized via its own
    /// fontDescriptor so the resolved family survives the change.
    private var terminalFont: NSFont
    /// The live size, seeded from the config and moved by the menu items.
    private var terminalFontSize: CGFloat
    private var starboardAnsiPalette: [Color] { config.palette }

    override init() {
        // First installed font from preferredFontNames, falling back to the
        // monospaced system font (SF Mono) only if none resolve. SF Mono is
        // last on purpose: it's missing glyphs common prompt themes use
        // (e.g. ➜ U+27A4), so it's a worse floor than Menlo, which has
        // broad coverage and is what Terminal.app has defaulted to for
        // years. Menlo in turn still lacks the Nerd Font ranges, hence the
        // patched variants ahead of it.
        //
        // NSFont(name:) returns nil for a name that isn't installed, so a
        // typo here degrades silently rather than failing the build — worth
        // checking the resolved font if the prompt looks wrong.
        let loaded = StarboardConfig.load()
        config = loaded
        terminalFontSize = loaded.fontSize
        terminalFont = loaded.fontNames.lazy.compactMap { NSFont(name: $0, size: loaded.fontSize) }.first
            ?? NSFont.monospacedSystemFont(ofSize: loaded.fontSize, weight: .regular)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Triggers the system Accessibility permission prompt on first
        // launch if not already granted. Needed to read the Dock's icon
        // tray geometry precisely; falls back to an approximation until
        // it's granted (see fallbackFrame below). Result captured (not
        // discarded) to drive the in-terminal hint fed below.
        let promptOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let accessibilityTrusted = AXIsProcessTrustedWithOptions(promptOptions)

        isExpanded = config.startExpanded

        // Report the Accessibility state on stderr, which the LaunchAgent sends
        // to ~/Library/Logs/Starboard.log. Until now the only signal was a line
        // fed into the terminal panel, which no script can read and which
        // scrolls out of a two-row panel almost immediately — so "is the
        // permission actually in effect?" had no answer outside System Settings.
        // scripts/grant-accessibility.sh greps for exactly this line.
        FileHandle.standardError.write(Data(
            "starboard: accessibility trusted = \(accessibilityTrusted ? "yes" : "no")\n".utf8))

        setUpMainMenu()

        let panel = KeyablePanel(
            contentRect: currentFrame(),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        // Present on every Space, including full-screen ones, and skip
        // the app switcher / window cycling entirely.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false

        let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: panel.frame.size))
        effectView.autoresizingMask = [.width, .height]
        effectView.material = config.material
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = cornerRadius
        // Clip subviews to the rounded shape too — otherwise the terminal
        // view (which fills the whole panel edge-to-edge) can paint square
        // corners over the rounded blur.
        effectView.layer?.masksToBounds = true
        // A faint edge highlight, similar to the Dock's own subtle stroke.
        effectView.layer?.borderWidth = 1
        effectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor

        // Starboard's own fixed tint, layered on top of the system blur.
        // The Dock's exact color/opacity is a private, OS-version-tuned
        // recipe (not a public material) that reacts live to the desktop
        // behind it — chasing it means drifting apart on every wallpaper
        // and macOS release. This tint is constant instead: always close
        // to black, independent of what's behind the panel.
        let tintView = NSView(frame: effectView.bounds)
        self.tintView = tintView
        tintView.autoresizingMask = [.width, .height]
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = panelTintColor.cgColor
        effectView.addSubview(tintView)

        let terminal = PanelTerminalView(frame: terminalContentFrame(in: effectView.bounds))
        // Width only — height is recomputed and recentered explicitly in
        // syncFrameToDock, since SwiftTerm's row count is a floor() of
        // pixel height and rarely divides it evenly, leaving slack that
        // needs to be centered rather than pinned to the top or bottom.
        terminal.autoresizingMask = [.width]
        terminal.font = terminalFont
        // Let the blur behind the panel show through instead of the
        // terminal's own opaque background.
        terminal.nativeBackgroundColor = .clear
        terminal.nativeForegroundColor = .labelColor
        terminal.layer?.backgroundColor = NSColor.clear.cgColor
        terminal.installColors(starboardAnsiPalette)
        // The only discoverability hint for Cmd+E/Cmd+Q: there's no menu
        // bar, Dock icon, or button to put one in, and feeding it into the
        // terminal as text (tried for the Accessibility hint above) reads
        // poorly in a panel this short -- it scrolls out of view almost
        // immediately and needs the user to scroll back up to find it. A
        // tooltip costs nothing until someone's cursor is actually
        // sitting still over the panel, which is exactly when it's useful
        // and never otherwise in the way.
        terminal.toolTip = "⌘E expand · ⌘Q quit · right-click for menu"
        // A right-click menu, because the key equivalents are the only other way
        // in: this app has no menu bar it can show, no Dock icon and no title
        // bar, so a user who does not already know ⌘E cannot discover it. AppKit
        // pops this for a right-click on the view without any mouse handling of
        // our own, and it leaves SwiftTerm's left-button selection untouched.
        terminal.menu = buildContextMenu()

        effectView.addSubview(terminal)
        panel.contentView = effectView

        self.panel = panel
        self.terminalView = terminal

        panel.orderFrontRegardless()
        panel.makeFirstResponder(terminal)

        // Ad-hoc signing pins the Accessibility grant to this exact
        // binary's content hash, not the app's path/identifier, so
        // updating Starboard in place (same /Applications/Starboard.app)
        // leaves System Settings showing a "Starboard" row that's already
        // checked on, but silently no longer valid for the new binary --
        // and re-checking that same box doesn't fix it, only removing
        // the row and letting a fresh one get created does. Fed directly
        // into the terminal (bypassing the shell entirely, so it can't be
        // mistaken for shell output or land in history) since that's the
        // only UI this menu-bar-less, Dock-icon-less app has to say
        // anything at all -- there's nowhere else a user would see this.
        // Kept to one short line deliberately: a multi-line explainer
        // (tried first) reads fine right when it's fed, but this panel
        // only ever shows ~2 rows, so it scrolls out of view almost
        // immediately once the shell starts producing its own output --
        // longer didn't mean clearer, just more of it to scroll back to.
        if !accessibilityTrusted {
            terminal.feed(text: "Not glued to Dock? Remove Starboard in System Settings → Accessibility, then re-add it.\r\n\r\n")
        }

        // A persistent login shell, not a new Process per command: cd/pwd
        // state survives between commands, same as a normal terminal tab.
        terminal.startProcess(
            executable: Self.shellExecutable,
            args: ["-l"],
            environment: Self.childEnvironment(),
            currentDirectory: NSHomeDirectory()
        )

        let timer = Timer(timeInterval: dockTrackingInterval, repeats: true) { [weak self] _ in
            self?.syncFrameToDock()
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    /// SwiftTerm's defaults plus `SHELL`.
    ///
    /// Passing `nil` for `startProcess`'s `environment` makes it fall back to
    /// `Terminal.getEnvironmentVariables()`, a deliberately minimal set —
    /// `TERM`, `LANG`, and a few identity variables — that does not include
    /// `SHELL`. In a normal terminal `login(1)` sets that; nothing does here,
    /// so the child shell starts with `SHELL` empty.
    ///
    /// That's not cosmetic. Tools that read `$SHELL` to decide which dialect
    /// to emit guess wrong and produce bash for a zsh session: `ngrok
    /// completion`, run from `.zshrc`, emits a bash completion script whose
    /// `[[ $(type -t compopt) = "builtin" ]]` line makes zsh fail with
    /// `type: bad option: -t` on every launch. Powerlevel10k's instant prompt
    /// then reports the resulting stray output as a configuration warning,
    /// which points at the user's `.zshrc` rather than at the terminal — the
    /// original symptom was several layers removed from this line.
    ///
    /// Appended rather than assigned unconditionally, so that if a future
    /// SwiftTerm starts providing `SHELL` itself, its value wins instead of
    /// being silently shadowed by ours.
    private static func childEnvironment() -> [String] {
        var environment = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        if !environment.contains(where: { $0.hasPrefix("SHELL=") }) {
            environment.append("SHELL=\(shellExecutable)")
        }

        // Identify the terminal, the way every other one does: WezTerm sets
        // TERM_PROGRAM=WezTerm, Apple Terminal Apple_Terminal, iTerm iTerm.app.
        // Without it a Starboard shell is indistinguishable from any other, and
        // that makes Starboard-only behaviour impossible to express: the panel
        // runs a login shell, so anything put in .zshrc to set it up applies to
        // every zsh session on the machine. Attaching this panel to a tmux
        // session, for instance, would hijack every terminal tab as well.
        //
        // With it, the user's own config can branch:
        //
        //     [[ "$TERM_PROGRAM" == Starboard && -z "$TMUX" ]] && tmux attach
        //
        // Appended rather than assigned, so a future SwiftTerm that provides it
        // wins instead of being silently shadowed.
        if !environment.contains(where: { $0.hasPrefix("TERM_PROGRAM=") }) {
            environment.append("TERM_PROGRAM=Starboard")
        }
        // Only when the bundle actually carries a version. Hardcoding one here
        // would be a second copy of VERSION to keep in sync; absent is honest.
        if !environment.contains(where: { $0.hasPrefix("TERM_PROGRAM_VERSION=") }),
           let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !version.isEmpty {
            environment.append("TERM_PROGRAM_VERSION=\(version)")
        }
        return environment
    }

    /// Cmd+C/Cmd+V/Cmd+A only reach a view's copy(_:)/paste(_:)/selectAll(_:)
    /// via AppKit's menu-key-equivalent system — there's no such routing
    /// without a main menu at all, which an accessory app with no Dock icon
    /// otherwise has no reason to set up. This menu is never shown (the
    /// nonactivating panel never makes Starboard the frontmost app, so its
    /// menu bar never displays); it exists purely so those key equivalents
    /// resolve to the terminal view's standard responder-chain actions.
    private func setUpMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Toggle Expanded", action: #selector(toggleExpanded(_:)), keyEquivalent: "e")
        appMenu.addItem(withTitle: "Increase Font Size", action: #selector(increaseFontSize(_:)), keyEquivalent: "+")
        appMenu.addItem(withTitle: "Decrease Font Size", action: #selector(decreaseFontSize(_:)), keyEquivalent: "-")
        appMenu.addItem(withTitle: "Reset Font Size", action: #selector(resetFontSize(_:)), keyEquivalent: "0")
        appMenu.addItem(withTitle: "Quit Starboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    /// The right-click menu. Same actions as the hidden main menu, which is only
    /// reachable by key equivalent — this is the discoverable path to them.
    func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        func add(_ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.tag = starboardMenuTag
            item.target = target
            menu.addItem(item)
        }
        func separator() {
            let item = NSMenuItem.separator()
            item.tag = starboardMenuTag
            menu.addItem(item)
        }

        // No target: routed through the responder chain to the terminal view.
        add("Copy", #selector(NSText.copy(_:)), "c")
        add("Paste", #selector(NSText.paste(_:)), "v")
        add("Select All", #selector(NSText.selectAll(_:)), "a")
        separator()
        add("Toggle Expanded", #selector(toggleExpanded(_:)), "e", target: self)
        add("Increase Font Size", #selector(increaseFontSize(_:)), "+", target: self)
        add("Decrease Font Size", #selector(decreaseFontSize(_:)), "-", target: self)
        add("Reset Font Size", #selector(resetFontSize(_:)), "0", target: self)
        add("Tint Colour…", #selector(chooseTintColour(_:)), "", target: self)
        add("Reveal Config in Finder", #selector(revealConfig(_:)), "", target: self)
        separator()
        add("Quit Starboard", #selector(NSApplication.terminate(_:)), "q")
        return menu
    }

    /// Opens the system colour picker for the panel tint, applying every change
    /// live and writing the result to the config when the panel closes.
    ///
    /// Live rather than on-confirm because the tint sits over a blur on top of
    /// whatever is behind the panel: the same colour reads completely differently
    /// against a bright wallpaper than against a dark one, so picking it against a
    /// swatch is guesswork. Alpha is the transparency, hence showsAlpha.
    @objc private func chooseTintColour(_ sender: Any?) {
        let picker = NSColorPanel.shared
        picker.showsAlpha = true
        picker.color = config.tint
        picker.setTarget(self)
        picker.setAction(#selector(tintColourChanged(_:)))
        // A nonactivating panel never becomes frontmost on its own, so without
        // this the picker opens behind everything and looks like nothing happened.
        NSApp.activate(ignoringOtherApps: true)
        picker.makeKeyAndOrderFront(nil)

        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification,
                                                  object: picker)
        NotificationCenter.default.addObserver(
            self, selector: #selector(tintPickerClosed(_:)),
            name: NSWindow.willCloseNotification, object: picker)
    }

    @objc private func tintColourChanged(_ sender: NSColorPanel) {
        tintView?.layer?.backgroundColor = sender.color.cgColor
    }

    /// Persists on close, not on every drag: the picker emits a change per mouse
    /// movement, and rewriting the file hundreds of times would be absurd.
    @objc private func tintPickerClosed(_ note: Notification) {
        guard let picker = note.object as? NSColorPanel else { return }
        let colour = picker.color
        let alpha = (colour.usingColorSpace(.sRGB) ?? colour).alphaComponent
        do {
            try StarboardConfig.saveTint(hex: colour.hexString, alpha: alpha)
            FileHandle.standardError.write(Data(
                "starboard: tint saved as \(colour.hexString) alpha \(String(format: "%.2f", alpha))\n".utf8))
        } catch {
            FileHandle.standardError.write(Data(
                "starboard: could not save the tint (\(error.localizedDescription))\n".utf8))
        }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification,
                                                  object: picker)
    }

    /// Opens the config directory, creating an annotated starter file when there
    /// is none — otherwise "edit your config" is advice with nowhere to go.
    @objc private func revealConfig(_ sender: Any?) {
        let url = StarboardConfig.path
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data(Self.starterConfig.utf8).write(to: url)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static let starterConfig = """
    {
      "_comment": "Starboard config. Delete any key to fall back to its default.",
      "fontSize": 11,
      "padding": 8,
      "cornerRadius": 12,
      "startExpanded": false,
      "tint": { "hex": "#050910", "alpha": 0.65 },
      "material": "menu",
      "fallback": { "width": 300, "height": 64, "rightMargin": 8 }
    }

    """

    @objc private func increaseFontSize(_ sender: Any?) { setFontSize(terminalFontSize + 1) }
    @objc private func decreaseFontSize(_ sender: Any?) { setFontSize(terminalFontSize - 1) }
    @objc private func resetFontSize(_ sender: Any?) { setFontSize(StarboardConfig().fontSize) }

    /// Applies a new font size live and persists it to the config file.
    ///
    /// The row count follows from the size: the panel's height is the Dock's,
    /// so a smaller font is the way to fit more than the default two rows
    /// without expanding. The terminal frame is recomputed directly (not via
    /// syncFrameToDock, whose early-return fires when the panel frame is
    /// unchanged — which it is here) so SwiftTerm re-derives its rows and the
    /// leftover slack is re-centered for the new cell height.
    private func setFontSize(_ size: CGFloat) {
        let clamped = min(max(size, 6), 32)
        guard clamped != terminalFontSize else { return }
        terminalFontSize = clamped
        // Resize through the descriptor so the resolved family (Nerd Font,
        // Menlo, or the SF Mono fallback) is kept rather than re-looked-up.
        terminalFont = NSFont(descriptor: terminalFont.fontDescriptor, size: clamped) ?? terminalFont
        terminalView.font = terminalFont
        terminalView.frame = terminalContentFrame(in: NSRect(origin: .zero, size: panel.frame.size))
        do {
            try StarboardConfig.saveFontSize(clamped)
        } catch {
            FileHandle.standardError.write(Data(
                "starboard: could not save the font size (\(error.localizedDescription))\n".utf8))
        }
    }

    /// Cmd+E, resolved the same key-equivalent way as Copy/Paste/Select All
    /// above — reaches here even though the hidden menu is never drawn.
    /// Flips between the Dock-height default and full screen height, then
    /// applies immediately rather than waiting for the next tracking tick.
    @objc private func toggleExpanded(_ sender: Any?) {
        isExpanded.toggle()
        syncFrameToDock()
    }

    private func syncFrameToDock() {
        let frame = currentFrame()
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
        terminalView.frame = terminalContentFrame(in: NSRect(origin: .zero, size: frame.size))
    }

    /// Padded frame for the terminal content, vertically centered within
    /// that padding. SwiftTerm derives its row count as
    /// `floor(height / cellHeight)`, which rarely divides the available
    /// height evenly — the leftover slack is centered here rather than
    /// left stuck at the top, which is what a plain edge inset produces.
    private func terminalContentFrame(in bounds: NSRect) -> NSRect {
        let usableWidth = bounds.width - terminalPadding * 2
        let usableHeight = bounds.height - terminalPadding * 2
        let cellHeight = estimatedCellHeight(for: terminalFont)
        let rows = max(1, Int(usableHeight / cellHeight))
        let contentHeight = CGFloat(rows) * cellHeight
        let verticalSlack = (usableHeight - contentHeight) / 2
        return NSRect(
            x: bounds.minX + terminalPadding,
            y: bounds.minY + terminalPadding + verticalSlack,
            width: max(usableWidth, 0),
            height: max(contentHeight, 0)
        )
    }

    /// Mirrors SwiftTerm's own internal cell-height calculation (ascent +
    /// descent + leading, at its default 1.0 line spacing) so the padding
    /// above can predict its row count before SwiftTerm itself lays out.
    private func estimatedCellHeight(for font: NSFont) -> CGFloat {
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        return ceil(ascent + descent + leading)
    }

    /// Sizes and positions the panel as a companion to the Dock: same
    /// height, same bottom margin (so they sit on one baseline), left edge
    /// touching the Dock's right edge, and its own right edge flush against
    /// the screen's right edge (no margin there at all).
    ///
    /// Only ever attempts this for a bottom-anchored Dock on the main
    /// display, not just because that's the only configuration this has
    /// been tuned against: a left/right Dock changes which axis the panel
    /// would need to hug, and a secondary-display Dock lives in a screen
    /// this code never even looks at. Rather than half-supporting those
    /// (partial tracking that's subtly wrong is worse than a fixed
    /// corner), `dockIconTrayFrame` itself returns nil for all of those
    /// cases -- same fallback path as Accessibility not being granted at
    /// all -- and `syncFrameToDock`'s existing 1s poll means switching
    /// Dock settings while Starboard is running re-evaluates this
    /// automatically, in either direction, without any extra observers.
    private func currentFrame() -> NSRect {
        guard let screen = mainDisplayScreen() else {
            return NSRect(x: 0, y: 0, width: fallbackWidth, height: fallbackHeight)
        }

        guard let rawDock = dockIconTrayFrame(on: screen) else {
            return fallbackFrame(on: screen)
        }
        // The AXList's box doesn't quite match the Dock's painted chrome
        // on either edge: its bottom sits above the Dock's real bottom
        // margin, and its top overshoots above the Dock's real top edge
        // (by a smaller amount) — independently tuned corrections for each.
        let minY = rawDock.minY - dockBottomCorrection
        let maxY = rawDock.maxY - dockTopCorrection
        let dock = NSRect(x: rawDock.minX, y: minY, width: rawDock.width, height: maxY - minY)

        let x = dock.maxX
        let width = max(screen.frame.maxX - x, 0)
        // Same bottom edge either way — dock.minY is the shared baseline —
        // but expanded grows the top edge up to the menu bar instead of
        // stopping at the Dock's own height. visibleFrame.maxY (not
        // frame.maxY) is what excludes the menu bar's reserved strip
        // (including notch height) — frame.maxY is the physical screen
        // edge, which the menu bar draws over since it sits at a higher
        // window level than this panel's .floating, not something a frame
        // that merely stops short of it can avoid.
        let height = isExpanded ? screen.visibleFrame.maxY - dock.minY : dock.height
        return NSRect(x: x, y: dock.minY, width: width, height: height)
    }

    /// Used whenever `dockIconTrayFrame` can't be trusted: Accessibility
    /// permission not granted, the Dock's AX tree unreadable, a left/right
    /// Dock, an auto-hiding Dock, or a Dock that isn't on the main
    /// display. The height macOS reserves for the Dock is still readable
    /// without any special permission, from the gap between the screen's
    /// full frame and its visible frame — just not the Dock's actual
    /// width, so this can't touch its right edge.
    private func fallbackFrame(on screen: NSScreen) -> NSRect {
        let reserved = screen.visibleFrame.minY - screen.frame.minY
        let collapsedHeight = reserved > 4 ? reserved : fallbackHeight
        let x = screen.frame.maxX - fallbackWidth - fallbackRightMargin
        // Flush with the screen's true bottom edge — the same baseline the
        // glued panel sits on (dock.minY in currentFrame() also lands right
        // at the Dock's real bottom margin, a hair above this edge, not
        // padded away from it). No separate bottom margin here; only the
        // right edge keeps one, so the panel doesn't touch the screen's
        // corner.
        let y = screen.frame.minY
        let height = isExpanded ? screen.visibleFrame.maxY - y : collapsedHeight
        return NSRect(x: x, y: y, width: fallbackWidth, height: height)
    }

    /// The display hosting the menu bar — i.e. the Dock's home in the
    /// supported configuration — identified via `CGMainDisplayID()`
    /// rather than `NSScreen.main`, which tracks whichever screen
    /// currently has keyboard focus. Using focus here would make this
    /// panel jump screens as the user works across multiple displays,
    /// exactly the "jumping" this is meant to avoid. Quartz/Accessibility
    /// coordinates (used below) are anchored to this display's top-left
    /// corner regardless of how displays are arranged relative to it.
    private func mainDisplayScreen() -> NSScreen? {
        let mainDisplayID = CGMainDisplayID()
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == mainDisplayID
        }
    }

    /// "bottom", "left", or "right". Absent entirely counts as "bottom":
    /// the key is only written once the user changes it away from the
    /// default.
    private func dockOrientation() -> String {
        CFPreferencesAppSynchronize(dockPreferencesDomain)
        return (CFPreferencesCopyAppValue("orientation" as CFString, dockPreferencesDomain) as? String) ?? "bottom"
    }

    private func dockAutoHides() -> Bool {
        (CFPreferencesCopyAppValue("autohide" as CFString, dockPreferencesDomain) as? Bool) ?? false
    }

    /// Tight bounding box of the Dock's icon tray — the `AXList` child of
    /// the Dock process's accessibility tree — read via the Accessibility
    /// API. This is deliberately not the Dock's own window frame: on
    /// modern macOS that frame spans the entire screen (the Dock process
    /// also hosts desktop wallpaper/icon interaction), which is useless
    /// for positioning. Returns nil if Accessibility permission hasn't
    /// been granted yet, the Dock's AX tree can't be read, the Dock isn't
    /// bottom-anchored, it's set to auto-hide, or it isn't on `screen`
    /// (the main display) at all — any of which means "don't track,
    /// fall back" to the caller.
    private func dockIconTrayFrame(on screen: NSScreen) -> NSRect? {
        guard dockOrientation() == "bottom", !dockAutoHides() else { return nil }

        guard let dockApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.dock" }) else {
            return nil
        }

        let axApp = AXUIElementCreateApplication(dockApp.processIdentifier)

        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement]
        else {
            return nil
        }

        guard let list = children.first(where: { axRole(of: $0) == (kAXListRole as String) }) else {
            return nil
        }

        guard let position = axPoint(list, kAXPositionAttribute as CFString),
              let size = axSize(list, kAXSizeAttribute as CFString)
        else {
            return nil
        }

        // AX coordinates are Quartz's top-left-origin space, anchored to
        // the main display regardless of how displays are arranged; flip
        // to AppKit's bottom-left-origin space, still relative to that
        // same origin.
        let flippedY = screen.frame.height - position.y - size.height
        let frame = NSRect(x: position.x, y: flippedY, width: size.width, height: size.height)
        // A Dock on a secondary display would flip to coordinates outside
        // `screen`'s own bounds, since both are anchored to the main
        // display's origin — that's the signal it isn't the one Starboard
        // should be attaching to.
        guard screen.frame.contains(frame) else { return nil }
        return frame
    }

    private func axRole(of element: AXUIElement) -> String? {
        var roleRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success else {
            return nil
        }
        return roleRef as? String
    }

    private func axPoint(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &valueRef) == .success,
              let axValue = valueRef
        else {
            return nil
        }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func axSize(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &valueRef) == .success,
              let axValue = valueRef
        else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(axValue as! AXValue, .cgSize, &size) else { return nil }
        return size
    }
}
