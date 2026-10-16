import WidgetKit
import SwiftUI

struct StatsEntry: TimelineEntry {
    var date: Date
    var stats: OmpStats?
    var limits: LimitsFile?
    var updated: Date?
}

struct StatsProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatsEntry {
        StatsEntry(date: Date(), stats: nil, limits: nil, updated: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatsEntry) -> Void) {
        completion(StatsEntry(date: Date(), stats: StatsStore.load(), limits: StatsStore.loadLimits(), updated: StatsStore.modificationDate()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatsEntry>) -> Void) {
        let entry = StatsEntry(date: Date(), stats: StatsStore.load(), limits: StatsStore.loadLimits(), updated: StatsStore.modificationDate())
        // The sync script pushes fresh data every 15 min; match that cadence.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date(timeIntervalSinceNow: 900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct MuseStatsWidgetView: View {
    var entry: StatsEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        if let s = entry.stats {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("⚡ Muse")
                        .font(.headline)
                    Spacer()
                    Text(Format.time(entry.updated))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    MiniStat(label: "Requests", value: "\(s.overall.totalRequests)")
                    MiniStat(label: "Tokens", value: Format.tokens(s.tokens))
                    MiniStat(label: "Cost", value: Format.cost(s.overall.totalCost))
                }
                if let limits = entry.limits, !limits.limits.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(limits.limits, id: \.id) { l in
                            HStack(spacing: 6) {
                                Text(l.label)
                                    .font(.caption2)
                                    .frame(width: 46, alignment: .leading)
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(l.usedFraction > 0.8 ? Color.red : Color.accentColor.opacity(0.85))
                                        .frame(width: max(3, geo.size.width * CGFloat(l.usedFraction)), height: 4)
                                }
                                .frame(height: 4)
                                Text("\(l.remainingPct)% left")
                                    .font(.caption2.monospacedDigit().bold())
                                Text("· \(l.resetsInText)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if family != .systemSmall {
                    let maxReq = max(1, s.byModel.map(\.totalRequests).max() ?? 1)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(s.byModel.prefix(4), id: \.model) { m in
                            HStack(spacing: 6) {
                                Text(m.shortName)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .frame(maxWidth: 110, alignment: .leading)
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.accentColor.opacity(0.85))
                                        .frame(width: max(3, geo.size.width * CGFloat(m.totalRequests) / CGFloat(maxReq)), height: 4)
                                }
                                .frame(height: 4)
                                Text("\(m.totalRequests)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(4)
        } else {
            VStack {
                Text("⚡ Muse")
                    .font(.headline)
                Text("Waiting for sync…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct MiniStat: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
        }
    }
}

struct MuseStatsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "codes.amos.musebar.stats", provider: StatsProvider()) { entry in
            MuseStatsWidgetView(entry: entry)
        }
        .configurationDisplayName("Muse Usage")
        .description("Your Muse requests, tokens and cost.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct MuseWidgets: WidgetBundle {
    var body: some Widget {
        MuseStatsWidget()
    }
}
