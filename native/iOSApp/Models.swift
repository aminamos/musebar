import SwiftUI

struct UsageResponse: Decodable {
    var totalRequests: Int = 0
    var totalInputTokens: Int = 0
    var totalOutputTokens: Int = 0
    var totalCost: Double?
    var updatedAt: String?
    var byModel: [UsageModel] = []

    var tokens: Int { totalInputTokens + totalOutputTokens }

    enum CodingKeys: String, CodingKey {
        case totalRequests, totalInputTokens, totalOutputTokens, totalCost, updatedAt, byModel
        case overall, models
    }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let o = try? c.nestedContainer(keyedBy: CodingKeys.self, forKey: .overall) {
            totalRequests = (try? o.decode(Int.self, forKey: .totalRequests)) ?? 0
            totalInputTokens = (try? o.decode(Int.self, forKey: .totalInputTokens)) ?? 0
            totalOutputTokens = (try? o.decode(Int.self, forKey: .totalOutputTokens)) ?? 0
            totalCost = try? o.decode(Double.self, forKey: .totalCost)
        } else {
            totalRequests = (try? c.decode(Int.self, forKey: .totalRequests)) ?? 0
            totalInputTokens = (try? c.decode(Int.self, forKey: .totalInputTokens)) ?? 0
            totalOutputTokens = (try? c.decode(Int.self, forKey: .totalOutputTokens)) ?? 0
            totalCost = try? c.decode(Double.self, forKey: .totalCost)
        }
        updatedAt = try? c.decode(String.self, forKey: .updatedAt)
        byModel = (try? c.decode([UsageModel].self, forKey: .byModel))
            ?? (try? c.decode([UsageModel].self, forKey: .models)) ?? []
    }
}

struct UsageModel: Decodable, Identifiable {
    var id: String { model }
    var model = "unknown"
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

struct Departure: Decodable, Identifiable {
    var id: String { "\(route)-\(minutes)-\(destination)" }
    var route: String = ""
    var destination: String = ""
    var minutes: Int = 0
    var scheduledAt: String?

    enum CodingKeys: String, CodingKey {
        case route, destination, minutes, scheduledAt, mins, headsign, line
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        route = (try? c.decode(String.self, forKey: .route)) ?? (try? c.decode(String.self, forKey: .line)) ?? ""
        destination = (try? c.decode(String.self, forKey: .destination)) ?? (try? c.decode(String.self, forKey: .headsign)) ?? ""
        if let m = try? c.decode(Int.self, forKey: .minutes) { minutes = m }
        else if let m = try? c.decode(Int.self, forKey: .mins) { minutes = m }
        else if let s = try? c.decode(String.self, forKey: .minutes), let m = Int(s) { minutes = m }
        scheduledAt = try? c.decode(String.self, forKey: .scheduledAt)
    }
}

struct DeparturesResponse: Decodable {
    var departures: [Departure] = []
    init(from decoder: Decoder) throws {
        if let arr = try? [Departure](from: decoder) {
            departures = arr
        } else if let c = try? decoder.container(keyedBy: Key.self) {
            departures = (try? c.decode([Departure].self, forKey: .departures)) ?? []
        }
    }
    enum Key: String, CodingKey { case departures }
}

enum IOSFormat {
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
}

enum API {
    static let usageURL = URL(string: "https://YOUR-WORKER.workers.dev/api/usage")!
    static let busURL = URL(string: "https://YOUR-GHOSTBUS-WORKER.workers.dev/api/departures?stop=17941&route=E")!

    static func fetchUsage() async -> UsageResponse? {
        guard let (data, _) = try? await URLSession.shared.data(from: usageURL) else { return nil }
        return try? JSONDecoder().decode(UsageResponse.self, from: data)
    }
    static func fetchDepartures() async -> [Departure] {
        guard let (data, _) = try? await URLSession.shared.data(from: busURL) else { return [] }
        if let r = try? JSONDecoder().decode(DeparturesResponse.self, from: data) { return r.departures }
        return (try? JSONDecoder().decode([Departure].self, from: data)) ?? []
    }
}
