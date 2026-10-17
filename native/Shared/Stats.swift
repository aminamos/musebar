import Foundation

// Mirrors the `omp stats --json` shape written by sync-muse.sh.
struct OmpStats: Decodable {
    var overall: Overall = Overall()
    var byModel: [ModelStats] = []

    struct Overall: Decodable {
        var totalRequests = 0
        var successfulRequests = 0
        var failedRequests = 0
        var totalInputTokens = 0
        var totalOutputTokens = 0
        var totalCacheReadTokens = 0
        var cacheRate: Double?
        var totalCost: Double?
        var totalPremiumRequests = 0
    }

    struct ModelStats: Decodable {
        var model = "unknown"
        var provider = ""
        var totalRequests = 0
        var totalInputTokens = 0
        var totalOutputTokens = 0
        var totalCost: Double?

        var tokens: Int { totalInputTokens + totalOutputTokens }
        var shortName: String {
            model.replacingOccurrences(of: "-latest", with: "")
                .replacingOccurrences(of: "deepseek-", with: "dsk-")
        }
    }

    var tokens: Int { overall.totalInputTokens + overall.totalOutputTokens }
}

// Quota windows from `omp usage`, written by the sync script.
struct LimitsFile: Decodable {
    var fetchedAt: String?
    var limits: [Limit] = []

    struct Limit: Decodable {
        var id: String          // "300m" | "1w"
        var label: String       // "5 Hours" | "Weekly"
        var usedFraction: Double
        var remainingFraction: Double
        var resetsAt: Double?   // epoch ms
        var durationMs: Double?

        var shortLabel: String { id == "300m" ? "5h" : (id == "1w" ? "wk" : label) }
        var remainingPct: Int { Int((remainingFraction * 100).rounded()) }

        var resetsInText: String {
            guard let resetsAt else { return "" }
            let ms = resetsAt - Date().timeIntervalSince1970 * 1000
            guard ms > 0 else { return "now" }
            let s = Int(ms / 1000)
            if s >= 86400 { return "\(s / 86400)d\((s % 86400) / 3600)h" }
            if s >= 3600 { return "\(s / 3600)h\((s % 3600) / 60)m" }
            return "\(s / 60)m"
        }
    }

    func limit(_ id: String) -> Limit? { limits.first { $0.id == id } }
}

enum StatsStore {
    static var snapshotURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".musebar/latest.json")
    }

    static var limitsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".musebar/limits.json")
    }

    static func loadLimits() -> LimitsFile? {
        guard let data = try? Data(contentsOf: limitsURL) else { return nil }
        return try? JSONDecoder().decode(LimitsFile.self, from: data)
    }

    static func load() -> OmpStats? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        // The sync script already strips omp's "Syncing…/Synced…" stdout
        // lines, but tolerate them here too via the fallback below.
        do {
            return try JSONDecoder().decode(OmpStats.self, from: data)
        } catch {
            // Fall back: try decoding after dropping non-JSON leading lines.
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            guard let start = text.firstIndex(of: "{"),
                  let json = text[start...].data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(OmpStats.self, from: json)
        }
    }

    static func modificationDate() -> Date? {
        try? FileManager.default.attributesOfItem(atPath: snapshotURL.path)[.modificationDate] as? Date
    }
}

enum Format {
    static func grouped(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }

    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.2fB", Double(n) / 1_000_000_000) }
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    static func cost(_ n: Double?) -> String {
        guard let n else { return "–" }
        return n.formatted(.currency(code: "USD"))
    }

    static func time(_ d: Date?) -> String {
        guard let d else { return "never" }
        let f = DateFormatter()
        f.dateFormat = "MMM d 'at' h:mm a"
        return f.string(from: d)
    }
}
