import Foundation

struct InstalledApp: Encodable {
    let name: String
    let bundleID: String
    let path: String

    static func discover() -> [Self] {
        let fm = FileManager.default
        var folders = fm.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        var apps: [Self] = []
        while let folder = folders.popLast() {
            guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else { continue }
            for url in entries where !url.lastPathComponent.hasPrefix(".") {
                if url.pathExtension.lowercased() == "app" {
                    guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
                    apps.append(Self(name: url.deletingPathExtension().lastPathComponent, bundleID: id, path: url.path))
                } else if let info = try? url.resourceValues(forKeys: keys), info.isDirectory == true,
                          info.isSymbolicLink != true, info.isPackage != true {
                    folders.append(url)
                }
            }
        }
        return apps.sorted { ($0.name.lowercased(), $0.path) < ($1.name.lowercased(), $1.path) }
    }
}
