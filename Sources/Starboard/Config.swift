import Cocoa
import SwiftTerm

/// User configuration, read once at launch from `~/.config/starboard/config.json`.
///
/// Every value in here used to be a compile-time constant, which meant changing
/// the tint, the transparency, the font size or the palette required editing
/// Swift and rebuilding. Those are exactly the things people want to change, and
/// they are also the things whose *defaults* this app has an opinion about — so
/// the defaults stay in code and the file only overrides.
///
/// Deliberately forgiving. A malformed file, an unknown key, a string where a
/// number belongs: each is reported on stderr (which lands in
/// `~/Library/Logs/Starboard.log`) and then ignored, and the panel still starts
/// with defaults. A terminal that refuses to open because of a typo in an
/// optional config file would be a worse tool than one with no config at all.
struct StarboardConfig {

    // MARK: Defaults — the app's opinion, unchanged from before this file existed

    var fontNames: [String] = [
        "MesloLGS NF",
        "MesloLGS Nerd Font",
        "Hack Nerd Font",
        "FiraCode Nerd Font",
        "JetBrainsMono Nerd Font",
        "Menlo",
    ]
    var fontSize: CGFloat = 11
    var padding: CGFloat = 8
    var cornerRadius: CGFloat = 12
    var tint = NSColor(calibratedRed: 0.02, green: 0.035, blue: 0.06, alpha: 0.65)
    var material: NSVisualEffectView.Material = .menu
    var fallbackWidth: CGFloat = 300
    var fallbackHeight: CGFloat = 64
    var fallbackRightMargin: CGFloat = 8
    var dockBottomCorrection: CGFloat = 5
    var dockTopCorrection: CGFloat = 5
    var dockTrackingInterval: TimeInterval = 1.0
    var startExpanded = false
    var palette: [Color] = [
        rgb(20, 24, 33), rgb(198, 74, 90), rgb(79, 157, 105), rgb(196, 154, 62),
        rgb(58, 124, 165), rgb(133, 110, 168), rgb(69, 156, 156), rgb(196, 190, 172),
        rgb(75, 87, 99), rgb(222, 102, 118), rgb(111, 191, 135), rgb(224, 186, 105),
        rgb(95, 168, 211), rgb(169, 143, 201), rgb(114, 214, 207), rgb(230, 224, 208),
    ]

    /// `Color`'s initializer takes 16-bit components; 8-bit * 257 maps
    /// 0...255 onto 0...65535 exactly, since 255 * 257 == 65535.
    static func rgb(_ red: UInt16, _ green: UInt16, _ blue: UInt16) -> Color {
        Color(red: red * 257, green: green * 257, blue: blue * 257)
    }

    // MARK: Loading

