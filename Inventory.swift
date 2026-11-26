import AppKit
import Carbon
import Foundation

struct Binding: Encodable, Hashable {
    enum Status: String, Encodable, Hashable {
        case enabled, configured, saved, disabled, inactive, unverified
    }

    let shortcut: String
    let owner: String
    let action: String
    let status: Status
    let source: String
    let combo: KeyCombo?

    enum CodingKeys: String, CodingKey { case shortcut, owner, action, status, source }

    init(shortcut: String, owner: String, action: String, status: Status, source: String, combo: KeyCombo? = nil) {
        self.shortcut = shortcut
        self.owner = owner
        self.action = action
        self.status = status
        self.source = source
        self.combo = combo
    }

    init(_ combo: KeyCombo, owner: String, action: String, status: Status, source: String) {
        self.init(shortcut: combo.label, owner: owner, action: action, status: status, source: source, combo: combo)
    }

    var isCurrent: Bool { status == .enabled || status == .configured }
}

private func readPlist(at url: URL) -> Any? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
}

func readJSONValue(at url: URL) -> Any? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
}

func readJSON(at url: URL) -> [String: Any]? { readJSONValue(at: url) as? [String: Any] }

let home = FileManager.default.homeDirectoryForCurrentUser
let library = home.appendingPathComponent("Library")

func preferences(_ domain: String) -> [String: Any] {
    let file = library.appendingPathComponent("Preferences/\(domain).plist")
    return readPlist(at: file) as? [String: Any] ?? [:]
}

struct SystemShortcuts {
    private typealias GetValue = @convention(c) (Int32, UnsafeMutablePointer<Int32>,
                                                 UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
    private typealias IsEnabled = @convention(c) (Int32) -> Bool

    let sessionStatus: OSStatus
    let bindings: [Binding]
    let usedLiveIDs: Bool

    init() {
        var shortcuts: Unmanaged<CFArray>?
        sessionStatus = CopySymbolicHotKeys(&shortcuts)
        _ = shortcuts?.takeRetainedValue()

        // The public API does not provide action IDs. Use the optional read-only
        // symbols to associate a live key with the name in Keyboard Settings.
        let skyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        let handle = sessionStatus == noErr ? dlopen(skyLight, RTLD_LAZY | RTLD_LOCAL) : nil
        defer { if let handle { dlclose(handle) } }
        let value = handle.flatMap { dlsym($0, "CGSGetSymbolicHotKeyValue") }
            .map { unsafeBitCast($0, to: GetValue.self) }
        let enabled = handle.flatMap { dlsym($0, "CGSIsSymbolicHotKeyEnabled") }
            .map { unsafeBitCast($0, to: IsEnabled.self) }
        usedLiveIDs = value != nil && enabled != nil

        let domain = "com.apple.symbolichotkeys"
        let overrides = UserDefaults(suiteName: domain)?.dictionary(forKey: "AppleSymbolicHotKeys")
            ?? preferences(domain)["AppleSymbolicHotKeys"] as? [String: Any] ?? [:]

        bindings = Self.actions().compactMap { action in
            var character: Int32 = 0
            var code: Int32 = 0
            var modifiers: Int32 = 0
            if let value, let enabled, value(action.id, &character, &code, &modifiers) == noErr,
               let key = UInt32(exactly: code), let flags = UInt32(exactly: modifiers) {
                return action.binding(code: key, flags: flags, status: enabled(action.id) ? .enabled : .disabled,
                                      source: "macOS symbolic hotkey \(action.id) (live)")
            }

            let entry = overrides[String(action.id)] as? [String: Any]
            let settings = entry?["value"] as? [String: Any]
            let values = settings?["parameters"] as? [UInt32]
            if let values, values.count >= 3 {
                let status: Binding.Status = entry?["enabled"] as? Bool == true ? .configured : .disabled
                return action.binding(code: values[1], flags: values[2], status: status,
                                      source: "macOS symbolic hotkey \(action.id) (preference)")
            }
            let status: Binding.Status = entry?["enabled"] as? Bool == false ? .disabled : .unverified
            return action.binding(code: action.code, flags: action.flags, status: status,
                                  source: "macOS symbolic hotkey \(action.id) (default key)")
        }
    }

    private struct Action {
        let id: Int32
        let name: String
        let code: UInt32
        let flags: UInt32

        func binding(code: UInt32, flags: UInt32, status: Binding.Status, source: String) -> Binding? {
            guard code < 65535 else { return nil }
            let modifiers = Modifiers(cocoa: flags, explicitFunction: self.flags & (1 << 23) != 0)
            return Binding(KeyCombo(code: code, modifiers: modifiers), owner: "macOS", action: name,
                           status: status, source: source)
        }
    }

    private static func actions() -> [Action] {
        let currentResources = "/System/Library/ExtensionKit/Extensions/KeyboardSettings.appex/Contents/Resources"
        let legacyResources = "/System/Library/PreferencePanes/Keyboard.prefPane/Contents/Resources"
        let resources = [currentResources, legacyResources].map { URL(fileURLWithPath: $0) }
        let tables = resources.compactMap { root -> [[String: Any]]? in
            let table = root.appendingPathComponent("en.lproj/DefaultShortcutsTable.xml")
            guard var rows = readPlist(at: table) as? [[String: Any]] else { return nil }
            let spaces = root.appendingPathComponent("DefaultSpacesShortcuts.xml")
            rows += readPlist(at: spaces) as? [[String: Any]] ?? []
            return rows
        }

        func parse(_ rows: [[String: Any]]) -> [Action] {
            rows.flatMap { row -> [Action] in
                if let children = row["elements"] as? [[String: Any]] { return parse(children) }
                guard let id = row["sybmolichotkey"] as? Int32, let label = row["name"] as? String,
                      let key = row["key"] as? UInt32, let flags = row["modifier"] as? UInt32 else { return [] }
                let prefix = "DO_NOT_LOCALIZE: "
                let name = label.hasPrefix(prefix) ? String(label.dropFirst(prefix.count)) : label
                return [Action(id: id, name: name, code: key, flags: flags)]
            }
        }

        let core = [Action(id: 0, name: "Force Quit Applications", code: 53, flags: 1572864),
                    Action(id: 1, name: "Switch to next app", code: 48, flags: 1048576),
                    Action(id: 2, name: "Switch to previous app", code: 48, flags: 1179648),
                    Action(id: 14, name: "Lock Screen", code: 12, flags: 1966080),
                    Action(id: 50, name: "Emoji & Symbols", code: 49, flags: 1310720),
                    Action(id: 60, name: "Select previous input source", code: 49, flags: 262144),
                    Action(id: 61, name: "Select next input source", code: 49, flags: 786432),
                    Action(id: 64, name: "Show Spotlight search", code: 49, flags: 1048576)]
        var seen = Set<Int32>()
        return (parse(tables.first ?? []) + core).filter { seen.insert($0.id).inserted }
    }
}

struct Inventory {
    let system = SystemShortcuts()
    private let runningApps = NSWorkspace.shared.runningApplications

