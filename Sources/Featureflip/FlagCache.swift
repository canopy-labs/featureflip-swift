import Foundation

/// Actor-isolated in-memory flag cache with file persistence.
actor FlagCache {
    private var flags: [String: FlagValue] = [:]
    private let fileURL: URL

    init(clientKey: String, cacheDirectory: URL? = nil) {
        let dir = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("featureflip")
        let safeKey = clientKey.replacingOccurrences(of: "/", with: "_")
        self.fileURL = dir.appendingPathComponent("\(safeKey)_flags.json")
    }

    func setAll(_ newFlags: [String: FlagValue]) {
        flags = newFlags
        persistToDisk()
    }

    func merge(_ delta: [String: FlagValue]) {
        for (key, value) in delta {
            if value.reason == "FLAG_REMOVED" && value.value == .null {
                flags.removeValue(forKey: key)
            } else {
                flags[key] = value
            }
        }
        persistToDisk()
    }

    func get(_ key: String) -> FlagValue? {
        flags[key]
    }

    func all() -> [String: FlagValue] {
        flags
    }

    func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            flags = try JSONDecoder().decode([String: FlagValue].self, from: data)
        } catch {
            // Corrupt cache — ignore and start fresh
        }
    }

    private func persistToDisk() {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(flags)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort persistence
        }
    }
}
