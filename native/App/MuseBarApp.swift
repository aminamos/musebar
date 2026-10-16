import SwiftUI
import WidgetKit

@main
struct MuseBarApp: App {
    private let refreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    @State private var stats: OmpStats?
    @State private var limits: LimitsFile?

    init() {
        _stats = State(initialValue: StatsStore.load())
        _limits = State(initialValue: StatsStore.loadLimits())
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(stats: stats, limits: limits, refresh: load)
        } label: {
            Text(labelText)
                .onReceive(refreshTimer) { _ in load() }
        }
        .menuBarExtraStyle(.window)
    }

    var labelText: String {
        var parts: [String] = []
        if let s = stats { parts.append("\(s.overall.totalRequests)") }
        if let l = limits?.limit("300m") { parts.append("5h \(l.remainingPct)%") }
        if let l = limits?.limit("1w") { parts.append("wk \(l.remainingPct)%") }
        guard !parts.isEmpty else { return "⚡ …" }
        return "⚡ " + parts.joined(separator: " · ")
    }

    func load() {
        stats = StatsStore.load()
        limits = StatsStore.loadLimits()
        WidgetCenter.shared.reloadTimelines(ofKind: "codes.amos.musebar.stats")
    }
}

struct MenuBarView: View {
    var stats: OmpStats?
    var limits: LimitsFile?
    var refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s = stats {
                Text("⚡ Muse Usage")
                    .font(.headline)
                HStack(spacing: 16) {
                    StatCell(label: "Requests", value: "\(s.overall.totalRequests)")
                    StatCell(label: "Tokens", value: Format.tokens(s.tokens))
                    StatCell(label: "Cost", value: Format.cost(s.overall.totalCost))
                }
                if let limits, !limits.limits.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(limits.limits, id: \.id) { l in
                            LimitRow(limit: l)
                        }
                    }
                    Divider()
                }
                ForEach(s.byModel.prefix(6), id: \.model) { m in
                    HStack {
                        Text(m.shortName)
                            .lineLimit(1)
                        Spacer()
                        Text("\(m.totalRequests) · \(Format.tokens(m.tokens)) · \(Format.cost(m.totalCost))")
                            .foregroundStyle(.secondary)
                            .font(.callout.monospacedDigit())
                    }
                }
                Text("Updated \(Format.time(StatsStore.modificationDate()))")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                Text("No stats yet — sync hasn't run.")
                    .foregroundStyle(.secondary)
            }
            Divider()
            Button("Refresh now") {
                refresh()
            }
            .keyboardShortcut("r")
            Button("Quit MuseBar") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(minWidth: 300)
        .onAppear { refresh() }
    }
}

struct StatCell: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading) {
            Text(label.uppercased())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold().monospacedDigit())
        }
    }
}

struct LimitRow: View {
    var limit: LimitsFile.Limit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(limit.label)
                    .font(.callout)
                Spacer()
                Text("\(limit.remainingPct)% left")
                    .font(.callout.monospacedDigit().bold())
                Text("· resets \(limit.resetsInText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(limit.usedFraction > 0.8 ? Color.red : (limit.usedFraction > 0.5 ? Color.orange : Color.accentColor))
                        .frame(width: geo.size.width * CGFloat(limit.usedFraction))
                }
            }
            .frame(height: 5)
        }
    }
}
