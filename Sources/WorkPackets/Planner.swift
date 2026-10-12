import Foundation

/// One session's worth of work: a bounded set of modules at the same dependency level,
/// small enough to finish inside one context window and verify on its own.
public struct WorkPacket: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let level: Int
    public let modules: [String]
    public let fileCount: Int
    /// Packets that must be verified before this one may start.
    public let dependsOn: [String]
    /// True when a single module alone exceeds the file budget.
    public let oversize: Bool

    public var scope: Set<String> { Set(modules) }
}

/// Decomposes a migration into packets: dependency order first, then a file budget.
public struct PacketPlanner: Sendable {
    public let fileBudget: Int

    public init(fileBudget: Int = 60) {
        self.fileBudget = max(1, fileBudget)
    }

    public func plan(_ graph: ModuleGraph) throws -> [WorkPacket] {
        let levels = try graph.topologicalLevels()
        var packets: [WorkPacket] = []
        var packetOf: [String: String] = [:]

        for (levelIndex, level) in levels.enumerated() {
            let pending = level.compactMap(graph.module).filter { !$0.isMigrated }
            var bucket: [Module] = []
            var bucketFiles = 0

            func flush() {
                guard !bucket.isEmpty else { return }
                let id = String(format: "P%02d", packets.count + 1)
                let names = bucket.map(\.name)
                var deps: Set<String> = []
                for name in names {
                    for dep in graph.transitiveDependencies(of: name) {
                        if let owner = packetOf[dep] { deps.insert(owner) }
                    }
                }
                let oversize = bucket.count == 1 && bucketFiles > fileBudget
                packets.append(WorkPacket(id: id, level: levelIndex, modules: names, fileCount: bucketFiles,
                                          dependsOn: deps.sorted(), oversize: oversize))
                for name in names { packetOf[name] = id }
                bucket = []
                bucketFiles = 0
            }

            for module in pending {
                if !bucket.isEmpty && bucketFiles + module.fileCount > fileBudget { flush() }
                bucket.append(module)
                bucketFiles += module.fileCount
            }
            flush()
        }
        return packets
    }
}
