import Foundation

enum KarabinerRules {
    typealias Object = [String: Any]
    private static let owner = "Karabiner-Elements"

    static func bindings(profile: Object, status: Binding.Status) -> [Binding] {
        var rows = simpleMappings(profile, path: "", scope: "", status: status)
        for (index, device) in (profile["devices"] as? [Object] ?? []).enumerated() {
            let ids = device["identifiers"] as? Object ?? [:]
            let scope = "指定设备" + deviceLabel(ids)
            let state = device["ignore"] as? Bool == true ? .disabled : status
            rows += simpleMappings(device, path: "devices[\(index)].", scope: scope, status: state)
        }

        let complex = profile["complex_modifications"] as? Object
        for (ruleIndex, rule) in (complex?["rules"] as? [Object] ?? []).enumerated() {
            let state = rule["enabled"] as? Bool == false ? .disabled : status
            let manipulators = rule["manipulators"] as? [Object] ?? []
            for (index, item) in manipulators.enumerated() {
                guard item["type"] as? String == "basic", let from = item["from"] as? Object,
                      let key = trigger(from) else { continue }
                let title = item["description"] as? String ?? rule["description"] as? String
                let modifiers = from["modifiers"] as? Object
                let optional = modifiers?["optional"] as? [String] ?? []
                let modifierNote = optional.isEmpty ? "" : " · 可叠加 " + optional.map(keyName).joined(separator: "/")
                let scope = conditionLabel(item)
                let path = "complex_modifications.rules[\(ruleIndex)].manipulators[\(index)]"
                let delayed = item["to_delayed_action"] as? Object ?? [:]
                let repeatKey = isSecondPress(item, following: manipulators.dropFirst(index + 1))
                var events: [(String, String, Any?)] = [
                    ("to", repeatKey ? "连按两次 " : "", item["to"]), ("to_if_alone", "单击 ", item["to_if_alone"]),
                    ("to_if_held_down", "长按 ", item["to_if_held_down"]),
                    ("to_after_key_up", "松开 ", item["to_after_key_up"]),
                    ("to_delayed_action.to_if_invoked", "延时触发 ", delayed["to_if_invoked"]),
                    ("to_delayed_action.to_if_canceled", "延时取消 ", delayed["to_if_canceled"])
                ]
                for (i, branch) in (item["to_if_other_key_pressed"] as? [Object] ?? []).enumerated() {
                    let other = (branch["other_keys"] as? [Object] ?? []).compactMap(trigger)
                    guard !other.isEmpty else { continue }
                    events.append(("to_if_other_key_pressed[\(i)].to",
                                   "加按 " + other.joined(separator: " 或 ") + " 时按住 ", branch["to"]))
                }
                if !events.contains(where: { $0.2 != nil }) {
                    rows.append(row(key, action: title ?? "拦截按键", path: path + modifierNote, scope: scope, status: state))
                }
                for (field, gesture, value) in events where value != nil {
                    guard let action = targetSequence(value) else { continue }
                    rows.append(row(gesture + key, action: [title, action].compactMap { $0 }.joined(separator: " → "),
                                    path: path + "." + field + modifierNote, scope: scope, status: state))
                }
            }
        }
        return rows
    }

