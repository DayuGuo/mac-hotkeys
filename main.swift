import Carbon
import Foundation

private let usage = """
mac-hotkeys 盘点这台 Mac 的全局快捷键，并导出 Markdown。

  mac-hotkeys                              生成当前目录的 mac-hotkeys.md，重名时自动编号
  mac-hotkeys export ~/Desktop/快捷键.md     指定输出文件
  mac-hotkeys export [文件] [--all] [--no-probe] [--force]
    --all       包含已停用、应用未运行及只有默认值的配置
    --no-probe  仅读取配置，跳过独占注册探测
    --force     允许替换目标报告

  mac-hotkeys list [--all] [--json | --markdown]           在终端列出配置
  mac-hotkeys coverage [--json | --markdown]               查看六款重点应用的读取结果
  mac-hotkeys probe [组合 ...] [--all] [--json | --markdown]  查看 Carbon 注册状态
  mac-hotkeys probe cmd+space ctrl+option+shift+cmd+t
  mac-hotkeys --version
"""

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

private struct ListReport: Encodable {
    let bindings: [Binding]
    let warnings: [String]
}

struct ProbeResult: Encodable {
    enum Status: String, Encodable { case conflict, registrable, error }

    let shortcut: String
    let status: Status
    let osStatus: Int32
    let knownBindings: [Binding]
}

struct ProbeReport: Encodable {
    let scanned: Int
    let conflicts: Int
    let registrable: Int
    let errors: Int
    let results: [ProbeResult]
    let warnings: [String]
}

private func probe(_ combo: KeyCombo, known: [Binding], target: EventTargetRef) throws -> ProbeResult {
    var reference: EventHotKeyRef?
    let status = RegisterEventHotKey(combo.code, combo.modifiers.rawValue,
                                     EventHotKeyID(signature: 0x4D48_4B59, id: 1), target,
                                     UInt32(kEventHotKeyExclusive), &reference)
    if status == noErr {
        guard let reference else { throw Failure("Carbon did not return a registration reference. Scan stopped.") }
        let released = UnregisterEventHotKey(reference)
        guard released == noErr else {
            throw Failure("Could not release \(combo.label) (OSStatus \(released)). Scan stopped.")
        }
        return ProbeResult(shortcut: combo.label, status: .registrable, osStatus: status, knownBindings: known)
    }
    let result: ProbeResult.Status = status == eventHotKeyExistsErr ? .conflict : .error
    return ProbeResult(shortcut: combo.label, status: result, osStatus: status, knownBindings: known)
}

func probeReport(combos: [KeyCombo], inventory: Inventory, bindings: [Binding], showAll: Bool) throws -> ProbeReport {
    guard inventory.system.sessionStatus == noErr, let target = GetApplicationEventTarget() else {
        throw Failure("无法访问当前登录会话的 Carbon 注册表，未执行探测。")
    }
    let known = Dictionary(grouping: bindings.compactMap { row in
        row.combo.map { ($0, row) }
    }, by: { $0.0 }).mapValues { $0.map { $0.1 } }
    let results = try combos.map { try probe($0, known: known[$0] ?? [], target: target) }
    let conflicts = results.filter { $0.status == .conflict }.count
    let registrable = results.filter { $0.status == .registrable }.count
    return ProbeReport(scanned: results.count, conflicts: conflicts, registrable: registrable,
                       errors: results.count - conflicts - registrable,
                       results: results.filter { showAll || $0.status != .registrable
                           || $0.knownBindings.contains(where: \.isCurrent) }, warnings: inventory.warnings)
}

private enum Format {
    case tsv, markdown, json

    func table(headers: [String], rows: [[String]]) {
        func cell(_ value: String) -> String {
            value.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
        }
        if self == .markdown {
            func row(_ values: [String]) -> String {
                "| " + values.map {
                    cell($0).replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "|", with: "\\|")
                        .replacingOccurrences(of: "`", with: "\\`")
                }
                    .joined(separator: " | ") + " |"
            }
            print(row(headers))
            print(row(headers.map { _ in "---" }))
            rows.forEach { print(row($0)) }
        } else {
            print(headers.joined(separator: "\t"))
            rows.forEach { print($0.map(cell).joined(separator: "\t")) }
        }
    }

    func json<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
}

private func diagnostic(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func run(_ rawArguments: [String]) throws {
    if rawArguments.contains("--help") || rawArguments.contains("-h") { print(usage); return }
    if rawArguments == ["--version"] { print("mac-hotkeys 0.3.0"); return }
    if rawArguments.isEmpty || rawArguments.first == "export" {
        try exportMarkdown(arguments: rawArguments.dropFirst())
        return
    }
    let all = rawArguments.contains("--all")
    let json = rawArguments.contains("--json")
    let markdown = rawArguments.contains("--markdown")
    guard !(json && markdown) else { throw Failure("Choose one of --json or --markdown.") }
    let format: Format = json ? .json : markdown ? .markdown : .tsv
    let options = ["--all", "--json", "--markdown"]
    let arguments = rawArguments.filter { !options.contains($0) }
    let command = arguments.first ?? "list"

    switch command {
    case "list":
        guard arguments.count <= 1 else { throw Failure("list does not take key combinations.") }
        let inventory = Inventory()
        let rows = inventory.bindings().filter { all || $0.isCurrent || $0.status == .saved }
        if format == .json {
            try format.json(ListReport(bindings: rows, warnings: inventory.warnings))
        } else {
            inventory.warnings.forEach(diagnostic)
            format.table(headers: ["Shortcut", "Owner", "Action", "Status", "Source"],
                         rows: rows.map { [$0.shortcut, $0.owner, $0.action, $0.status.rawValue, $0.source] })
        }

    case "coverage":
        guard arguments.count == 1, !all else { throw Failure("coverage takes only an output-format flag.") }
        let rows = Inventory().applicationScans()
        if format == .json {
            try format.json(rows)
        } else {
            format.table(headers: ["App", "Running", "Status", "Bindings", "Details"], rows: rows.map { row in
                [row.owner, row.running.map { $0 ? "yes" : "no" } ?? "unknown",
                 row.status.rawValue, String(row.bindings.count), row.detail]
            })
        }

    case "probe":
        let requested = arguments.dropFirst()
        var seen = Set<KeyCombo>()
        let selected = try requested.compactMap { raw -> KeyCombo? in
            guard let combo = KeyCombo(argument: raw) else {
                throw Failure("Unsupported shortcut '\(raw)'. Use a chord such as ctrl+option+space.")
            }
            return seen.insert(combo).inserted ? combo : nil
        }
        let combos = selected.isEmpty ? KeyCombo.candidates : selected
        let inventory = Inventory()
        let report = try probeReport(combos: combos, inventory: inventory, bindings: inventory.bindings(),
                                     showAll: all || !selected.isEmpty)
        if format == .json {
            try format.json(report)
        } else {
            report.warnings.forEach(diagnostic)
            format.table(headers: ["Shortcut", "Carbon", "OSStatus", "Known bindings (configuration)"],
                         rows: report.results.map { row in
                let owners = row.knownBindings.map { "\($0.owner) · \($0.action) [\($0.status.rawValue)]" }
                return [row.shortcut, row.status.rawValue, String(row.osStatus), owners.joined(separator: "; ")]
            })
            diagnostic("Scanned \(report.scanned) · conflicts \(report.conflicts) · registrable \(report.registrable) · errors \(report.errors)")
        }

    default:
        throw Failure("Unknown command '\(command)'. See mac-hotkeys --help.")
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    diagnostic("mac-hotkeys: \(error)")
    exit(EXIT_FAILURE)
}
