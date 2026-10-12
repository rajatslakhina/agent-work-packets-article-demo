import Foundation

/// A scripted stand-in for a coding agent. It is not a model of any real LLM's accuracy.
/// It encodes two behaviours the sources describe: long sessions get compacted and lose
/// detail, and agents take structural shortcuts. Every number it produces follows from
/// these parameters, so change them and the comparison changes with them.
public struct AgentProfile: Sendable, Equatable {
    public var contextWindow: Int
    public var tokensPerFile: Int
    /// Context left after a compaction (the summary of everything before it).
    public var summaryTokens: Int
    /// Cost of reading PROGRESS.md and the packet prompt at the start of a fresh session.
    public var ledgerTokens: Int
    /// After a compaction, every Nth feature module gets a sideways feature→feature import.
    public var driftEvery: Int
    /// One shortcut the agent takes regardless of context: (module, import it adds).
    public var scriptedMistake: (module: String, adds: String)?

    public init(contextWindow: Int = 200_000, tokensPerFile: Int = 1_500, summaryTokens: Int = 20_000,
                ledgerTokens: Int = 6_000, driftEvery: Int = 3,
                scriptedMistake: (module: String, adds: String)? = ("FeatureCheckout", "FeatureCart")) {
        self.contextWindow = max(1, contextWindow)
        self.tokensPerFile = max(0, tokensPerFile)
        self.summaryTokens = max(0, summaryTokens)
        self.ledgerTokens = max(0, ledgerTokens)
        self.driftEvery = max(1, driftEvery)
        self.scriptedMistake = scriptedMistake
    }

    public static func == (lhs: AgentProfile, rhs: AgentProfile) -> Bool {
        lhs.contextWindow == rhs.contextWindow && lhs.tokensPerFile == rhs.tokensPerFile
            && lhs.summaryTokens == rhs.summaryTokens && lhs.ledgerTokens == rhs.ledgerTokens
            && lhs.driftEvery == rhs.driftEvery
            && lhs.scriptedMistake?.module == rhs.scriptedMistake?.module
            && lhs.scriptedMistake?.adds == rhs.scriptedMistake?.adds
    }
}

public struct RunEvent: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case session, work, compaction, shortcut, gatePass, gateFail, finalCheck }
    public let id: Int
    public let kind: Kind
    public let label: String
}

public struct RunReport: Sendable {
    public enum Mode: String, Sendable { case monolith, packets }
    public let mode: Mode
    public let sessions: Int
    public let compactions: Int
    public let tokens: Int
    /// Bad edits the agent made during the run, caught or not.
    public let shortcutsTaken: Int
    /// Violations still present in the final graph.
    public let escapedViolations: [Violation]
    /// Files of work that had to be redone (packets) or sit on top of the first bad edit (monolith).
    public let reworkFiles: Int
    /// Where each problem was first detected: a packet id, or "end of run".
    public let detections: [String]
    public let finalGraph: ModuleGraph
    public let ledger: HandoffLedger?
    public let events: [RunEvent]
}

public enum Simulator {

    private struct Session {
        var context: Int
        var drifting = false
        var featuresSinceCompaction = 0
    }

    /// Applies the agent to one module. Returns true if it took a shortcut.
    private static func work(on name: String, graph: inout ModuleGraph, session: inout Session,
                             profile: AgentProfile, allowScriptedMistake: Bool,
                             lastFeature: String?, compactions: inout Int, tokens: inout Int,
                             log: (RunEvent.Kind, String) -> Void) -> Bool {
        guard let module = graph.module(name) else { return false }
        let cost = module.fileCount * profile.tokensPerFile
        if session.context + cost > profile.contextWindow {
            compactions += 1
            session.context = profile.summaryTokens
            session.drifting = true
            session.featuresSinceCompaction = 0
            log(.compaction, "compaction #\(compactions): context summarised to \(profile.summaryTokens / 1_000)k tokens")
        }
        session.context += cost
        tokens += cost
        graph.migrate(name)
        log(.work, "\(name): \(module.fileCount) files migrated")

        var shortcut = false
        if allowScriptedMistake, let mistake = profile.scriptedMistake, mistake.module == name {
            graph.addImport(mistake.adds, to: name)
            log(.shortcut, "\(name) imports \(mistake.adds) to reuse a view")
            shortcut = true
        }
        if session.drifting && module.layer == .feature {
            session.featuresSinceCompaction += 1
            if session.featuresSinceCompaction % profile.driftEvery == 0, let other = lastFeature, other != name,
               graph.module(name)?.imports.contains(other) == false {
                graph.addImport(other, to: name)
                log(.shortcut, "\(name) imports \(other) after compaction lost the layering rule")
                shortcut = true
            }
        }
        return shortcut
    }

