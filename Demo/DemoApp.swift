import SwiftUI
import WorkPackets

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Launch arguments let CI open a specific screen:
/// `-tab plan|run|ledger` and `-mode monolith|packets`.
private enum LaunchOptions {
    static var tab: String { UserDefaults.standard.string(forKey: "tab") ?? "run" }
    static var mode: String { UserDefaults.standard.string(forKey: "mode") ?? "packets" }
}

struct RootView: View {
    @State private var tab = LaunchOptions.tab

    var body: some View {
        TabView(selection: $tab) {
            PlanView()
                .tabItem { Label("Plan", systemImage: "square.stack.3d.up") }
                .tag("plan")
            RunView(initialMode: LaunchOptions.mode)
                .tabItem { Label("Run", systemImage: "play.rectangle") }
                .tag("run")
            LedgerView()
                .tabItem { Label("Ledger", systemImage: "doc.text") }
                .tag("ledger")
        }
    }
}

// MARK: Plan

struct PlanView: View {
    private let graph = SampleCodebase.graph()
    private var packets: [WorkPacket] { (try? PacketPlanner(fileBudget: 60).plan(graph)) ?? [] }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Modules", value: "\(graph.names.count)")
                    LabeledContent("Files", value: "\(graph.totalFiles)")
                    LabeledContent("ObservableObject types", value: "\(graph.totalLegacyObservables)")
                    LabeledContent("Packets (≤ 60 files)", value: "\(packets.count)")
                } footer: {
                    Text("Constructed 40-module app. Packets follow dependency levels, then a file budget.")
                }
                Section("Packets") {
                    ForEach(packets) { packet in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(packet.id).font(.headline.monospaced())
                                Text("level \(packet.level)").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(packet.fileCount) files").font(.caption.monospacedDigit())
                            }
                            Text(packet.modules.joined(separator: ", "))
                                .font(.subheadline)
                            if !packet.dependsOn.isEmpty {
                                Text("after \(packet.dependsOn.joined(separator: " "))")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("Work packets")
        }
    }
}

// MARK: Run

struct RunView: View {
    @State private var mode: String
    private let monolith: RunReport?
    private let chain: RunReport?

    init(initialMode: String) {
        _mode = State(initialValue: initialMode == "monolith" ? "monolith" : "packets")
        let graph = SampleCodebase.graph()
        monolith = try? Simulator.runMonolith(graph)
        chain = try? Simulator.runPackets(graph)
    }

    private var report: RunReport? { mode == "monolith" ? monolith : chain }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Mode", selection: $mode) {
                        Text("One long session").tag("monolith")
                        Text("Packet chain").tag("packets")
                    }
                    .pickerStyle(.segmented)
                }
                if let report {
                    Section {
                        StatRow(title: "Sessions", value: "\(report.sessions)")
                        StatRow(title: "Compactions", value: "\(report.compactions)")
                        StatRow(title: "Tokens", value: "\(report.tokens / 1_000)k")
                        StatRow(title: "Shortcuts taken", value: "\(report.shortcutsTaken)")
                        StatRow(title: "Violations that escaped", value: "\(report.escapedViolations.count)",
                                alarm: !report.escapedViolations.isEmpty)
                        StatRow(title: "Files to redo", value: "\(report.reworkFiles)", alarm: report.reworkFiles > 100)
                        StatRow(title: "Caught at", value: report.detections.isEmpty ? "-" : summary(report.detections))
                    } footer: {
                        Text("Scripted agent: 200k window, 1.5k tokens per file. Not a measurement of any model.")
                    }
                    Section("Timeline") {
                        ForEach(report.events.filter { $0.kind != .work }) { event in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: icon(event.kind))
                                    .foregroundStyle(color(event.kind))
                                    .frame(width: 20)
                                Text(event.label).font(.footnote)
                            }
                        }
                    }
                }
            }
            .navigationTitle(mode == "monolith" ? "One long session" : "Packet chain")
        }
    }

    private func summary(_ detections: [String]) -> String {
        let unique = Array(Set(detections)).sorted()
        return unique.joined(separator: ", ") + (detections.count > 1 ? " ×\(detections.count)" : "")
    }

    private func icon(_ kind: RunEvent.Kind) -> String {
        switch kind {
        case .session: return "play.circle"
        case .work: return "hammer"
        case .compaction: return "arrow.down.right.and.arrow.up.left"
        case .shortcut: return "exclamationmark.triangle.fill"
        case .gatePass: return "checkmark.seal.fill"
        case .gateFail: return "xmark.octagon.fill"
        case .finalCheck: return "flag.checkered"
        }
    }

    private func color(_ kind: RunEvent.Kind) -> Color {
        switch kind {
        case .shortcut, .gateFail: return .red
        case .compaction: return .orange
        case .gatePass: return .green
        default: return .secondary
        }
    }
}

struct StatRow: View {
    let title: String
    let value: String
    var alarm = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(alarm ? Color.red : Color.primary)
        }
    }
}

// MARK: Ledger

struct LedgerView: View {
    private let ledger: HandoffLedger? = (try? Simulator.runPackets(SampleCodebase.graph()))?.ledger
    private let retryPrompt: String = {
        let graph = SampleCodebase.graph()
        guard let packets = try? PacketPlanner().plan(graph) else { return "" }
        var ledger = HandoffLedger(goal: SampleCodebase.goal, packets: packets)
        // Replay the first eight packets so P08's failed first attempt is on record.
        var current = graph
        while let next = ledger.nextPacket(), next.id != "P08" {
            try? ledger.start(next.id)
            let before = current
            for name in next.modules { current.migrate(name) }
            let report = RegressionGate().evaluate(before: before, after: current, scope: next.scope)
            _ = try? ledger.record(next.id, gate: report, evidence: [Evidence(kind: "swift test", reference: "log")])
        }
        guard let p08 = ledger.nextPacket() else { return "" }
        try? ledger.start(p08.id)
        var after = current
        for name in p08.modules { after.migrate(name) }
        after.addImport("FeatureCart", to: "FeatureCheckout")
        let report = RegressionGate().evaluate(before: current, after: after, scope: p08.scope)
        _ = try? ledger.record(p08.id, gate: report, evidence: [Evidence(kind: "swift test", reference: "log")])
        return PacketPrompt.render(p08, ledger: ledger)
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Prompt for P08, attempt 2").font(.headline)
                    Text(retryPrompt)
                        .font(.caption.monospaced())
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    Text("PROGRESS.md after the run").font(.headline)
                    Text(ledger?.markdown() ?? "")
                        .font(.caption2.monospaced())
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding()
            }
            .navigationTitle("Handoff ledger")
        }
    }
}
