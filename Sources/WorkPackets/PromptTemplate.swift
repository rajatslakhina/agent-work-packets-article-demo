import Foundation

/// Renders the session prompt for one packet. The prompt is deliberately short: the
/// invariants live in code and the history lives in PROGRESS.md, so neither has to
/// survive inside the model's context.
public enum PacketPrompt {
    public static func render(_ packet: WorkPacket, ledger: HandoffLedger) -> String {
        let carried = ledger.entry(packet.id)?.notes ?? []
        var lines = [
            "You are running packet \(packet.id) of \(ledger.entries.count). Goal: \(ledger.goal)",
            "",
            "1. Read PROGRESS.md before anything else. It is the only memory of earlier sessions.",
            "2. Scope: \(packet.modules.joined(separator: ", ")) (\(packet.fileCount) files). Do not edit any other module.",
            "3. Do not add imports to fix a compile error. If a fix needs a new dependency, stop and write the reason in PROGRESS.md.",
            "4. Done means: swift test passes, the regression gate passes, and the test log is saved as evidence.",
            "5. Update PROGRESS.md, commit, and stop. Do not start the next packet.",
            "",
            "The gate checks these, so you do not need to remember them, only to not fight them:"
        ]
        lines += ledger.invariantSummaries.map { "- \($0)" }
        if !carried.isEmpty {
            lines += ["", "A previous attempt at this packet failed the gate:"] + carried.map { "- \($0)" }
        }
        return lines.joined(separator: "\n")
    }
}
