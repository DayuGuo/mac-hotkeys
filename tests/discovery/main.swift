import Foundation

// The normal CLI defines this in main.swift. The test executable has its own entry point.
struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !condition() {
        FileHandle.standardError.write(Data("FAIL (line \(line)): \(message)\n".utf8))
        exit(1)
    }
}

private func key(_ argument: String) -> KeyCombo { KeyCombo(argument: argument)! }

private func testPlan() {
    let known = key("ctrl+option+i")
    let service = key("ctrl+option+b")
    let remapped = key("ctrl+option+c").code
    let gesture = key("ctrl+option+j")
    let bindings = [Binding(known, owner: "Fixture", action: "Open", status: .configured, source: "test"),
                    Binding(shortcut: gesture.label + " ×2", owner: "Fixture", action: "Raise",
                            status: .configured, source: "test")]
    var history = DiscoveryHistory()
    func plan(_ limit: Int) -> ActiveScanPlan {
        // Explicit service keys keep this independent of the host's Services preferences.
        ActiveScanPlan(bindings: bindings, remapped: [remapped], history: history, limit: limit, services: [service])
    }

    let candidates = plan(10_000).candidates
    let set = Set(candidates)
    check(candidates.count == set.count, "duplicate candidates")
    check(set.isDisjoint(with: [known, service, gesture]), "included configured shortcut, service or double press")
    check(!candidates.contains { $0.code == remapped }, "remapped physical key appeared with other modifiers")
    for risky in ["cmd+q", "cmd+shift+w", "cmd+option+v", "cmd+shift+4", "cmd+ctrl+space"] {
        check(!set.contains(key(risky)), "included risky chord \(risky)")
    }
    // The planner works without Carbon probe results. An unconfigured chord may have a listener.
    check(set.contains(key("ctrl+option+e")), "unconfigured chord omitted without a Carbon conflict")
    let first = plan(2)
    check(first.candidates.count == 2 && !first.beginsNewCycle, "invalid initial batch")
    history.update(bindings: bindings, scan: ScanSummary(attempted: first.candidates.map(\.label), planned: 2))
    check(Set(plan(2).candidates).isDisjoint(with: first.candidates), "repeated the previous batch")
    history.update(bindings: bindings, scan: ScanSummary(attempted: candidates.map(\.label), planned: candidates.count))
    let next = plan(2)
    check(next.beginsNewCycle && first.candidates == next.candidates, "exhaustion did not restart rotation")
    history.update(bindings: bindings, scan: ScanSummary(attempted: [next.candidates[0].label], planned: 2,
                                                         beginsNewCycle: next.beginsNewCycle))
    check(history.tried == [next.candidates[0].label], "unfinished samples carried over into the next cycle")
}

private func testAttribution() {
    let combo = key("ctrl+option+e")
    func target(_ pid: Int32, _ evidence: String) -> ActiveEventTarget {
        ActiveEventTarget(pid: pid, name: "App \(pid)", bundleIdentifier: "test.app\(pid)", evidence: evidence)
    }
    func findings(_ targets: [ActiveEventTarget], start: Bool = true, tail: Bool = true,
                  changed: Bool = false) -> [ScanFinding] {
        classify(ActiveSample(startObserved: start, tailIntercepted: tail, tailChanged: changed, targets: targets),
                 combo: combo)
    }
    let weak = target(3, "time_window")
    for signal in ["marker", "same_timestamp"] {
        let result = findings([target(1, signal), weak])
        check(result.count == 1 && result[0].kind == "target" && result[0].pid == 1, "lost a unique strong target")
    }
    for ambiguous in [[weak], [target(1, "marker"), target(2, "same_timestamp")]] {
        let result = findings(ambiguous)
        check(result.count == 1 && result[0].kind == "clue" && result[0].pid == nil && result[0].owner == nil,
              "attributed a weak or ambiguous observation to an app")
    }
    for result in [findings([], tail: false), findings([weak], changed: true)] {
        check(result.count == 1 && result[0].kind == "suspected" && result[0].owner == nil && result[0].pid == nil,
              "assigned an owner to a missing or changed event")
    }
    check(findings([]).isEmpty, "normal passage reported as occupied")
    check(findings([target(1, "marker")], start: false, tail: false).isEmpty, "unobserved start was classified")
}

