import SwiftUI

struct ContentView: View {
    @State private var usage: UsageResponse?
    @State private var departures: [Departure] = []
    @State private var weeks: [WeekUsage] = []
    @State private var weekIndex = 0

    private var displayedUsage: UsageResponse? {
        if weeks.indices.contains(weekIndex) {
            let w = weeks[weekIndex]
            var u = UsageResponse()
            u.totalRequests = w.totalRequests
            u.totalInputTokens = w.totalInputTokens
            u.totalOutputTokens = w.totalOutputTokens
            u.totalCost = w.totalCost
            u.byModel = w.byModel
            return u
        }
        return usage
    }

    private func weekLabel(_ w: WeekUsage) -> String {
        if weekIndex == 0 { return "This week" }
        guard let d = ISO8601DateFormatter().date(from: w.windowStart) else { return "Earlier week" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return "Week of \(f.string(from: d))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Muse Usage") {
                    if let u = displayedUsage {
                        if !weeks.isEmpty {
                            HStack {
                                Button { weekIndex += 1 } label: { Image(systemName: "chevron.left") }
                                    .disabled(weekIndex >= weeks.count - 1)
                                Spacer()
                                Text(weekLabel(weeks[weekIndex]))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button { weekIndex -= 1 } label: { Image(systemName: "chevron.right") }
                                    .disabled(weekIndex == 0)
                            }
                        }
                        HStack(spacing: 16) {
                            StatCell(label: "Requests", value: IOSFormat.grouped(u.totalRequests))
                            StatCell(label: "Tokens", value: IOSFormat.tokens(u.tokens))
                            StatCell(label: "Cost est.", value: IOSFormat.cost(u.totalCost))
                        }
                        ForEach(u.byModel.prefix(6)) { m in
                            HStack {
                                Text(m.shortName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .layoutPriority(0)
                                Spacer(minLength: 8)
                                Text("\(IOSFormat.grouped(m.totalRequests)) · \(IOSFormat.tokens(m.tokens))")
                                    .foregroundStyle(.secondary)
                                    .font(.callout.monospacedDigit())
                                    .lineLimit(1)
                                    .layoutPriority(1)
                            }
                        }
                    } else {
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                }
                Section("Bus E · Stop 17941") {
                    if departures.isEmpty {
                        Text("Loading…").foregroundStyle(.secondary)
                    } else {
                        ForEach(departures.prefix(6)) { d in
                            HStack {
                                Text(d.route).bold()
                                Text(d.destination).lineLimit(1).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(d.minutes) min")
                            }
                        }
                    }
                }
            }
            .navigationTitle("MuseBar")
            .task { await load() }
            .refreshable { await load() }
        }
    }

    func load() async {
        async let u = API.fetchUsage()
        async let b = API.fetchDepartures()
        async let w = API.fetchWeeks()
        usage = await u
        departures = await b
        weeks = await w
        if weekIndex >= weeks.count { weekIndex = max(0, weeks.count - 1) }
    }
}

struct StatCell: View {
    var label: String
    var value: String
    var body: some View {
        VStack(alignment: .leading) {
            Text(label.uppercased()).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
    }
}
