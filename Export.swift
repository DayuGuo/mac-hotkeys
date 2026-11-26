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

func exportMarkdown(arguments: ArraySlice<String>) throws {
    var path: String?
    var all = false
    var scan = true
    var overwrite = false
    for argument in arguments {
        switch argument {
        case "--all": all = true
        case "--no-probe": scan = false
        case "--force": overwrite = true
        default:
            guard !argument.hasPrefix("-"), !argument.isEmpty, path == nil else {
                throw Failure("用法  mac-hotkeys export [文件] [--all] [--no-probe] [--force]")
            }
            path = (argument as NSString).expandingTildeInPath
        }
    }

    let inventory = Inventory()
    let scans = inventory.applicationScans()
    let bindings = inventory.bindings(including: scans)
    let rows = bindings.filter { all || $0.isCurrent || $0.status == .saved }
    var warnings = inventory.warnings
    var probe: ProbeReport?
    if scan {
        do {
            probe = try probeReport(combos: KeyCombo.candidates, inventory: inventory, bindings: bindings, showAll: false)
        } catch {
            warnings.append(String(describing: error))
        }
    }
    let report = renderMarkdown(bindings: rows, scans: scans, probe: probe, probeRequested: scan,
                                warnings: warnings, all: all)
    let output = try writeMarkdown(report, path: path, overwrite: overwrite)
    print("已导出 \(output.path)")
    if let probe {
        print("\(rows.count) 条配置 · 探测 \(probe.scanned) 个组合 · \(probe.conflicts) 个注册冲突 · \(probe.errors) 个探测错误")
    } else {
        print("\(rows.count) 条配置 · " + (scan ? "未取得注册探测结果，原因见报告" : "已按 --no-probe 跳过注册探测"))
    }
}
