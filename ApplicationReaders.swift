import Foundation
import SQLite3

struct AppShortcutScan: Encodable {
    enum Status: String, Encodable {
        case bindingsFound = "bindings_found"
        case noKeyboardRules = "no_keyboard_rules"
        case permissionDenied = "permission_denied"
        case noReadableBindings = "no_readable_bindings"
    }

    let owner: String
    let running: Bool?
    let status: Status
    let detail: String
    let bindings: [Binding]
}

struct AppShortcutReaders {
    let running: Set<String>?

    private let cleanShotDomains = ["com.getcleanshot.app-setapp", "com.getcleanshot.app", "pl.maketheweb.cleanshotx"]
    private let superchargeDomains = ["com.sindresorhus.Supercharge-setapp", "com.sindresorhus.Supercharge"]

    func scans() -> [AppShortcutScan] {
        [cleanShot(), copyEm(), weChat(), supercharge(), codex(), linguaX(), picGo()]
    }

    private func scan(_ owner: String, domains: [String], bindings: [Binding], detail: String,
                      empty: AppShortcutScan.Status = .noReadableBindings) -> AppShortcutScan {
        AppShortcutScan(owner: owner, running: running.map { !$0.isDisjoint(with: domains) },
                        status: bindings.isEmpty ? empty : .bindingsFound, detail: detail, bindings: bindings)
    }

    private func state(_ domain: String) -> Binding.Status {
        guard let running else { return .saved }
        return running.contains(domain) ? .configured : .inactive
    }

