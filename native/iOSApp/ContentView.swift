import SwiftUI

struct ContentView: View {
    @State private var usage: UsageResponse?
    @State private var departures: [Departure] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Muse Usage") {
                    if let u = usage {
                        HStack(spacing: 16) {
                            StatCell(label: "Requests", value: IOSFormat.grouped(u.totalRequests))
                            StatCell(label: "Tokens", value: IOSFormat.tokens(u.tokens))
                            StatCell(label: "Cost est.", value: IOSFormat.cost(u.totalCost))
                        }
                        ForEach(u.byModel.prefix(6)) { m in
                            HStack {
                                Text(m.shortName).lineLimit(1)
                                Spacer()
                                Text("\(IOSFormat.grouped(m.totalRequests)) · \(IOSFormat.tokens(m.tokens))")
                                    .foregroundStyle(.secondary).font(.callout)
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
        usage = await u
        departures = await b
    }
}

struct StatCell: View {
    var label: String
    var value: String
    var body: some View {
        VStack(alignment: .leading) {
            Text(label.uppercased()).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.title3.bold())
        }
    }
}