private func testHistory(_ directory: URL) throws {
    let url = directory.appendingPathComponent("history.json")
    let binding = Binding(key("ctrl+option+d"), owner: "Fixture", action: "Open", status: .configured, source: "test")
    var history = try DiscoveryHistory.load(at: url)
    check(history.isFirst && history.newBindings([binding]).isEmpty, "first run marked existing configuration as new")
    func finding(pid: Int32) -> ScanFinding {
        ScanFinding(shortcut: binding.shortcut, owner: "Fixture", bundleID: "org.example.fixture",
                    pid: pid, evidence: "marker", kind: "target")
    }
    let original = finding(pid: 10)
    let restarted = finding(pid: 20)
    check(history.newFindings([original, restarted]) == [original], "duplicated a target after a PID change")
    history.update(bindings: [binding], scan: ScanSummary(attempted: [binding.shortcut], findings: [original], planned: 1))
    try history.save(at: url)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "history file is not mode 0600")
    history = try DiscoveryHistory.load(at: url)
    check(!history.isFirst && history.newBindings([binding]).isEmpty, "persisted baseline changed")
    check(history.newFindings([restarted]).isEmpty, "reported the same app as new after reload")
    history.update(bindings: [], scan: ScanSummary(findings: [restarted], planned: 0))
    check(history.findings == [restarted], "latest evidence was not retained")
    let legacy = directory.appendingPathComponent("legacy.json")
    try Data(#"{"bindings":[{"shortcut":"⌃⌥D","owner":"Fixture","action":"Open","source":"old"}]}"#.utf8).write(to: legacy)
    let imported = try DiscoveryHistory().loadingLegacyBaseline(from: legacy)
    check(!imported.isFirst && imported.newBindings([binding]).isEmpty, "legacy baseline failed to match")
    let oldReport = directory.appendingPathComponent("legacy.md")
    let markdown = """
    # Mac 全局快捷键清单

    ## 应用快捷键

    | 快捷键 | 软件 | 动作 | 状态 | 依据 |
    | --- | --- | --- | --- | --- |
    | ⌃⌥E | Fixture | Run&#124;Open | 已配置 | fixture |

    ## 系统快捷键

    """
    try Data(markdown.utf8).write(to: oldReport)
    let previous = try DiscoveryHistory().loadingLegacyBaseline(from: oldReport)
    let oldKey = key("ctrl+option+e")
    let oldRow = Binding(oldKey, owner: "Fixture", action: "Run|Open", status: .saved, source: "new")
    check(previous.newBindings([oldRow]).isEmpty, "Markdown baseline did not preserve cell text")
    let plan = ActiveScanPlan(bindings: [], remapped: [], history: previous, limit: 10_000, services: [])
    check(!plan.candidates.contains(oldKey), "a known shortcut in the imported report became a scan candidate")
    try Data("{}".utf8).write(to: url)
    do {
        _ = try DiscoveryHistory.load(at: url)
        check(false, "corrupt history was silently accepted")
    } catch is DecodingError { /* expected */ }
}

private func testKarabiner() {
    let fixture: KarabinerRules.Object = ["complex_modifications": ["rules": [["manipulators": [[
        "type": "basic", "from": ["key_code": "b"], "to_if_alone": [["key_code": "c"]],
        "to_if_held_down": [["key_code": "d"]]
    ]]]]]]
    let bindings = KarabinerRules.bindings(profile: fixture, status: .configured)
    check(Set(bindings.map(\.shortcut)) == ["单击 B", "长按 B"], "single and held branches were merged")
    check(KarabinerRules.excludedKeyCodes(profile: fixture) == [key("ctrl+b").code], "held key not excluded from scan")
}

do {
    guard CommandLine.arguments.count == 2 else { throw Failure("Expected a temporary state directory") }
    testPlan()
    testAttribution()
    try testHistory(URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
    testKarabiner()
    print("Offline discovery checks passed.")
} catch {
    FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
    exit(1)
}
