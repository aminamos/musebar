import WidgetKit
import SwiftUI

// Reuse Models.swift in this target for API + formatting.

struct MuseEntry: TimelineEntry {
    var date: Date
    var usage: UsageResponse?
}

struct MuseProvider: TimelineProvider {
    func placeholder(in context: Context) -> MuseEntry { MuseEntry(date: Date(), usage: nil) }
    func getSnapshot(in context: Context, completion: @escaping (MuseEntry) -> Void) {
        Task {
            let u = await API.fetchUsage()
            completion(MuseEntry(date: Date(), usage: u))
        }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<MuseEntry>) -> Void) {
        Task {
            let u = await API.fetchUsage()
            let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date(timeIntervalSinceNow: 900)
            completion(Timeline(entries: [MuseEntry(date: Date(), usage: u)], policy: .after(next)))
        }
    }
}

struct MuseWidgetView: View {
    var entry: MuseEntry
    var body: some View {
        if let u = entry.usage {
            VStack(alignment: .leading, spacing: 6) {
                Text("⚡ Muse").font(.headline)
                HStack(spacing: 14) {
                    MiniStat(label: "Requests", value: IOSFormat.grouped(u.totalRequests))
                    MiniStat(label: "Tokens", value: IOSFormat.tokens(u.tokens))
                    MiniStat(label: "Cost est.", value: IOSFormat.cost(u.totalCost))
                }
            }.padding(4)
        } else {
            VStack {
                Text("⚡ Muse").font(.headline)
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct MuseWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "codes.amos.musebar.ios.muse", provider: MuseProvider()) { entry in
            MuseWidgetView(entry: entry)
        }
        .configurationDisplayName("Muse Usage")
        .description("Your Muse requests, tokens and cost.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct BusEntry: TimelineEntry {
    var date: Date
    var departures: [Departure]
}

struct BusProvider: TimelineProvider {
    func placeholder(in context: Context) -> BusEntry { BusEntry(date: Date(), departures: []) }
    func getSnapshot(in context: Context, completion: @escaping (BusEntry) -> Void) {
        Task {
            completion(BusEntry(date: Date(), departures: await API.fetchDepartures()))
        }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<BusEntry>) -> Void) {
        Task {
            let deps = await API.fetchDepartures()
            let next = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date(timeIntervalSinceNow: 300)
            completion(Timeline(entries: [BusEntry(date: Date(), departures: deps)], policy: .after(next)))
        }
    }
}

struct BusWidgetView: View {
    var entry: BusEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("🚌 E · 17941").font(.headline)
            if entry.departures.isEmpty {
                Text("No departures").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(entry.departures.prefix(3)) { d in
                    HStack {
                        Text(d.destination).lineLimit(1).font(.caption)
                        Spacer()
                        Text("\(d.minutes)m").font(.caption.bold())
                    }
                }
            }
        }.padding(4)
    }
}

struct BusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "codes.amos.musebar.ios.bus", provider: BusProvider()) { entry in
            BusWidgetView(entry: entry)
        }
        .configurationDisplayName("Bus Departures")
        .description("Upcoming E departures at stop 17941.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct MiniStat: View {
    var label: String
    var value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased()).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
    }
}

@main
struct MuseBarWidgets: WidgetBundle {
    var body: some Widget {
        MuseWidget()
        BusWidget()
    }
}