    // Only label the double-press paths used in Karabiner's documented examples:
    // the same input must arm a time window checked by the higher-priority rule.
    private static func isSecondPress(_ item: Object, following: ArraySlice<Object>) -> Bool {
        guard let conditions = item["conditions"] as? [Object], let from = item["from"] as? NSDictionary else { return false }
        for next in following {
            guard next["type"] as? String == "basic", let nextFrom = next["from"] as? NSDictionary,
                  nextFrom == from, let events = next["to"] as? [Object] else { continue }
            for variable in events.compactMap({ $0["set_variable"] as? Object }) {
                guard let name = variable["name"] as? String else { continue }
                let expired = name + ">system.now.milliseconds"
                if let expression = variable["expression"] as? String,
                   expression.filter({ !$0.isWhitespace }).range(of: #"^system\.now\.milliseconds\+[1-9][0-9]*$"#, options: .regularExpression) != nil,
                   conditions.contains(where: { $0["type"] as? String == "expression_if"
                       && ($0["expression"] as? String)?.filter { !$0.isWhitespace } == expired }) { return true }
                guard variable["value"] as? Int == 1, let delay = next["to_delayed_action"] as? Object,
                      conditions.contains(where: { $0["type"] as? String == "variable_if"
                          && $0["name"] as? String == name && $0["value"] as? Int == 1 }) else { continue }
                let clearsWindow = ["to_if_invoked", "to_if_canceled"].allSatisfy { field in
                    (delay[field] as? [Object] ?? []).contains { event in
                        guard let reset = event["set_variable"] as? Object else { return false }
                        return reset["name"] as? String == name && reset["value"] as? Int == 0 && event["conditions"] == nil
                    }
                }
                if clearsWindow { return true }
            }
        }
        return false
    }

    private static func simpleMappings(_ config: Object, path: String, scope: String, status: Binding.Status) -> [Binding] {
        var rows: [Binding] = []
        for field in ["simple_modifications", "fn_function_keys"] {
            for (index, entry) in mappingEntries(config, field).enumerated() {
                guard let from = entry["from"] as? Object, let key = trigger(from),
                      let target = targetSequence(entry["to"]) else { continue }
                let action = field == "fn_function_keys" ? "功能键映射 → " + target : "映射为 " + target
                rows.append(row(key, action: action, path: "\(path)\(field)[\(index)]", scope: scope, status: status))
            }
        }
        return rows
    }

    private static func mappingEntries(_ settings: Object, _ field: String) -> [Object] {
        if let legacy = settings[field] as? [String: String] {
            return legacy.sorted { $0.key < $1.key }.map { ["from": ["key_code": $0.key], "to": ["key_code": $0.value]] }
        }
        return settings[field] as? [Object] ?? []
    }

    private static func row(_ key: String, action: String, path: String, scope: String, status: Binding.Status) -> Binding {
        let source = "karabiner.json · " + path + (scope.isEmpty ? "" : " · 限定 " + scope)
        return Binding(shortcut: key, owner: owner, action: action, status: status, source: source)
    }

    private static func keyName(_ raw: String) -> String {
        let special = ["caps_lock": "Caps Lock", "spacebar": "Space", "return_or_enter": "Return",
                       "escape": "Esc", "left_arrow": "←", "right_arrow": "→", "up_arrow": "↑", "down_arrow": "↓",
                       "command": "⌘", "control": "⌃", "option": "⌥", "shift": "⇧", "fn": "Fn",
                       "any": "任意修饰键", "vk_none": "无输出"]
        if let label = special[raw] { return label }
        for (prefix, side) in [("left_", "左 "), ("right_", "右 ")] where raw.hasPrefix(prefix) {
            if let label = special[String(raw.dropFirst(prefix.count))] { return side + label }
        }
        if raw.count == 1 || raw.range(of: #"^f[0-9]+$"#, options: .regularExpression) != nil { return raw.uppercased() }
        return raw.replacingOccurrences(of: "_", with: " ")
    }

    private static func eventKey(_ event: Object) -> String? {
        for field in ["key_code", "consumer_key_code", "apple_vendor_keyboard_key_code", "apple_vendor_top_case_key_code"] {
            if let raw = event[field] as? String { return keyName(raw) }
        }
        return nil
    }

    private static func trigger(_ from: Object) -> String? {
        let key: String
        if let simultaneous = from["simultaneous"] as? [Object] {
            let names = simultaneous.compactMap(eventKey)
            guard names.count == simultaneous.count, names.count >= 2 else { return nil }
            key = names.joined(separator: " + ") + "（同时按下）"
        } else if from["any"] as? String == "key_code" {
            key = "任意键"
        } else {
            guard let name = eventKey(from) else { return nil }
            key = name
        }
        let modifiers = from["modifiers"] as? Object
        let mandatory = modifiers?["mandatory"] as? [String] ?? []
        return (mandatory.map(keyName) + [key]).joined(separator: " + ")
    }

    private static func targetSequence(_ raw: Any?) -> String? {
        let events = raw as? [Object] ?? (raw as? Object).map { [$0] } ?? []
        guard !events.isEmpty else { return nil }
        return events.map { event -> String in
            let label: String
            if let name = eventKey(event) {
                let modifiers = event["modifiers"] as? [String] ?? []
                label = (modifiers.map(keyName) + [name]).joined(separator: " + ")
            } else if let button = event["pointing_button"] as? String {
                label = button
            } else if let variable = event["set_variable"] as? Object, let name = variable["name"] as? String {
                label = "设置变量 " + name
            } else if event["shell_command"] != nil {
                label = "运行 Shell 命令"
            } else if let operation = (event["software_function"] as? Object)?.keys.sorted().first {
                label = keyName(operation)
            } else {
                label = event.keys.sorted().map(keyName).joined(separator: ", ")
            }
            let scope = conditionLabel(event)
            return scope.isEmpty ? label : "\(label)（限定 \(scope)）"
        }.joined(separator: " → ")
    }

    private static func deviceLabel(_ ids: Object) -> String {
        let fields = ["vendor_id", "product_id"].compactMap { key in (ids[key] as? Int).map { "\(key)=\($0)" } }
        return fields.isEmpty ? "" : " (" + fields.joined(separator: ", ") + ")"
    }

    private static func conditionLabel(_ item: Object) -> String {
        (item["conditions"] as? [Object] ?? []).map { condition in
            let kind = condition["type"] as? String ?? "条件"
            let details: [String]
            if kind.hasPrefix("frontmost_application") {
                details = (condition["bundle_identifiers"] as? [String] ?? []) + (condition["file_paths"] as? [String] ?? [])
            } else if kind.hasPrefix("device") {
                details = (condition["identifiers"] as? [Object] ?? []).map(deviceLabel).filter { !$0.isEmpty }
            } else {
                details = (condition["name"] as? String).map { [$0] } ?? []
            }
            return ([kind] + details).joined(separator: " ")
        }.joined(separator: "；")
    }
}

func karabinerSelectedProfile() -> KarabinerRules.Object? {
    let file = home.appendingPathComponent(".config/karabiner/karabiner.json")
    let profiles = readJSON(at: file)?["profiles"] as? [KarabinerRules.Object] ?? []
    return profiles.first { $0["selected"] as? Bool == true } ?? profiles.first
}

func karabinerScanExclusions() -> Set<UInt32> {
    guard let profile = karabinerSelectedProfile() else { return [] }
    return KarabinerRules.excludedKeyCodes(profile: profile)
}

extension KarabinerRules {
    static func excludedKeyCodes(profile: Object) -> Set<UInt32> {
        var inputs: [Object] = []
        for settings in [profile] + (profile["devices"] as? [Object] ?? []) {
            for field in ["simple_modifications", "fn_function_keys"] {
                inputs += mappingEntries(settings, field).compactMap { $0["from"] as? Object }
            }
        }
        let complex = profile["complex_modifications"] as? Object
        for rule in complex?["rules"] as? [Object] ?? [] {
            for item in rule["manipulators"] as? [Object] ?? [] {
                if let from = item["from"] as? Object { inputs.append(from) }
                for branch in item["to_if_other_key_pressed"] as? [Object] ?? [] {
                    inputs += branch["other_keys"] as? [Object] ?? []
                }
            }
        }
        let aliases = [
            "spacebar": "space", "return_or_enter": "return", "delete_or_backspace": "delete",
            "delete_forward": "forward delete", "grave_accent_and_tilde": "`", "hyphen": "-",
            "equal_sign": "=", "open_bracket": "[", "close_bracket": "]", "backslash": "\\",
            "semicolon": ";", "quote": "'", "comma": ",", "period": ".", "slash": "/",
            "right_arrow": "right", "left_arrow": "left", "down_arrow": "down", "up_arrow": "up",
            "page_up": "page up", "page_down": "page down", "caps_lock": "caps lock",
            "keypad_period": "keypad .", "keypad_slash": "keypad /", "keypad_asterisk": "keypad *",
            "keypad_hyphen": "keypad -", "keypad_plus": "keypad +", "keypad_equal_sign": "keypad =",
            "keypad_num_lock": "clear", "insert": "help"
        ]
        let modifierKeys: [String: UInt32] = ["left_command": 55, "right_command": 54, "left_shift": 56,
                                               "right_shift": 60, "left_option": 58, "right_option": 61,
                                               "left_control": 59, "right_control": 62, "fn": 63]
        var excluded = Set<UInt32>()
        for input in inputs {
            for key in [input] + (input["simultaneous"] as? [Object] ?? []) {
                if key["any"] as? String == "key_code" { return Set(KeyCombo.keyNames.keys) }
                guard let name = key["key_code"] as? String else { continue }
                let label = aliases[name] ?? name.replacingOccurrences(of: "_", with: " ")
                if let code = modifierKeys[name] ?? KeyCombo.keyCodes[label] { excluded.insert(code) }
            }
        }
        return excluded
    }
}
