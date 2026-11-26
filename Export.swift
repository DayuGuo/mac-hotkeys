import Darwin
import Foundation

// RENAME_EXCL publishes the complete report only if the destination is still free.
private func writeMarkdown(_ text: String, path: String?, overwrite: Bool) throws -> URL {
    let destination = URL(fileURLWithPath: path ?? "mac-hotkeys.md").standardizedFileURL
    let folder = destination.deletingLastPathComponent()
    let temporary = folder.appendingPathComponent(".mac-hotkeys-\(UUID().uuidString).tmp")
    try Data(text.utf8).write(to: temporary, options: .withoutOverwriting)
    defer { try? FileManager.default.removeItem(at: temporary) }
    var candidate = destination
    var number = 1
    while true {
        let result = overwrite ? rename(temporary.path, candidate.path)
                               : renamex_np(temporary.path, candidate.path, UInt32(RENAME_EXCL))
        if result == 0 { return candidate }
        let code = errno
        if !overwrite && code == EEXIST {
            guard path == nil else { throw Failure("目标文件已存在。若要覆盖，请加 --force。\n\(candidate.path)") }
            number += 1
            candidate = folder.appendingPathComponent("mac-hotkeys-\(number).md")
        } else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                          userInfo: [NSFilePathErrorKey: candidate.path])
        }
    }
}

private final class HistoryLock {
    let fd: Int32

    init(in folder: URL, filename: String = "discovery.lock") throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lock = folder.appendingPathComponent(filename)
        let descriptor = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw Failure("无法独占本地发现记录，可能已有另一个扫描正在运行。")
        }
        fd = descriptor
    }

    deinit { close(fd) }
}

private struct ExportOptions {
    var path: String?
    var all = false
    var probe = false
    var active: Bool
    var preview = false
    var selfTest = false
    var overwrite = false
    var limit = 32
    var baseline: URL?
    var stateDir = library.appendingPathComponent("Application Support/mac-hotkeys", isDirectory: true)

    init(arguments: ArraySlice<String>, active: Bool) throws {
        self.active = active
        var rest = arguments
        func next(_ option: String) throws -> String {
            guard let s = rest.popFirst(), !s.isEmpty, !s.hasPrefix("-") else { throw Failure("\(option) 缺少参数。") }
            return s
        }
        while let option = rest.popFirst() {
            switch option {
            case "--all": all = true
            case "--probe": probe = true
            case "--no-probe": probe = false
            case "--scan": self.active = true
            case "--dry-run": preview = true; self.active = true
            case "--self-test": selfTest = true; self.active = true
            case "--force": overwrite = true
            case "--limit":
                guard let n = Int(try next(option)), n > 0 else { throw Failure("--limit 需要正整数。") }
                limit = n
            case "--baseline":
                baseline = URL(fileURLWithPath: (try next(option) as NSString).expandingTildeInPath)
            case "--state-dir":
                stateDir = URL(fileURLWithPath: (try next(option) as NSString).expandingTildeInPath, isDirectory: true)
            default:
                guard !option.hasPrefix("-"), !option.isEmpty, path == nil else { throw Failure("参数无效：\(option)。请查看 mac-hotkeys --help。") }
                path = (option as NSString).expandingTildeInPath
            }
        }
        guard !(preview && selfTest) else { throw Failure("--dry-run 与 --self-test 请分别使用。") }
    }
}

func exportMarkdown(arguments: ArraySlice<String>, active: Bool = false) throws {
    let options = try ExportOptions(arguments: arguments, active: active)
    let state = options.stateDir.appendingPathComponent("discoveries.json")
    var warnings = [String]()
    // Different snapshot directories must still share one keyboard session.
    let sessionDir = FileManager.default.temporaryDirectory.appendingPathComponent("mac-hotkeys-\(getuid())", isDirectory: true)
    let eventLock = options.active && !options.preview
        ? try HistoryLock(in: sessionDir, filename: "active.lock") : nil
    defer { withExtendedLifetime(eventLock) {} }
    var lock: HistoryLock?
    if !options.preview {
        do { lock = try HistoryLock(in: options.stateDir) }
        catch {
            if options.active { throw error }
            warnings.append("未能锁定本地发现记录，本次仅生成报告，历史记录未更新。")
        }
    }
    defer { withExtendedLifetime(lock) {} }
    if options.selfTest {
        let monitor = try ActiveEventMonitor.open()
        monitor.stop()
        print("拦截自检通过。起点、末端拦截及后验对照均通过，未发送候选组合。")
        return
    }
    if options.active, !options.preview {
        let destination = URL(fileURLWithPath: options.path ?? "mac-hotkeys.md")
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
            throw Failure("报告目录不可写，未开始主动扫描。")
        }
        if options.path != nil, !options.overwrite, fm.fileExists(atPath: destination.path) {
            throw Failure("目标报告已存在。请选择其他路径或加 --force，未开始主动扫描。")
        }
    }
    var history = lock == nil && !options.preview ? DiscoveryHistory() : try DiscoveryHistory.load(at: state)
    if let baseline = options.baseline { history = try history.loadingLegacyBaseline(from: baseline) }
    let inventory = Inventory()
    let scans = inventory.applicationScans()
    let bindings = inventory.bindings(including: scans)
    let discovered = bindings.filter { $0.status != .disabled && $0.status != .unverified }
    let rows = options.all ? bindings : discovered
    warnings += inventory.warnings
    var scan: ScanSummary?
    if options.active {
        let plan = ActiveScanPlan(bindings: bindings, remapped: karabinerScanExclusions(), history: history, limit: options.limit)
        if options.preview {
            print("本轮有 \(plan.eligible) 个清单外的允许组合，下批 \(plan.candidates.count) 个。仅预览，未发送按键。")
            for combo in plan.candidates { print(combo.label) }
            return
        }
        scan = runActiveScan(plan)
    }
    var probe: ProbeReport?
    if options.probe {
        do { probe = try probeReport(combos: KeyCombo.candidates, inventory: inventory, bindings: bindings, showAll: false) }
        catch { warnings.append(String(describing: error)) }
    }
    let newBindings = history.newBindings(discovered)
    let newFindings = history.newFindings(scan?.findings ?? [])
    let changes = discoveryMarkdown(newBindings: newBindings, newFindings: newFindings, previous: history.findings,
                                   scan: scan, first: history.isFirst)
    let report = renderMarkdown(bindings: rows, scans: scans, probe: probe, probeRequested: options.probe,
                                warnings: warnings, all: options.all, discoveries: changes)
    let output = try writeMarkdown(report, path: options.path, overwrite: options.overwrite)
    print("已导出 \(output.path)")
    print("\(rows.count) 条配置 · " + (history.isFirst ? "首次建档" : "新识别配置 \(newBindings.count) 条") +
          " · 新观察 \(newFindings.count) 条")
    if lock != nil {
        history.update(bindings: discovered, scan: scan)
        try history.save(at: state)
    }
    if let stopped = scan?.stopped { throw Failure(stopped) }
}
