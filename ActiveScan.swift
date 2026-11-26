import Foundation

struct ScanFinding: Codable, Hashable {
    let shortcut: String
    let owner: String?
    let bundleID: String?
    let pid: Int32?
    let evidence: String
    let kind: String
}

struct ScanSummary {
    var attempted: [String] = []
    var findings: [ScanFinding] = []
    var stopped: String?
    var planned: Int
    var beginsNewCycle = false
}

struct ActiveScanPlan {
    let candidates: [KeyCombo]
    let eligible: Int
    let beginsNewCycle: Bool

    init(bindings: [Binding], remapped: Set<UInt32>, history: DiscoveryHistory, limit: Int,
         services: Set<KeyCombo> = serviceKeyEquivalents()) {
        let known = Set(bindings.compactMap(\.combo)).union(services)
        // Gestures such as "Hold ⌘Q" and "⌘Q ×2" may also act on the first press.
        let gestures = Set((Set(bindings.map(\.shortcut)).union(history.knownShortcuts)).map { label in
            label.replacingOccurrences(of: "Hold ", with: "").components(separatedBy: " ×")[0]
        })
        let attributed = Set(history.findings.filter { $0.kind == "target" }.map(\.shortcut))
        let order: [Modifiers] = [
            [.control, .option, .shift, .command], [.control, .option], [.control, .command],
            [.option, .shift], [.control, .shift], [.option, .command],
            [.control, .option, .shift], [.control, .option, .command],
            [.control, .shift, .command], [.option, .shift, .command], [.shift, .command]
        ]
        let names = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").map(String.init)
            + ["Space", "[", "]", "-", "=", ";", ",", ".", "/"] + (13...20).map { "F\($0)" }
        // Keep quit/close, clipboard, save, print, new/open, reload, undo and other
        // destructive or disruptive Command chords out, including their shifted variants.
        let riskyCommandKeys = Set(Array("QWHMNSOPRTXCVZY").map(String.init))
        var eligible: [KeyCombo] = []
        for flags in order {
            for name in names {
                guard let code = KeyCombo.keyCodes[name.lowercased()], !remapped.contains(code) else { continue }
                if name == "Q" || name == "W" { continue }
                if flags.contains(.control), !flags.contains(.command), ["C", "D", "K", "S", "U", "V", "X", "Z"].contains(name) { continue }
                if flags.contains(.command) {
                    if riskyCommandKeys.contains(name) { continue }
                    if flags.contains(.shift) && ["3", "4", "5", "6"].contains(name) { continue }
                    if name == "Space" { continue }
                }
                let combo = KeyCombo(code: code, modifiers: flags)
                guard !known.contains(combo), !gestures.contains(combo.label), !attributed.contains(combo.label) else { continue }
                eligible.append(combo)
            }
        }
        self.eligible = eligible.count
        let untried = eligible.filter { !history.tried.contains($0.label) }
        beginsNewCycle = untried.isEmpty && !eligible.isEmpty
        candidates = Array((beginsNewCycle ? eligible : untried).prefix(limit))
    }
}

// Services can trigger workflows in an eligible frontmost app. Use their
// assigned menu keys only as exclusions, without claiming global ownership.
private func serviceKeyEquivalents() -> Set<KeyCombo> {
    let entries = preferences("pbs")["NSServicesStatus"] as? [String: [String: Any]] ?? [:]
    let marks: [Character: Modifiers] = ["@": .command, "^": .control, "~": .option, "$": .shift]
    return Set(entries.values.compactMap { settings in
        guard let key = settings["key_equivalent"] as? String, let last = key.last,
              let code = KeyCombo.keyCodes[String(last).lowercased()] else { return nil }
        var flags: Modifiers = last.isUppercase ? .shift : []
        for mark in key.dropLast() {
            guard let mod = marks[mark] else { return nil }
            flags.insert(mod)
        }
        return KeyCombo(code: code, modifiers: flags)
    })
}

func classify(_ sample: ActiveSample, combo: KeyCombo) -> [ScanFinding] {
    guard sample.startObserved else { return [] }
    let strong = sample.targets.filter { $0.evidence == "marker" || $0.evidence == "same_timestamp" }
    if strong.count == 1, let t = strong.first {
        let evidence = t.evidence == "marker" ? "携带本次合成按下事件标记" : "与本次按下的事件时间戳相同"
        return [ScanFinding(shortcut: combo.label, owner: t.name ?? t.bundleIdentifier ?? "PID \(t.pid)", bundleID: t.bundleIdentifier,
                            pid: t.pid, evidence: "systemDefined/subtype 6 事件的目标 PID，" + evidence, kind: "target")]
    }
    var notes: [String] = []
    if !sample.tailIntercepted {
        notes.append("起点看见标记按键，末端未见；拦截对照通过")
    } else if sample.tailChanged {
        notes.append("起点与末端的标记相同，键码或修饰键在途中变化")
    }
    let suspected = !notes.isEmpty
    if !sample.targets.isEmpty {
        let ids = sample.targets.map { String($0.pid) }.joined(separator: "、")
        notes.append("同一采样窗内出现系统事件目标 PID \(ids)，无法唯一关联本次按下")
    }
    guard !notes.isEmpty else { return [] }
    return [ScanFinding(shortcut: combo.label, owner: nil, bundleID: nil, pid: nil,
                        evidence: notes.joined(separator: "。"), kind: suspected ? "suspected" : "clue")]
}

func runActiveScan(_ plan: ActiveScanPlan) -> ScanSummary {
    var result = ScanSummary(planned: plan.candidates.count, beginsNewCycle: plan.beginsNewCycle)
    guard !plan.candidates.isEmpty else { return result }
    do {
        let monitor = try ActiveEventMonitor.open()
        defer { monitor.stop() }
        for combo in plan.candidates {
            let sample = try monitor.sample(combo)
            result.attempted.append(combo.label)
            result.findings += classify(sample, combo: combo)
        }
    } catch { result.stopped = String(describing: error) }
    return result
}
