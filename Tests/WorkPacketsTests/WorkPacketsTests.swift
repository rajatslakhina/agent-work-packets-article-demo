import XCTest
@testable import WorkPackets

final class GraphTests: XCTestCase {
    func testSampleIsCleanAndAcyclic() throws {
        let graph = SampleCodebase.graph()
        XCTAssertEqual(graph.names.count, 40)
        XCTAssertEqual(graph.totalFiles, 622)
        XCTAssertTrue(RegressionGate().violations(in: graph).isEmpty)
        XCTAssertEqual(try graph.topologicalLevels().count, 7)
    }

    func testUnknownImportIsRejected() {
        let a = Module(name: "A", layer: .core, imports: ["Ghost"], fileCount: 1, legacyObservables: 1)
        XCTAssertThrowsError(try ModuleGraph([a])) { error in
            XCTAssertEqual(error as? GraphError, .unknownImport(module: "A", imports: "Ghost"))
        }
    }

    func testDuplicateModuleIsRejected() {
        let a = Module(name: "A", layer: .core, imports: [], fileCount: 1, legacyObservables: 1)
        XCTAssertThrowsError(try ModuleGraph([a, a]))
    }

    func testCycleIsReported() throws {
        let a = Module(name: "A", layer: .service, imports: ["B"], fileCount: 1, legacyObservables: 1)
        let b = Module(name: "B", layer: .service, imports: ["A"], fileCount: 1, legacyObservables: 1)
        let graph = try ModuleGraph([a, b])
        XCTAssertThrowsError(try graph.topologicalLevels()) { error in
            XCTAssertEqual(error as? GraphError, .cycle(["A", "B"]))
        }
        XCTAssertThrowsError(try PacketPlanner().plan(graph))
    }

    func testNegativeCountsClampToZero() {
        let m = Module(name: "A", layer: .core, imports: [], fileCount: -3, legacyObservables: -1)
        XCTAssertEqual(m.fileCount, 0)
        XCTAssertTrue(m.isMigrated)
    }
}

final class InvariantTests: XCTestCase {
    func testLayerRuleCatchesSidewaysAndUpwardImports() throws {
        var graph = SampleCodebase.graph()
        graph.addImport("FeatureCart", to: "FeatureCheckout")
        graph.addImport("FeatureHome", to: "CatalogService")
        let found = LayerRule().check(graph)
        XCTAssertEqual(found.count, 2)
        XCTAssertTrue(found.contains { $0.module == "FeatureCheckout" && $0.detail.contains("feature imports feature") })
        XCTAssertTrue(found.contains { $0.module == "CatalogService" && $0.detail.contains("service imports feature") })
    }

    func testBottomUpCatchesOutOfOrderMigration() {
        var graph = SampleCodebase.graph()
        graph.migrate("FeatureCart") // CartService, CatalogService and CoreAnalytics still legacy
        let found = BottomUpMigration().check(graph)
        XCTAssertEqual(found.count, 3)
        XCTAssertTrue(found.allSatisfy { $0.module == "FeatureCart" })
    }

    func testGateJudgesTheDeltaNotTheAbsoluteState() throws {
        var dirty = SampleCodebase.graph()
        dirty.addImport("FeatureCart", to: "FeatureHome") // pre-existing violation
        var after = dirty
        after.migrate("CoreModels")
        let report = RegressionGate().evaluate(before: dirty, after: after, scope: ["CoreModels"])
        XCTAssertTrue(report.passed, "an old violation must not block an unrelated packet")
    }

    func testGateFlagsScopeEscapeAndBackslide() throws {
        let before = SampleCodebase.graph()
        var after = before
        after.migrate("CoreModels")
        after.migrate("CoreStorage")
        let report = RegressionGate().evaluate(before: before, after: after, scope: ["CoreModels"])
        XCTAssertEqual(report.scopeEscapes, ["CoreStorage"])
        XCTAssertFalse(report.passed)

        let back = RegressionGate().evaluate(before: after, after: before, scope: ["CoreModels", "CoreStorage"])
        XCTAssertEqual(back.legacyIncreases, ["CoreModels", "CoreStorage"])
    }
}

final class PlannerTests: XCTestCase {
    func testPacketsRespectBudgetAndDependencyOrder() throws {
        let graph = SampleCodebase.graph()
        let packets = try PacketPlanner(fileBudget: 60).plan(graph)
        XCTAssertEqual(packets.count, 15)
        XCTAssertTrue(packets.allSatisfy { $0.fileCount <= 60 })
        let covered = packets.flatMap(\.modules)
        XCTAssertEqual(covered.count, 39, "CoreDesign has nothing to migrate")
        XCTAssertFalse(covered.contains("CoreDesign"))
        var seen: Set<String> = []
        for packet in packets {
            XCTAssertTrue(packet.dependsOn.allSatisfy(seen.contains), "\(packet.id) depends on a later packet")
            seen.insert(packet.id)
        }
        XCTAssertEqual(packets.last?.modules, ["AppShell", "AppWidgets"])
    }