    var canSeeApplications: Bool { system.sessionStatus == noErr && !runningApps.isEmpty }

    var warnings: [String] {
        var messages: [String] = []
        if system.sessionStatus != noErr {
            messages.append("无法读取当前登录会话的系统快捷键（OSStatus \(system.sessionStatus)）。系统条目取自可读偏好或默认键位。")
        } else if !system.usedLiveIDs {
            messages.append("无法读取实时系统动作 ID，系统条目取自可读偏好或默认键位。")
        }
        if !canSeeApplications { messages.append("无法核实应用运行状态。可在已登录这台 Mac 的终端中重新运行。") }
        return messages
    }

    private func state(_ ids: String...) -> Binding.Status {
        guard canSeeApplications else { return .saved }
        return runningApps.contains { app in ids.contains(app.bundleIdentifier ?? "") } ? .configured : .inactive
    }

    func applicationScans() -> [AppShortcutScan] {
        let ids = canSeeApplications ? Set(runningApps.compactMap(\.bundleIdentifier)) : nil
        return AppShortcutReaders(running: ids).scans()
    }

    func bindings(including scans: [AppShortcutScan]? = nil) -> [Binding] {
        let extra = (scans ?? applicationScans()).flatMap(\.bindings)
        let rows = system.bindings + rectangle() + keyboardMaestro() + alfred() + karabiner() + swiftShortcuts() + extra
        return Set(rows).sorted {
            ($0.owner, $0.shortcut, $0.action, $0.status.rawValue, $0.source)
                < ($1.owner, $1.shortcut, $1.action, $1.status.rawValue, $1.source)
        }
    }

