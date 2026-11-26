import Foundation

private func observationRow(_ finding: ScanFinding) -> [String] {
    let label: String
    switch finding.kind {
    case "target": label = "相关系统事件目标"
    case "suspected": label = "疑似占用，归属未知"
    default: label = "时序或传递线索"
    }
    return [finding.shortcut, label, finding.owner ?? finding.bundleID ?? "未知",
            finding.pid.map(String.init) ?? "—", "未知动作", finding.evidence]
}

func discoveryMarkdown(newBindings: [Binding], newFindings: [ScanFinding], previous: [ScanFinding],
                       scan: ScanSummary?, first: Bool) -> String {
    var parts = ["## 本次新发现"]
    if first {
        parts.append("首次建档。本次可读配置将作为下次比较的起点。")
    } else if newBindings.isEmpty {
        parts.append("与上次配置快照相比，本次没有新识别的快捷键绑定。")
    } else {
        parts.append("本次新识别 \(newBindings.count) 条配置。软件新启用、设置变更或之前无法读取，都可能让绑定首次出现。")
        parts.append(markdownTable(["快捷键", "软件", "动作", "配置来源"],
                                   newBindings.map { [$0.shortcut, $0.owner, $0.action, $0.source] }))
    }

    let headers = ["快捷键", "观察类型", "事件相关软件", "当时 PID", "动作", "依据"]
    if let scan {
        parts.append("### 本次主动扫描")
        if scan.planned == 0 && scan.stopped == nil {
            parts.append("本轮没有待测组合，未执行主动扫描。")
        } else {
            parts.append("计划测试 \(scan.planned) 个组合，已完整测量 \(scan.attempted.count) 个。")
        }
        if let stopped = scan.stopped { parts.append("扫描已停止。理由为「" + markdownText(stopped) + "」。") }
        if scan.stopped != nil {
            parts.append("完成数仅计入通过对照的完整采样。若在发送按键后中止，该组合仍可能已经触发。")
        }
        if scan.findings.isEmpty {
            if !scan.attempted.isEmpty { parts.append("已测组合未产生可报告的事件线索，仍可能由应用处理。") }
        } else {
            let fresh = Set(newFindings.map(FindingIdentity.init))
            parts.append("本次有 \(fresh.count) 条首次记录的观察。事件目标说明该事件发往哪个进程。实际执行的动作仍需验证。")
            parts.append(markdownTable(headers + ["本地记录"], scan.findings.map {
                observationRow($0) + [fresh.contains(FindingIdentity($0)) ? "首次观察" : "曾观察"]
            }))
        }
    } else { parts.append("本次未执行主动扫描。") }

    let observedNow = Set((scan?.findings ?? []).map(FindingIdentity.init))
    let earlier = previous.filter { !observedNow.contains(FindingIdentity($0)) }
    if !earlier.isEmpty {
        parts.append("### 以往观察")
        parts.append("以下记录来自先前扫描，本次未重复观察到。软件和 PID 均对应当时的会话，当前占用情况未知。")
        parts.append(markdownTable(headers, earlier.map(observationRow)))
    }
    return parts.joined(separator: "\n\n") + "\n"
}
