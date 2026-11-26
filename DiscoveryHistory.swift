import Darwin
import Foundation

private struct BindingIdentity: Codable, Hashable {
    let shortcut: String
    let owner: String
    let action: String

    init(_ binding: Binding) {
        shortcut = binding.shortcut
        owner = binding.owner
        action = binding.action
    }

    init(shortcut: String, owner: String, action: String) {
        self.shortcut = shortcut
        self.owner = owner
        self.action = action
    }
}

struct FindingIdentity: Hashable {
    let shortcut: String
    let kind: String
    let target: String?

    init(_ finding: ScanFinding) {
        shortcut = finding.shortcut
        kind = finding.kind
        target = finding.bundleID ?? finding.owner
    }
}

struct DiscoveryHistory: Codable {
    private let version: Int
    private var bindings: Set<BindingIdentity>
    private(set) var isFirst: Bool
    var tried: Set<String>
    private(set) var findings: [ScanFinding]
    var knownShortcuts: Set<String> { Set(bindings.map(\.shortcut)) }

    init() {
        version = 1
        bindings = []
        isFirst = true
        tried = []
        findings = []
    }

    static func load(at url: URL) throws -> Self {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Self()
        }
        let history = try JSONDecoder().decode(Self.self, from: data)
        guard history.version == 1 else { throw Failure("无法读取此版本的扫描历史（版本 \(history.version)）。") }
        return history
    }

    func loadingLegacyBaseline(from url: URL) throws -> Self {
        struct ListReport: Decodable { let bindings: [BindingIdentity] }
        let data = try Data(contentsOf: url)
        var copy = self
        if url.pathExtension.lowercased() == "md" {
            let body = String(decoding: data, as: UTF8.self)
            guard body.hasPrefix("# Mac 全局快捷键清单\n"), body.contains("\n## 系统快捷键\n"),
                  body.contains("\n## 应用快捷键\n") else { throw Failure("无法识别基线报告。请使用 mac-hotkeys 导出的 Markdown 或 list --json。") }
            var rows = Set<BindingIdentity>()
            var inBindings = false
            for line in body.components(separatedBy: .newlines) {
                if line.hasPrefix("## ") {
                    inBindings = line == "## 应用快捷键" || line == "## 系统快捷键"
                    continue
                }
                guard inBindings, line.hasPrefix("| "), !line.hasPrefix("| 快捷键 |"), !line.hasPrefix("| --- |") else { continue }
                let cells = line.components(separatedBy: "|")
                guard cells.count == 7 else { throw Failure("基线中有无法解析的快捷键行。") }
                rows.insert(BindingIdentity(shortcut: Self.decodeCell(cells[1]), owner: Self.decodeCell(cells[2]),
                                            action: Self.decodeCell(cells[3])))
            }
            copy.bindings = rows
        } else {
            copy.bindings = Set(try JSONDecoder().decode(ListReport.self, from: data).bindings)
        }
        copy.isFirst = false
        return copy
    }

    private static func decodeCell(_ raw: String) -> String {
        var value = ""
        var escaped = false
        for c in raw.trimmingCharacters(in: .whitespaces) {
            if c == "\\" && !escaped { escaped = true; continue }
            value.append(c)
            escaped = false
        }
        if escaped { value.append("\\") }
        return value.replacingOccurrences(of: "&#124;", with: "|").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }

    func newBindings(_ rows: [Binding]) -> [Binding] {
        guard !isFirst else { return [] }
        var seen = bindings
        return rows.filter { seen.insert(BindingIdentity($0)).inserted }
    }

    func newFindings(_ found: [ScanFinding]) -> [ScanFinding] {
        var seen = Set(findings.map(FindingIdentity.init))
        return found.filter { seen.insert(FindingIdentity($0)).inserted }
    }

    mutating func update(bindings rows: [Binding], scan: ScanSummary?) {
        bindings = Set(rows.map(BindingIdentity.init))
        isFirst = false
        guard let scan else { return }
        if scan.beginsNewCycle { tried.removeAll() }
        tried.formUnion(scan.attempted)
        // Preserve observation order and refresh the evidence when a process restarts.
        var indices = [FindingIdentity: Int]()
        for (index, finding) in findings.enumerated() { indices[FindingIdentity(finding)] = index }
        for finding in scan.findings {
            let identity = FindingIdentity(finding)
            if let index = indices[identity] {
                findings[index] = finding
            } else {
                indices[identity] = findings.count
                findings.append(finding)
            }
        }
    }

    func save(at url: URL) throws {
        let data = try JSONEncoder().encode(self)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = parent.appendingPathComponent(".history-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try file.write(contentsOf: data)
        try file.synchronize()
        try file.close()
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