    private func jsonDictionary(_ value: Any) -> [String: Any]? {
        if let entry = value as? [String: Any] { return entry }
        let data = (value as? Data) ?? (value as? String)?.data(using: .utf8)
        guard let data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func cleanShot() -> AppShortcutScan {
        let owner = "CleanShot X"
        let labels = ["LAVAtakeFullscreen": "Capture Fullscreen", "LAVAtakeArea": "Capture Area",
                      "LAVAtakeAllInOne": "All-In-One", "LAVAtakeOCR": "Capture Text (OCR)"]
        let bindings = cleanShotDomains.flatMap { domain in
            preferences(domain).compactMap { key, value -> Binding? in
                guard key.hasPrefix("LAVA"), let entry = jsonDictionary(value),
                      let code = entry["carbonKey"] as? UInt32, code < 65535,
                      let flags = entry["carbonModifiers"] as? UInt32, entry["enabled"] as? Bool != false else { return nil }
                let modifiers = Modifiers(rawValue: flags).intersection(Modifiers.standardMask.union(.function))
                return Binding(KeyCombo(code: code, modifiers: modifiers), owner: owner,
                               action: labels[key] ?? key, status: state(domain), source: "\(domain): \(key)")
            }
        }
        return scan(owner, domains: cleanShotDomains, bindings: bindings, detail: "读取普通版与 Setapp 版偏好中的 LAVA 快捷键")
    }

    private func copyEm() -> AppShortcutScan {
        let owner = "Copy ’Em"
        let domain = "Copy-em-Paste"
        let labels = ["PanelShortcut": "Show clipboard panel", "ToggleRecordingShortcut": "Pause/resume recording",
                      "PastePlainTextShortcut": "Paste as plain text"]
        let store = protectedPreferences(domain)
        let prefs = preferences(domain).merging(store.values) { _, container in container }
        let bindings = labels.compactMap { key, action -> Binding? in
            guard let value = prefs[key], let entry = jsonDictionary(value), entry["enabled"] as? Bool != false else { return nil }
            let combo: KeyCombo
            if let code = entry["carbonKeyCode"] as? UInt32, code < 65535,
               let flags = entry["carbonModifiers"] as? UInt32 {
                combo = KeyCombo(code: code, modifiers: Modifiers(rawValue: flags).intersection(.standardMask))
            } else if let code = entry["keyCode"] as? UInt32, code < 65535,
                      let flags = entry["modifierFlags"] as? UInt32 {
                combo = KeyCombo(code: code, modifiers: Modifiers(cocoa: flags, explicitFunction: true))
            } else { return nil }
            return Binding(combo, owner: owner, action: action, status: state(domain), source: "\(domain): \(key)")
        }
        let detail = store.denied ? "macOS 拒绝读取此应用的偏好容器"
            : "尝试读取面板、暂停录制与粘贴纯文本相关的偏好项，覆盖范围取决于版本"
        return scan(owner, domains: [domain], bindings: bindings, detail: detail,
                    empty: store.denied ? .permissionDenied : .noReadableBindings)
    }

    private func weChat() -> AppShortcutScan {
        let domain = "com.tencent.xinWeChat"
        let store = protectedPreferences(domain)
        let detail = store.denied ? "macOS 拒绝读取微信偏好容器，本工具也尚未验证该版本的键位格式"
            : "本工具尚未验证该版本微信的全局快捷键存储格式"
        return scan("WeChat", domains: [domain], bindings: [], detail: detail,
                    empty: store.denied ? .permissionDenied : .noReadableBindings)
    }

    private func protectedPreferences(_ domain: String) -> (values: [String: Any], denied: Bool) {
        let url = library.appendingPathComponent("Containers/\(domain)/Data/Library/Preferences/\(domain).plist")
        do {
            let data = try Data(contentsOf: url)
            let values = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            return (values as? [String: Any] ?? [:], false)
        } catch {
            let failure = error as NSError
            let denied = failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoPermissionError
            return ([:], denied)
        }
    }

    private func supercharge() -> AppShortcutScan {
        let owner = "Supercharge"
        let modes = ["doubleTap": "⌘Q ×2", "hold": "Hold ⌘Q", "shiftCommand": "⇧⌘Q"]
        let bindings = superchargeDomains.compactMap { domain -> Binding? in
            let prefs = preferences(domain)
            guard let mode = prefs["accidentalQuitPreventionMode"] as? String, let shortcut = modes[mode] else { return nil }
            let press = mode == "shiftCommand" ? KeyCombo(argument: "shift+cmd+q") : nil
            return Binding(shortcut: shortcut, owner: owner, action: "Prevent accidental app quits",
                           status: state(domain), source: "\(domain): accidentalQuitPreventionMode", combo: press)
        }
        return scan(owner, domains: superchargeDomains, bindings: bindings,
                    detail: "读取防误退出设置中的全局按键手势")
    }

    private func codex() -> AppShortcutScan {
        let domain = "com.openai.codex"
        let owner = "ChatGPT / Codex"
        let config = home.appendingPathComponent(".codex")
        let prefs = readJSON(at: config.appendingPathComponent(".codex-global-state.json")) ?? [:]
        let overrides = readJSONValue(at: config.appendingPathComponent("keybindings.json")) as? [[String: Any]] ?? []
        let actions = [("globalDictationHold", "globalDictationHotkey", "Hold to dictate"),
                       ("globalDictationSingleTap", "globalDictationToggleHotkey", "Toggle dictation"),
                       ("appshotHotkey", "appshotHotkey", "Appshot")]
        let bareKeys = ["RightOption": "Right ⌥", "LeftOption": "Left ⌥", "RightControl": "Right ⌃",
                        "LeftControl": "Left ⌃", "RightCommand": "Right ⌘", "LeftCommand": "Left ⌘",
                        "RightShift": "Right ⇧", "LeftShift": "Left ⇧", "Fn": "Fn"]
        let bindings = actions.compactMap { command, stateKey, action -> Binding? in
            let override = overrides.last { $0["command"] as? String == command }
            let raw = override == nil ? prefs[stateKey] : override?["key"]
            guard let key = raw as? String else { return nil }
            let chord = KeyCombo(argument: key)
            guard let shortcut = chord?.label ?? bareKeys[key] else { return nil }
            let source = override == nil ? ".codex-global-state.json" : "keybindings.json"
            return Binding(shortcut: shortcut, owner: owner, action: action, status: state(domain),
                           source: "Codex \(source): \(command)", combo: chord)
        }
        return scan(owner, domains: [domain], bindings: bindings,
                    detail: "读取 com.openai.codex 显式保存的全局听写键和 Appshot 键")
    }

    private func picGo() -> AppShortcutScan {
        let owner = "PicGo"
        let domain = "com.molunerfinn.picgo"
        let path = library.appendingPathComponent("Application Support/picgo/data.json")
        let settings = readJSON(at: path)?["settings"] as? [String: Any]
        let shortcuts = settings?["shortKey"] as? [String: Any] ?? [:]
        // PicGo registers built-in commands directly. Plugin commands also depend on
        // the plugin still being installed and exporting the corresponding handler.
        let bindings = shortcuts.compactMap { id, value -> Binding? in
            guard id.hasPrefix("picgo:"), let entry = value as? [String: Any],
                  let enabled = entry["enable"] as? Bool, let key = entry["key"] as? String,
                  let combo = KeyCombo(argument: key) else { return nil }
            return Binding(combo, owner: owner, action: id == "picgo:upload" ? "上传图片" : id,
                           status: enabled ? state(domain) : .disabled, source: "PicGo settings.shortKey · \(id)")
        }
        return scan(owner, domains: [domain], bindings: bindings,
                    detail: "读取 settings.shortKey 中保存的 PicGo 内置全局快捷键")
    }

    private func linguaX() -> AppShortcutScan {
        let domain = "com.deepzz.LinguaX"
        let owner = "LinguaX"
        let path = library.appendingPathComponent("Application Support/LinguaX/LinguaX.sqlite").path
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil)
        defer { if let database { sqlite3_close(database) } }
        let unavailable = scan(owner, domains: [domain], bindings: [], detail: "无法读取本机动作映射数据库")
        guard opened == SQLITE_OK, let database else { return unavailable }

        let query = "SELECT COUNT(*), COUNT(CASE WHEN ZTRIGGERTYPE = 'mouse' THEN 1 END) FROM ZACTIONMAPPING"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else { return unavailable }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return unavailable }
        let total = sqlite3_column_int64(statement, 0)
        let mouse = sqlite3_column_int64(statement, 1)
        if total == mouse {
            return scan(owner, domains: [domain], bindings: [],
                        detail: "动作映射库中有 \(mouse) 条鼠标规则、0 条键盘规则",
                        empty: .noKeyboardRules)
        }
        return scan(owner, domains: [domain], bindings: [],
                    detail: "动作库中有 \(total - mouse) 条非鼠标规则，触发器格式待验证")
    }
}
