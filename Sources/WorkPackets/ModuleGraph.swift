import Foundation

/// Architectural layer of a module. Lower layers must never import higher ones.
public enum Layer: Int, Codable, Sendable, CaseIterable, Comparable {
    case core = 0
    case service = 1
    case feature = 2
    case app = 3

    public static func < (lhs: Layer, rhs: Layer) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .core: return "core"
        case .service: return "service"
        case .feature: return "feature"
        case .app: return "app"
        }
    }
}

/// One Swift module in the codebase being migrated.
public struct Module: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let layer: Layer
    public var imports: [String]
    public let fileCount: Int
    /// Remaining legacy `ObservableObject` types still to migrate to `@Observable`.
    public var legacyObservables: Int

    public init(name: String, layer: Layer, imports: [String], fileCount: Int, legacyObservables: Int) {
        self.name = name
        self.layer = layer
        self.imports = imports
        self.fileCount = max(0, fileCount)
        self.legacyObservables = max(0, legacyObservables)
    }

    public var isMigrated: Bool { legacyObservables == 0 }
}

public enum GraphError: Error, Equatable, CustomStringConvertible {
    case duplicateModule(String)
    case unknownImport(module: String, imports: String)
    case cycle([String])

    public var description: String {
        switch self {
        case .duplicateModule(let name): return "duplicate module \(name)"
        case .unknownImport(let module, let imports): return "\(module) imports unknown module \(imports)"
        case .cycle(let names): return "dependency cycle among: \(names.joined(separator: ", "))"
        }
    }
}

/// A snapshot of the module dependency graph. Value type, so a "before" and "after"
/// snapshot can be compared by the regression gate.
public struct ModuleGraph: Codable, Sendable, Equatable {
    public private(set) var modules: [String: Module]

    public init(_ list: [Module]) throws {
        var map: [String: Module] = [:]
        for module in list {
            guard map[module.name] == nil else { throw GraphError.duplicateModule(module.name) }
            map[module.name] = module
        }
        for module in list {
            for dep in module.imports where map[dep] == nil {
                throw GraphError.unknownImport(module: module.name, imports: dep)
            }
        }
        self.modules = map
    }

    public var names: [String] { modules.keys.sorted() }
    public var totalFiles: Int { modules.values.reduce(0) { $0 + $1.fileCount } }
    public var totalLegacyObservables: Int { modules.values.reduce(0) { $0 + $1.legacyObservables } }

    public func module(_ name: String) -> Module? { modules[name] }

    public func dependencies(of name: String) -> [String] {
        (modules[name]?.imports ?? []).sorted()
    }

    /// All modules reachable through imports, excluding `name` itself.
    public func transitiveDependencies(of name: String) -> Set<String> {
        var seen: Set<String> = []
        var stack = dependencies(of: name)
        while let next = stack.popLast() {
            guard next != name, seen.insert(next).inserted else { continue }
            stack.append(contentsOf: dependencies(of: next))
        }
        return seen
    }

    /// Kahn's algorithm, grouped by level: level 0 has no imports, level n only imports
    /// lower levels. Deterministic (names sorted within a level). Throws on cycles.
    public func topologicalLevels() throws -> [[String]] {
        var remaining: [String: Set<String>] = [:]
        for (name, module) in modules { remaining[name] = Set(module.imports) }
        var levels: [[String]] = []
        while !remaining.isEmpty {
            let ready = remaining.filter { $0.value.isEmpty }.map(\.key).sorted()
            guard !ready.isEmpty else { throw GraphError.cycle(remaining.keys.sorted()) }
            levels.append(ready)
            for name in ready { remaining[name] = nil }
            for key in remaining.keys { remaining[key]?.subtract(ready) }
        }
        return levels
    }

    // MARK: Mutation (used by the simulated agent)

    public mutating func migrate(_ name: String) {
        modules[name]?.legacyObservables = 0
    }

    public mutating func addImport(_ dep: String, to name: String) {
        guard modules[dep] != nil, var module = modules[name], !module.imports.contains(dep) else { return }
        module.imports.append(dep)
        modules[name] = module
    }

    public mutating func removeImport(_ dep: String, from name: String) {
        modules[name]?.imports.removeAll { $0 == dep }
    }

    /// Modules whose content differs between two snapshots.
    public func changedModules(comparedTo other: ModuleGraph) -> Set<String> {
        let all = Set(modules.keys).union(other.modules.keys)
        return all.filter { modules[$0] != other.modules[$0] }
    }
}