    static var path: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("starboard/config.json")
    }

    /// Reads the config, falling back to defaults for anything missing or unusable.
    static func load(from url: URL? = nil) -> StarboardConfig {
        var config = StarboardConfig()
        let file = url ?? path

        guard let data = try? Data(contentsOf: file) else {
            return config // no file is the normal case, not a problem
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            warn("\(file.path): not a JSON object — using defaults")
            return config
        }

        var known: Set<String> = []
        func number(_ key: String) -> CGFloat? {
            known.insert(key)
            guard let raw = root[key] else { return nil }
            guard let n = raw as? NSNumber else {
                warn("\(key): expected a number, got \(type(of: raw)) — ignored")
                return nil
            }
            return CGFloat(n.doubleValue)
        }
        func bool(_ key: String) -> Bool? {
            known.insert(key)
            guard let raw = root[key] else { return nil }
            guard let b = raw as? Bool else {
                warn("\(key): expected true or false — ignored")
                return nil
            }
            return b
        }
        func strings(_ key: String) -> [String]? {
            known.insert(key)
            guard let raw = root[key] else { return nil }
            guard let list = raw as? [String], !list.isEmpty else {
                warn("\(key): expected a non-empty array of strings — ignored")
                return nil
            }
            return list
        }
        func object(_ key: String) -> [String: Any]? {
            known.insert(key)
            guard let raw = root[key] else { return nil }
            guard let dict = raw as? [String: Any] else {
                warn("\(key): expected an object — ignored")
                return nil
            }
            return dict
        }

        if let v = strings("fontNames") { config.fontNames = v }
        if let v = number("fontSize"), v > 0 { config.fontSize = v }
        if let v = number("padding"), v >= 0 { config.padding = v }
        if let v = number("cornerRadius"), v >= 0 { config.cornerRadius = v }
        if let v = number("dockTrackingInterval"), v > 0 { config.dockTrackingInterval = v }
        if let v = bool("startExpanded") { config.startExpanded = v }

        if let tint = object("tint") {
            let get: (String, CGFloat) -> CGFloat = { key, fallback in
                (tint[key] as? NSNumber).map { CGFloat($0.doubleValue) } ?? fallback
            }
            // Accepts either 0...1 components or a "#rrggbb" hex string plus alpha.
            if let hex = tint["hex"] as? String, let colour = NSColor(hex: hex) {
                config.tint = colour.withAlphaComponent(get("alpha", 0.65))
            } else {
                config.tint = NSColor(
                    calibratedRed: get("red", 0.02), green: get("green", 0.035),
                    blue: get("blue", 0.06), alpha: get("alpha", 0.65))
            }
        }

        if let name = root["material"] as? String {
            known.insert("material")
            if let m = Self.material(named: name) {
                config.material = m
            } else {
                warn("material: unknown value '\(name)' — using 'menu'. "
                     + "Known: \(Self.materialNames.keys.sorted().joined(separator: ", "))")
            }
        } else if root["material"] != nil {
            known.insert("material")
            warn("material: expected a string — ignored")
        }

        if let fallback = object("fallback") {
            if let w = (fallback["width"] as? NSNumber)?.doubleValue, w > 0 {
                config.fallbackWidth = CGFloat(w)
            }
            if let h = (fallback["height"] as? NSNumber)?.doubleValue, h > 0 {
                config.fallbackHeight = CGFloat(h)
            }
            if let m = (fallback["rightMargin"] as? NSNumber)?.doubleValue, m >= 0 {
                config.fallbackRightMargin = CGFloat(m)
            }
        }

        if let correction = object("dockCorrection") {
            if let b = (correction["bottom"] as? NSNumber)?.doubleValue {
                config.dockBottomCorrection = CGFloat(b)
            }
            if let t = (correction["top"] as? NSNumber)?.doubleValue {
                config.dockTopCorrection = CGFloat(t)
            }
        }

        // A partial palette is a mistake worth naming: SwiftTerm needs all 16,
        // and silently padding it would produce colours nobody asked for.
        if let hexes = strings("palette") {
            if hexes.count == 16 {
                let parsed = hexes.compactMap { NSColor(hex: $0)?.terminalColor }
                if parsed.count == 16 {
                    config.palette = parsed
                } else {
                    warn("palette: \(16 - parsed.count) entries are not #rrggbb — palette ignored")
                }
            } else {
                warn("palette: expected exactly 16 entries, got \(hexes.count) — ignored")
            }
        }

        // JSON has no comments, so an underscore prefix is the usual stand-in.
        // config.example.json uses it heavily; warning about those would drown
        // the real warnings.
        for key in root.keys.sorted() where !known.contains(key) && !key.hasPrefix("_") {
            warn("unknown key '\(key)' — ignored")
        }
        return config
    }

    /// Writes only the tint back, leaving every other key — including the
    /// _-prefixed comments — as it was. A read-modify-write rather than a dump of
    /// the in-memory struct: dumping would silently materialise every default
    /// into the file, so a later change to a default would no longer reach
    /// anyone who had once used the colour picker.
    static func saveTint(hex: String, alpha: CGFloat, to url: URL? = nil) throws {
        let file = url ?? path
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: file),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root = existing
        }
        root["tint"] = ["hex": hex, "alpha": Double(String(format: "%.3f", alpha)) ?? Double(alpha)]

        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("starboard config: \(message)\n".utf8))
    }

    // MARK: Materials

    static let materialNames: [String: NSVisualEffectView.Material] = [
        "titlebar": .titlebar, "selection": .selection, "menu": .menu,
        "popover": .popover, "sidebar": .sidebar, "headerView": .headerView,
        "sheet": .sheet, "windowBackground": .windowBackground,
        "hudWindow": .hudWindow, "fullScreenUI": .fullScreenUI,
        "toolTip": .toolTip, "contentBackground": .contentBackground,
        "underWindowBackground": .underWindowBackground,
        "underPageBackground": .underPageBackground,
    ]

    static func material(named name: String) -> NSVisualEffectView.Material? {
        materialNames[name]
    }
}

extension NSColor {
    /// Parses `#rrggbb` or `rrggbb`. Returns nil for anything else, so the caller
    /// can report it rather than silently rendering black.
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(
            calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
    }

    /// `#rrggbb`, ignoring alpha — which the config carries separately.
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02x%02x%02x",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }

    /// This colour as a SwiftTerm palette entry.
    var terminalColor: Color {
        let rgb = usingColorSpace(.sRGB) ?? self
        return StarboardConfig.rgb(
            UInt16(round(rgb.redComponent * 255)),
            UInt16(round(rgb.greenComponent * 255)),
            UInt16(round(rgb.blueComponent * 255)))
    }
}
