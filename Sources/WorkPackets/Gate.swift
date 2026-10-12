import Foundation

/// What the regression gate found between two snapshots.
public struct GateReport: Codable, Sendable, Equatable {
    /// Violations present after the packet that were not present before it.
    public let newViolations: [Violation]
    /// Modules the packet changed even though they were outside its scope.
    public let scopeEscapes: [String]
    /// Modules whose legacy `ObservableObject` count went up.
    public let legacyIncreases: [String]

    public var passed: Bool { newViolations.isEmpty && scopeEscapes.isEmpty && legacyIncreases.isEmpty }

    public var findings: [String] {
        newViolations.map(\.description)
            + scopeEscapes.map { "[scope] \($0) changed outside the packet" }
            + legacyIncreases.map { "[backslide] \($0) gained ObservableObject types" }
    }
}

/// Runs between packets. It judges the delta, not the absolute state, so a codebase that
/// starts with old violations can still make progress without the gate going red forever.
public struct RegressionGate: Sendable {
    public let invariants: [any StructuralInvariant]

    public init(invariants: [any StructuralInvariant] = Invariants.standard) {
        self.invariants = invariants
    }

    public func violations(in graph: ModuleGraph) -> [Violation] {
        invariants.flatMap { $0.check(graph) }
    }

    public func evaluate(before: ModuleGraph, after: ModuleGraph, scope: Set<String>) -> GateReport {
        let old = Set(violations(in: before))
        let fresh = violations(in: after).filter { !old.contains($0) }
        let changed = after.changedModules(comparedTo: before)
        let escapes = changed.subtracting(scope).sorted()
        let increases = changed.filter { name in
            guard let b = before.module(name), let a = after.module(name) else { return false }
            return a.legacyObservables > b.legacyObservables
        }.sorted()
        return GateReport(newViolations: fresh, scopeEscapes: escapes, legacyIncreases: increases)
    }
}