    private func rectangle() -> [Binding] {
        let domains = [("com.knollsoft.Hookshot", "Rectangle Pro"), ("com.knollsoft.Rectangle", "Rectangle")]
        return domains.flatMap { domain, owner in
            preferences(domain).compactMap { name, raw -> Binding? in
                guard let entry = raw as? [String: Any], let code = entry["keyCode"] as? UInt32,
                      code < 65535, let flags = entry["modifierFlags"] as? UInt32 else { return nil }
                let mods = Modifiers(cocoa: flags, explicitFunction: true)
                return Binding(KeyCombo(code: code, modifiers: mods), owner: owner, action: name,
                               status: state(domain), source: domain)
            }
        }
    }

    private func keyboardMaestro() -> [Binding] {
        let path = "Application Support/Keyboard Maestro/Keyboard Maestro Macros.plist"
        guard let root = readPlist(at: library.appendingPathComponent(path)) as? [String: Any],
              let groups = root["MacroGroups"] as? [[String: Any]] else { return [] }
        let owner = "Keyboard Maestro"
        let appState = state("com.stairways.keyboardmaestro.engine")
        // USB HID usage numbers are distinct from macOS virtual keycodes.
        let hidArrows: [UInt32: UInt32] = [79: 124, 80: 123, 81: 125, 82: 126]
        return groups.flatMap { group -> [Binding] in
            guard let scope = group["Targeting"] as? [String: Any], scope["Targeting"] as? String == "All",
                  group["Activate"] as? String == "Normal",
                  let macros = group["Macros"] as? [[String: Any]] else { return [] }
            return macros.flatMap { macro -> [Binding] in
                guard let name = macro["Name"] as? String, let triggers = macro["Triggers"] as? [[String: Any]] else { return [] }
                let enabled = group["IsActive"] as? Bool != false && macro["IsActive"] as? Bool != false
                let status: Binding.Status = enabled ? appState : .disabled
                return triggers.compactMap { trigger in
                    let mods = Modifiers(rawValue: trigger["Modifiers"] as? UInt32 ?? 0).intersection(.standardMask)
                    if trigger["MacroTriggerType"] as? String == "HotKey",
                       let code = trigger["KeyCode"] as? UInt32, code < 65535 {
                        let mode = trigger["FireType"] as? String ?? "Pressed"
                        let action = mode == "Pressed" ? name : "\(name) [\(mode)]"
                        return Binding(KeyCombo(code: code, modifiers: mods), owner: owner, action: action,
                                       status: status, source: "Keyboard Maestro Macros.plist")
                    }
                    if trigger["MacroTriggerType"] as? String == "HID", trigger["ElementUsagePage"] as? Int == 7,
                       let usage = trigger["ElementUsage"] as? UInt32, let code = hidArrows[usage],
                       let count = trigger["TapCount"] as? Int, count > 1 {
                        let actualMods = trigger["UseModifiers"] as? Bool == true ? mods : []
                        let key = KeyCombo(code: code, modifiers: actualMods).label
                        return Binding(shortcut: "\(key) ×\(count)", owner: owner, action: "\(name) (device specific)",
                                       status: status, source: "Keyboard Maestro Macros.plist")
                    }
                    return nil
                }
            }
        }
    }