    /// One long session over the whole migration, checked once at the end.
    public static func runMonolith(_ baseline: ModuleGraph, profile: AgentProfile = AgentProfile(),
                                   gate: RegressionGate = RegressionGate()) throws -> RunReport {
        let order = try baseline.topologicalLevels().flatMap { $0 }.filter { baseline.module($0)?.isMigrated == false }
        var graph = baseline
        var session = Session(context: 0)
        var compactions = 0, tokens = 0, shortcuts = 0
        var events: [RunEvent] = []
        func log(_ kind: RunEvent.Kind, _ label: String) { events.append(RunEvent(id: events.count, kind: kind, label: label)) }

        log(.session, "session 1: whole migration (\(order.count) modules)")
        var lastFeature: String?
        var firstBadIndex: Int?
        for (index, name) in order.enumerated() {
            let bad = work(on: name, graph: &graph, session: &session, profile: profile, allowScriptedMistake: true,
                           lastFeature: lastFeature, compactions: &compactions, tokens: &tokens, log: log)
            if bad { shortcuts += 1; if firstBadIndex == nil { firstBadIndex = index } }
            if graph.module(name)?.layer == .feature { lastFeature = name }
        }
        let report = gate.evaluate(before: baseline, after: graph, scope: Set(baseline.names))
        log(.finalCheck, report.passed ? "final check: clean" : "final check: \(report.newViolations.count) violations")

        var rework = 0
        if let first = firstBadIndex {
            rework = order[first...].compactMap { baseline.module($0)?.fileCount }.reduce(0, +)
        }
        return RunReport(mode: .monolith, sessions: 1, compactions: compactions, tokens: tokens,
                         shortcutsTaken: shortcuts, escapedViolations: report.newViolations, reworkFiles: rework,
                         detections: report.passed ? [] : Array(repeating: "end of run", count: report.newViolations.count),
                         finalGraph: graph, ledger: nil, events: events)
    }

    /// One fresh session per packet, gated between packets, resumed from the ledger.
    public static func runPackets(_ baseline: ModuleGraph, planner: PacketPlanner = PacketPlanner(),
                                  profile: AgentProfile = AgentProfile(), gate: RegressionGate = RegressionGate(),
                                  maxAttempts: Int = 3) throws -> RunReport {
        let packets = try planner.plan(baseline)
        var ledger = HandoffLedger(goal: SampleCodebase.goal, packets: packets, invariants: gate.invariants)
        var graph = baseline
        var sessions = 0, compactions = 0, tokens = 0, shortcuts = 0, rework = 0
        var detections: [String] = []
        var events: [RunEvent] = []
        var lastFeature: String?
        func log(_ kind: RunEvent.Kind, _ label: String) { events.append(RunEvent(id: events.count, kind: kind, label: label)) }

        while let packet = ledger.nextPacket() {
            let attempt = (ledger.entry(packet.id)?.attempts ?? 0) + 1
            guard attempt <= max(1, maxAttempts) else { break }
            try ledger.start(packet.id)
            sessions += 1
            tokens += profile.ledgerTokens
            log(.session, "session \(sessions): \(packet.id) attempt \(attempt), \(packet.modules.count) modules, \(packet.fileCount) files")

            let before = graph
            var session = Session(context: profile.ledgerTokens)
            var packetLastFeature = lastFeature
            for name in packet.modules {
                let bad = work(on: name, graph: &graph, session: &session, profile: profile,
                               allowScriptedMistake: attempt == 1, lastFeature: packetLastFeature,
                               compactions: &compactions, tokens: &tokens, log: log)
                if bad { shortcuts += 1 }
                if graph.module(name)?.layer == .feature { packetLastFeature = name }
            }
            let report = gate.evaluate(before: before, after: graph, scope: packet.scope)
            let evidence = [Evidence(kind: "swift test", reference: "logs/\(packet.id)-attempt\(attempt).txt")]
            let status = try ledger.record(packet.id, gate: report, evidence: evidence)
            if status == .verified {
                lastFeature = packetLastFeature
                log(.gatePass, "\(packet.id) gate: pass")
            } else {
                // Roll the packet back (git reset to the last verified commit) and retry fresh.
                graph = before
                rework += packet.fileCount
                detections.append(contentsOf: Array(repeating: packet.id, count: max(1, report.newViolations.count)))
                log(.gateFail, "\(packet.id) gate: \(report.findings.first ?? "failed"); rolled back \(packet.fileCount) files")
            }
        }
        let leftover = gate.evaluate(before: baseline, after: graph, scope: Set(baseline.names)).newViolations
        log(.finalCheck, leftover.isEmpty ? "final check: clean" : "final check: \(leftover.count) violations")
        return RunReport(mode: .packets, sessions: sessions, compactions: compactions, tokens: tokens,
                         shortcutsTaken: shortcuts, escapedViolations: leftover, reworkFiles: rework,
                         detections: detections, finalGraph: graph, ledger: ledger, events: events)
    }
}
