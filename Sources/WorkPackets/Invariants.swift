import Foundation

/// A broken structural rule, found by a check rather than by a reviewer reading prose.
public struct Violation: Codable, Sendable, Hashable, CustomStringConvertible {
    public let invariant: String
    public let module: String
    public let detail: String

    public init(invariant: String, module: String, detail: String) {
        self.invariant = invariant
        self.module = module
        self.detail = detail
    }

    public var description: String { "[\(invariant)] \(module): \(detail)" }
}

/// A structural constraint of the target architecture, written as code so it survives
/// a context reset: the agent can forget it, the gate cannot.
public protocol StructuralInvariant: Sendable {
    var id: String { get }
    var summary: String { get }
    func check(_ graph: ModuleGraph) -> [Violation]
}

/// Lower layers never import higher layers, and features never import other features.
public struct LayerRule: StructuralInvariant {
    public init() {}
    public let id = "layering"
    public let summary = "No upward imports; features never import other features."

    public func check(_ graph: ModuleGraph) -> [Violation] {
        var found: [Violation] = []
        for name in graph.names {
            guard let module = graph.module(name) else { continue }
            for dep in module.imports.sorted() {
                guard let target = graph.module(dep) else { continue }
                if target.layer > module.layer {
                    found.append(Violation(invariant: id, module: name,
                                           detail: "\(module.layer.label) imports \(target.layer.label) \(dep)"))
                } else if module.layer == .feature && target.layer == .feature {
                    found.append(Violation(invariant: id, module: name,
                                           detail: "feature imports feature \(dep)"))
                }
            }
        }
        return found
    }
}

/// Migration order rule: a module that has been migrated to `@Observable` may only depend
/// on modules that are migrated too (bottom-up), so no view mixes the two observation models.
public struct BottomUpMigration: StructuralInvariant {
    public init() {}
    public let id = "bottom-up"
    public let summary = "A migrated module depends only on migrated modules."

    public func check(_ graph: ModuleGraph) -> [Violation] {
        var found: [Violation] = []
        for name in graph.names {
            guard let module = graph.module(name), module.isMigrated else { continue }
            for dep in module.imports.sorted() {
                if let target = graph.module(dep), !target.isMigrated {
                    found.append(Violation(invariant: id, module: name,
                                           detail: "migrated, but \(dep) still has \(target.legacyObservables) ObservableObject types"))
                }
            }
        }
        return found
    }
}

public enum Invariants {
    public static let standard: [any StructuralInvariant] = [LayerRule(), BottomUpMigration()]
}
