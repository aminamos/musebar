import SwiftUI
import WidgetKit

@main
struct MuseBarApp: App {
    private let refreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    @State private var stats: OmpStats?
    @State private var limits: LimitsFile?
    @AppStorage("showRequests") private var showRequests = true
    @AppStorage("showCost") private var showCost = true
    @AppStorage("show5h") private var show5h = true
    @AppStorage("showWeekly") private var showWeekly = true

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
        if let s = stats {
            if showRequests { parts.append(Format.grouped(s.overall.totalRequests)) }
            if showCost { parts.append(Format.cost(s.overall.totalCost)) }
        }
        if show5h, let l = limits?.limit("300m") { parts.append("5h \(l.remainingPct)%") }
        if showWeekly, let l = limits?.limit("1w") { parts.append("wk \(l.remainingPct)%") }
        guard !parts.isEmpty else { return "⚡" }
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
    @AppStorage("showRequests") private var showRequests = true
    @AppStorage("showTokens") private var showTokens = true
    @AppStorage("showCost") private var showCost = true
    @AppStorage("show5h") private var show5h = true
    @AppStorage("showWeekly") private var showWeekly = true
    @AppStorage("showPerModel") private var showPerModel = true
    @State private var showSettings = false

    private func limitVisible(_ l: LimitsFile.Limit) -> Bool {
        switch l.id {
        case "300m": return show5h
        case "1w": return showWeekly
        default: return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s = stats {
                Text("⚡ Muse Usage")
                    .font(.headline)
                if showRequests || showTokens || showCost {
                    HStack(spacing: 16) {
                        if showRequests { StatCell(label: "Requests", value: Format.grouped(s.overall.totalRequests)) }
                        if showTokens { StatCell(label: "Tokens", value: Format.tokens(s.tokens)) }
                        if showCost { StatCell(label: "Cost est.", value: Format.cost(s.overall.totalCost)) }
                    }
                }
                if let limits {
                    let visible = limits.limits.filter(limitVisible)
                    if !visible.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(visible, id: \.id) { l in
                                LimitRow(limit: l)
                            }
                        }
                        Divider()
                    }
                }
                if showPerModel {
                    ForEach(s.byModel.prefix(6), id: \.model) { m in
                        HStack {
                            Text(m.shortName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .layoutPriority(0)
                            Spacer(minLength: 8)
                            Text("\(Format.grouped(m.totalRequests)) · \(Format.tokens(m.tokens)) · \(Format.cost(m.totalCost))")
                                .foregroundStyle(.secondary)
                                .font(.callout.monospacedDigit())
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
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
            Button(showSettings ? "Hide settings" : "Settings…") {
                showSettings.toggle()
            }
            if showSettings {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SHOW")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Toggle("Requests", isOn: $showRequests)
                    Toggle("Tokens", isOn: $showTokens)
                    Toggle("Cost est.", isOn: $showCost)
                    Toggle("5 Hours quota", isOn: $show5h)
                    Toggle("Weekly quota", isOn: $showWeekly)
                    Toggle("Per-model breakdown", isOn: $showPerModel)
                    Text("Requests, Cost, 5h, and Weekly also apply to the menu bar label.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                .font(.callout)
            }
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
        .frame(minWidth: 400)
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
