import Foundation

enum ConfigLoader {
    static var configURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".ego-mac/config.json")
    }

    static func load() -> EGOConfig {
        let url = configURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(EGOConfig.self, from: data)
        else {
            return .default
        }
        // Upgrade legacy schemas on disk silently — the decoder accepts v1/v2/v3,
        // but we always want the persisted file in v3 so the user sees the
        // current shape if they ever inspect it.
        let onDisk = String(data: data, encoding: .utf8) ?? ""
        if !onDisk.contains("\"stops\"") {
            save(cfg)
        }
        return cfg
    }

    static func writeDefaultIfMissing() {
        let url = configURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        save(.default)
    }

    static func save(_ config: EGOConfig) {
        let url = configURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) {
            try? data.write(to: url)
        }
    }
}