    func testOversizeModuleGetsItsOwnFlaggedPacket() throws {
        let big = Module(name: "Monster", layer: .core, imports: [], fileCount: 90, legacyObservables: 5)
        let small = Module(name: "Small", layer: .core, imports: [], fileCount: 5, legacyObservables: 1)
        let packets = try PacketPlanner(fileBudget: 60).plan(try ModuleGraph([big, small]))
        XCTAssertEqual(packets.map(\.modules), [["Monster"], ["Small"]])
        XCTAssertEqual(packets.first?.oversize, true)
        XCTAssertEqual(packets.last?.oversize, false)
    }
}

final class LedgerTests: XCTestCase {
    private func ledger() throws -> HandoffLedger {
        HandoffLedger(goal: "g", packets: try PacketPlanner().plan(SampleCodebase.graph()))
    }

    func testCannotStartBeforeDependenciesVerify() throws {
        var l = try ledger()
        XCTAssertThrowsError(try l.start("P02")) { error in
            XCTAssertEqual(error as? LedgerError, .dependenciesNotVerified(packet: "P02", waitingOn: ["P01"]))
        }
        XCTAssertEqual(l.nextPacket()?.id, "P01")
    }

    func testDefaultFailWithoutEvidence() throws {
        var l = try ledger()
        try l.start("P01")
        let clean = GateReport(newViolations: [], scopeEscapes: [], legacyIncreases: [])
        XCTAssertEqual(try l.record("P01", gate: clean, evidence: []), .failed)
        XCTAssertEqual(l.nextPacket()?.id, "P01", "a failed packet is retried before anything after it")
        try l.start("P01")
        XCTAssertEqual(try l.record("P01", gate: clean, evidence: [Evidence(kind: "swift test", reference: "log")]), .verified)
        XCTAssertEqual(l.entry("P01")?.attempts, 2)
    }

    func testRecordRequiresInProgress() throws {
        var l = try ledger()
        let clean = GateReport(newViolations: [], scopeEscapes: [], legacyIncreases: [])
        XCTAssertThrowsError(try l.record("P01", gate: clean, evidence: []))
        XCTAssertThrowsError(try l.start("P99"))
    }

    func testLedgerSurvivesARoundTripAndRendersProgress() throws {
        var l = try ledger()
        try l.start("P01")
        let bad = GateReport(newViolations: [Violation(invariant: "layering", module: "X", detail: "d")],
                             scopeEscapes: [], legacyIncreases: [])
        try l.record("P01", gate: bad, evidence: [Evidence(kind: "swift test", reference: "log")])
        let restored = try HandoffLedger.decode(try l.jsonData())
        XCTAssertEqual(restored, l)
        let md = restored.markdown()
        XCTAssertTrue(md.contains("| P01 | 0 | CoreAnalytics, CoreModels | 26 | failed | 1 |"))
        XCTAssertTrue(md.contains("## Findings carried forward"))
        let prompt = PacketPrompt.render(try XCTUnwrap(restored.nextPacket()), ledger: restored)
        XCTAssertTrue(prompt.contains("A previous attempt at this packet failed the gate"))
        XCTAssertTrue(prompt.contains("Read PROGRESS.md before anything else"))
    }
}

final class SimulationTests: XCTestCase {
    func testMonolithCompactsDriftsAndFindsEverythingLate() throws {
        let r = try Simulator.runMonolith(SampleCodebase.graph())
        XCTAssertEqual(r.compactions, 5)
        XCTAssertEqual(r.tokens, 900_000)
        XCTAssertEqual(r.shortcutsTaken, 7)
        XCTAssertEqual(r.escapedViolations.count, 7)
        XCTAssertEqual(r.reworkFiles, 428)
        XCTAssertTrue(r.detections.allSatisfy { $0 == "end of run" })
    }

    func testPacketsCatchTheShortcutAtItsPacketAndCostMoreTokens() throws {
        let r = try Simulator.runPackets(SampleCodebase.graph())
        XCTAssertEqual(r.sessions, 16)
        XCTAssertEqual(r.compactions, 0)
        XCTAssertEqual(r.shortcutsTaken, 1)
        XCTAssertEqual(r.detections, ["P08"])
        XCTAssertEqual(r.reworkFiles, 52)
        XCTAssertTrue(r.escapedViolations.isEmpty)
        XCTAssertEqual(r.tokens, 1_074_000)
        XCTAssertEqual(r.ledger?.isComplete, true)
        XCTAssertEqual(r.finalGraph.totalLegacyObservables, 0)
    }

    func testBiggerWindowRemovesDriftButNotLateDetection() throws {
        let profile = AgentProfile(contextWindow: 1_000_000)
        let r = try Simulator.runMonolith(SampleCodebase.graph(), profile: profile)
        XCTAssertEqual(r.compactions, 0)
        XCTAssertEqual(r.escapedViolations.count, 1)
        XCTAssertEqual(r.reworkFiles, 348)
    }

    func testOversizePacketsDegradeBackToMonolithBehaviour() throws {
        let r = try Simulator.runPackets(SampleCodebase.graph(), planner: PacketPlanner(fileBudget: 400))
        XCTAssertGreaterThan(r.compactions, 0)
        XCTAssertGreaterThan(r.shortcutsTaken, 1)
        XCTAssertTrue(r.escapedViolations.isEmpty, "the gate still holds, it just costs more retries")
    }
}
