import Cocoa

// A self-check rather than a feature: the point of tagging our menu items is
// that AppKit's additions get removed, and there is no way to right-click in a
// test. This builds the real menu, injects what AppKit would append, runs the
// real strip, and prints what survives. Exits without opening a panel.
if CommandLine.arguments.contains("--dump-menu") {
    let delegate = AppDelegate()
    let menu = delegate.buildContextMenu()
    let ours = menu.items.count

    // Localised on a real system; the titles here only make the output readable.
    for title in ["AutoFill", "Spelling and Grammar", "Substitutions"] {
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
    }
    let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
    services.submenu = NSMenu()
    menu.addItem(services)

    print("OURS \(ours)")
    print("AFTER-INJECTION \(menu.items.count)")
    PanelTerminalView.stripForeignItems(from: menu)
    print("AFTER-STRIP \(menu.items.count)")
    for item in menu.items {
        print("ITEM \(item.isSeparatorItem ? "---" : item.title)")
    }
    exit(0)
}

// Second self-check: the colour picker writes to the config, and the risk worth
// testing is not the colour but everything else in that file. Uses the real
// saveTint, so the test drives the same code the picker does.
if let i = CommandLine.arguments.firstIndex(of: "--save-tint"),
   CommandLine.arguments.count > i + 2 {
    let hex = CommandLine.arguments[i + 1]
    let alpha = Double(CommandLine.arguments[i + 2]) ?? 0.65
    do {
        try StarboardConfig.saveTint(hex: hex, alpha: CGFloat(alpha))
        print("SAVED \(StarboardConfig.path.path)")
        exit(0)
    } catch {
        print("SAVE-FAILED \(error.localizedDescription)")
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
