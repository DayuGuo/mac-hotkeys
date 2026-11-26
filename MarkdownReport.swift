import Foundation

// Keep values from preferences and macro names inside a single, literal table cell.
func markdownText(_ value: String) -> String {
    var output = ""
    for char in value {
        switch char {
        case _ where char.isNewline, "\t": output += " "
        case "&": output += "&amp;"
        case "<": output += "&lt;"
        case ">": output += "&gt;"
        case "|": output += "&#124;"
        case "\\", "`", "*", "_", "[", "]", "~": output += "\\" + String(char)
        default: output.append(char)
        }
    }
    return output
}

func markdownTable(_ headers: [String], _ rows: [[String]]) -> String {
    let divider = Array(repeating: "---", count: headers.count)
    return ([headers, divider] + rows).map { values in
        "| " + values.map(markdownText).joined(separator: " | ") + " |"
    }.joined(separator: "\n")
}

private extension Binding.Status {
    var label: String {
        switch self {
        case .enabled: return "系统已启用"
        case .configured: return "已配置"
        case .saved: return "已保存，运行状态未知"
        case .disabled: return "已停用"
        case .inactive: return "已保存，应用未运行"
        case .unverified: return "默认值待核实"
        }
    }
}

private extension AppShortcutScan.Status {
    var label: String {
        switch self {
        case .bindingsFound: return "读到配置"
        case .noKeyboardRules: return "动作库中无键盘规则"
        case .permissionDenied: return "受权限限制"
        case .noReadableBindings: return "未取得可识别的配置"
        }
    }
}

func renderMarkdown(bindings: [Binding], scans: [AppShortcutScan], probe: ProbeReport?, probeRequested: Bool,
                    warnings: [String], all: Bool, discoveries: String) -> String {
    let clock = DateFormatter()
    clock.locale = Locale(identifier: "en_US_POSIX")
    clock.timeZone = .current
    clock.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let system = bindings.filter { $0.owner == "macOS" }
    let applications = bindings.filter { $0.owner != "macOS" }
    var blocks = [
        "# Mac 全局快捷键清单",
        "\(clock.string(from: Date())) · macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
        "本次列出应用配置 \(applications.count) 条、系统配置 \(system.count) 条。同一组合绑定多个动作时，每个动作各占一行。"
    ]
    if !warnings.isEmpty {
        blocks.append("**采集提示**\n\n" + warnings.map { "- " + markdownText($0) }.joined(separator: "\n"))
    }
    blocks.append(discoveries.trimmingCharacters(in: .newlines))
    let scope = all ? "本次也列出已停用及只有默认值的记录。"
                    : "包含未运行应用已保存的键位。加上 `--all` 可查看已停用及只有默认值的记录。"
    blocks.append("软件归属来自可读配置，仅覆盖工具能识别的设置。实际处理按键的软件仍需通过事件验证。“已配置”表示对应应用正在运行且设置可读，或系统偏好标为启用。“系统已启用”来自当前登录会话。\(scope)")
    blocks.append("⌃ Control　⌥ Option　⇧ Shift　⌘ Command。字母及标点按美式物理键位显示。")
    for (title, rows) in [("应用快捷键", applications), ("系统快捷键", system)] {
        blocks.append("## " + title)
        blocks.append(rows.isEmpty ? "本次没有符合筛选条件的记录。" :
            markdownTable(["快捷键", "软件", "动作", "状态", "依据"], rows.map {
                [$0.shortcut, $0.owner, $0.action, $0.status.label, $0.source]
            }))
    }

    if probeRequested { blocks.append("## 独占注册冲突") }
    if let probe {
        blocks.append("枚举 \(probe.scanned) 个组合，发现 \(probe.conflicts) 个冲突、\(probe.registrable) 个可注册、\(probe.errors) 个探测错误。每次注册成功后立即释放。")
        blocks.append("探测范围是常用物理键配合 ⌃、⌥、⇧、⌘ 的 15 种非空组合。Carbon 只返回注册状态，部分系统保留键也会报告冲突。实际处理进程仍待确认，事件监听、长按、双击或重映射也可能使用可注册的键。")
        let exceptions = probe.results.filter { $0.status != .registrable }
        if !exceptions.isEmpty {
            blocks.append(markdownTable(["快捷键", "结果", "OSStatus", "同键的当前配置线索"], exceptions.map { row in
                let matches = row.knownBindings.filter(\.isCurrent).map { "\($0.owner) · \($0.action)" }
                return [row.shortcut, row.status == .conflict ? "独占注册冲突" : "探测错误", String(row.osStatus),
                        matches.isEmpty ? "未找到" : matches.joined(separator: "、")]
            }))
        }
    } else if probeRequested {
        blocks.append("本次未取得注册探测结果，原因见上方采集提示。")
    }

    blocks.append("## 重点应用读取情况")
    blocks.append("条数包含各应用已保存的配置。“—”表示此次无法确定数量。")
    blocks.append(markdownTable(["应用", "运行状态", "读取结果", "配置条数", "读取范围或原因"], scans.map { scan in
        let state = scan.running.map { $0 ? "运行中" : "未运行" } ?? "未知"
        let count = (scan.status == .bindingsFound || scan.status == .noKeyboardRules) ? String(scan.bindings.count) : "—"
        return [scan.owner, state, scan.status.label, count, scan.detail]
    }))
    return blocks.joined(separator: "\n\n") + "\n"
}