    private func alfred() -> [Binding] {
        let support = library.appendingPathComponent("Application Support/Alfred")
        let path = readJSON(at: support.appendingPathComponent("prefs.json"))?["current"] as? String
        let package = path.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath, relativeTo: support) }
            ?? support.appendingPathComponent("Alfred.alfredpreferences")
        let domain = "com.runningwithcrayons.Alfred"
        let owner = "Alfred"
        let status = state(domain)
        var rows: [Binding] = []
        let actions = package.appendingPathComponent("preferences/features/filesearch/actions/prefs.plist")
        let settings = readPlist(at: actions) as? [String: Any]
        if let entry = settings?["finderSelectionHotkey"] as? [String: Any], let raw = entry["mod"] as? UInt32 {
            let modifiers = Modifiers(cocoa: raw)
            if let code = entry["key"] as? UInt32, code < 65535, !modifiers.isEmpty {
                rows.append(Binding(KeyCombo(code: code, modifiers: modifiers), owner: owner,
                                    action: "Actions for selected files", status: status, source: "Alfred file search settings"))
            } else if entry["string"] as? String == "double tap", !modifiers.isEmpty {
                rows.append(Binding(shortcut: "\(modifiers.symbols) ×2", owner: owner,
                                    action: "Actions for selected files", status: status, source: "Alfred file search settings"))
            }
        }
        let workflows = package.appendingPathComponent("workflows")
        let folders = (try? FileManager.default.contentsOfDirectory(at: workflows, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            guard let info = readPlist(at: folder.appendingPathComponent("info.plist")) as? [String: Any],
                  let name = info["name"] as? String, let objects = info["objects"] as? [[String: Any]] else { continue }
            for object in objects {
                guard object["type"] as? String == "alfred.workflow.trigger.hotkey",
                      let config = object["config"] as? [String: Any],
                      let key = config["hotkey"] as? UInt32, key < 65535,
                      let flags = config["hotmod"] as? UInt32, flags != 0,
                      (config["relatedApps"] as? [Any] ?? []).isEmpty else { continue }
                let combo = KeyCombo(code: key, modifiers: Modifiers(cocoa: flags))
                let workflowState: Binding.Status = info["disabled"] as? Bool == true ? .disabled : status
                rows.append(Binding(combo, owner: owner, action: name, status: workflowState, source: "Alfred workflow"))
            }
        }
        return rows
    }

    private func karabiner() -> [Binding] {
        let path = home.appendingPathComponent(".config/karabiner/karabiner.json")
        guard let profiles = readJSON(at: path)?["profiles"] as? [[String: Any]],
              let profile = profiles.first(where: { $0["selected"] as? Bool == true }),
              let complex = profile["complex_modifications"] as? [String: Any],
              let rules = complex["rules"] as? [[String: Any]] else { return [] }
        let owner = "Karabiner-Elements"
        let appState = state("org.pqrs.Karabiner-Console-User-Server", "org.pqrs.Karabiner-Core-Service")
        return rules.flatMap { rule -> [Binding] in
            let status: Binding.Status = rule["enabled"] as? Bool == false ? .disabled : appState
            let manipulators = rule["manipulators"] as? [[String: Any]] ?? []
            return manipulators.compactMap { manipulator in
                guard let from = manipulator["from"] as? [String: Any], let key = from["key_code"] as? String,
                      let action = manipulator["description"] as? String ?? rule["description"] as? String else { return nil }
                let config = from["modifiers"] as? [String: Any]
                let required = config?["mandatory"] as? [String] ?? []
                let aliases: [String: Modifiers] = ["command": .command, "control": .control,
                                                    "option": .option, "shift": .shift, "fn": .function]
                let mods = required.reduce(Modifiers()) { mods, raw in
                    let normal = raw.replacingOccurrences(of: "left_", with: "").replacingOccurrences(of: "right_", with: "")
                    return mods.union(aliases[normal] ?? [])
                }
                let knownKeys = ["caps_lock": "Caps Lock", "spacebar": "Space", "return_or_enter": "Return"]
                let label = mods.symbols + (knownKeys[key] ?? key.replacingOccurrences(of: "_", with: " "))
                return Binding(shortcut: label, owner: owner, action: action, status: status, source: "karabiner.json")
            }
        }
    }

    private func swiftShortcuts() -> [Binding] {
        var seen = Set<String>()
        return runningApps.flatMap { app -> [Binding] in
            guard let domain = app.bundleIdentifier, !domain.hasPrefix("com.apple."), seen.insert(domain).inserted else { return [] }
            let prefix = "KeyboardShortcuts_"
            return preferences(domain).compactMap { name, raw -> Binding? in
                guard name.hasPrefix(prefix), let value = raw as? String, let data = value.data(using: .utf8),
                      let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let code = entry["carbonKeyCode"] as? UInt32, code < 65535,
                      let flags = entry["carbonModifiers"] as? UInt32 else { return nil }
                let combo = KeyCombo(code: code, modifiers: Modifiers(rawValue: flags).intersection(.standardMask))
                return Binding(combo, owner: app.localizedName ?? domain, action: String(name.dropFirst(prefix.count)),
                               status: .configured, source: "\(domain) (KeyboardShortcuts preference)")
            }
        }
    }
}
