import Foundation

public enum PacketStatus: String, Codable, Sendable {
    case pending, inProgress, verified, failed
}

/// Something observed, not asserted: a test log, a gate report, a screenshot path.
public struct Evidence: Codable, Sendable, Hashable {
    public let kind: String
    public let reference: String

    public init(kind: String, reference: String) {
        self.kind = kind
        self.reference = reference
    }
}

public struct LedgerEntry: Codable, Sendable, Equatable {
    public let packet: WorkPacket
    public var status: PacketStatus
    public var attempts: Int
    public var evidence: [Evidence]
    public var notes: [String]
}

public enum LedgerError: Error, Equatable {
    case unknownPacket(String)
    case dependenciesNotVerified(packet: String, waitingOn: [String])
    case notInProgress(String)
}

/// The handoff file that survives context resets. Every session starts by reading it and
/// ends by writing it. Status defaults to FAIL: "verified" needs a passing gate plus evidence.
public struct HandoffLedger: Codable, Sendable, Equatable {
    public let goal: String
    public let invariantSummaries: [String]
    public private(set) var entries: [LedgerEntry]

    public init(goal: String, packets: [WorkPacket], invariants: [any StructuralInvariant] = Invariants.standard) {
        self.goal = goal
        self.invariantSummaries = invariants.map { "\($0.id): \($0.summary)" }
        self.entries = packets.map { LedgerEntry(packet: $0, status: .pending, attempts: 0, evidence: [], notes: []) }
    }

    public func entry(_ id: String) -> LedgerEntry? { entries.first { $0.packet.id == id } }

    public var verifiedCount: Int { entries.filter { $0.status == .verified }.count }
    public var isComplete: Bool { !entries.isEmpty && verifiedCount == entries.count }

    /// The first pending or failed packet whose dependencies are all verified.
    public func nextPacket() -> WorkPacket? {
        let verified = Set(entries.filter { $0.status == .verified }.map(\.packet.id))
        return entries.first { entry in
            (entry.status == .pending || entry.status == .failed)
                && entry.packet.dependsOn.allSatisfy(verified.contains)
        }?.packet
    }

    public mutating func start(_ id: String) throws {
        guard let index = entries.firstIndex(where: { $0.packet.id == id }) else { throw LedgerError.unknownPacket(id) }
        let verified = Set(entries.filter { $0.status == .verified }.map(\.packet.id))
        let waiting = entries[index].packet.dependsOn.filter { !verified.contains($0) }
        guard waiting.isEmpty else { throw LedgerError.dependenciesNotVerified(packet: id, waitingOn: waiting) }
        entries[index].status = .inProgress
        entries[index].attempts += 1
    }

    /// Closes a packet. Returns the resulting status: verified only if the gate passed
    /// and at least one piece of evidence other than the gate itself was recorded.
    @discardableResult
    public mutating func record(_ id: String, gate: GateReport, evidence: [Evidence]) throws -> PacketStatus {
        guard let index = entries.firstIndex(where: { $0.packet.id == id }) else { throw LedgerError.unknownPacket(id) }
        guard entries[index].status == .inProgress else { throw LedgerError.notInProgress(id) }
        entries[index].evidence.append(contentsOf: evidence)
        let attempt = entries[index].attempts
        if !gate.passed {
            entries[index].status = .failed
            entries[index].notes.append(contentsOf: gate.findings.map { "attempt \(attempt): \($0)" })
        } else if evidence.isEmpty {
            entries[index].status = .failed
            entries[index].notes.append("attempt \(attempt): gate passed but no evidence recorded (default FAIL)")
        } else {
            entries[index].status = .verified
        }
        return entries[index].status
    }

    // MARK: Serialisation

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> HandoffLedger {
        try JSONDecoder().decode(HandoffLedger.self, from: data)
    }

    /// PROGRESS.md: what a fresh session reads first.
    public func markdown() -> String {
        var lines = ["# PROGRESS", "", "Goal: \(goal)", "",
                     "Verified \(verifiedCount) of \(entries.count) packets.", "",
                     "## Invariants (enforced by the gate, not by memory)"]
        lines += invariantSummaries.map { "- \($0)" }
        lines += ["", "## Packets", "", "| Packet | Level | Modules | Files | Status | Attempts |",
                  "|---|---|---|---|---|---|"]
        for entry in entries {
            let p = entry.packet
            lines.append("| \(p.id) | \(p.level) | \(p.modules.joined(separator: ", ")) | \(p.fileCount) | \(entry.status.rawValue) | \(entry.attempts) |")
        }
        let notes = entries.flatMap { entry in entry.notes.map { "- \(entry.packet.id) \($0)" } }
        if !notes.isEmpty {
            lines += ["", "## Findings carried forward"] + notes
        }
        if let next = nextPacket() {
            lines += ["", "## Next", "", "\(next.id): \(next.modules.joined(separator: ", "))"]
        }
        return lines.joined(separator: "\n")
    }
}
