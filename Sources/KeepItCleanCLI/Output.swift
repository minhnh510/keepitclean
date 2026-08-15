import Foundation
import KeepItCleanCore
import KeepItCleanTUI

struct JSONEnvelope<Payload: Encodable>: Encodable {
    let schemaVersion = keepItCleanSchemaVersion
    let command: String
    let generatedAt: Date
    let status: String
    let data: Payload
    let warnings: [String]

    init(command: String, data: Payload, warnings: [String] = []) {
        self.command = command
        self.generatedAt = Date()
        self.status = "ok"
        self.data = data
        self.warnings = warnings
    }
}

enum CLIOutput {
    static func json<Payload: Encodable>(
        command: String,
        data: Payload,
        warnings: [String] = []
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(JSONEnvelope(command: command, data: data, warnings: warnings))
        FileHandle.standardOutput.write(bytes)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    static func text(_ value: String) {
        FileHandle.standardOutput.write(Data((value + "\n").utf8))
    }

    static func raw(_ value: String) {
        FileHandle.standardOutput.write(Data(value.utf8))
    }

    static func warning(_ value: String) {
        let renderer = TUIConsoleRenderer.terminal(fileDescriptor: STDERR_FILENO)
        FileHandle.standardError.write(Data(renderer.notice(
            title: "Warning",
            message: value,
            tone: .warning
        ).utf8))
    }

    static func notice(
        _ title: String,
        _ value: String,
        tone: TUIConsoleTone = .accent
    ) {
        let renderer = TUIConsoleRenderer.terminal()
        raw(renderer.notice(title: title, message: value, tone: tone))
    }
}

struct PlanOutput: Encodable {
    let report: ScanReport?
    let plan: CleanupPlan
    let planPath: String
    let mode: String
}

struct PathOutput: Encodable {
    let path: String
}

struct MessageOutput: Encodable {
    let message: String
}

enum HumanOutput {
    static func scan(_ planned: PlannedScan, label: String) {
        CLIOutput.raw(renderScan(planned, label: label))
        if planned.report.partial {
            CLIOutput.warning("The scan was partial. Review every issue; blocked or unknown state stays unselected.")
        }
        for issue in planned.report.issues {
            CLIOutput.warning([issue.path, issue.message].compactMap { $0 }.joined(separator: ": "))
        }
    }

    static func renderScan(
        _ planned: PlannedScan,
        label: String,
        renderer: TUIConsoleRenderer = .terminal()
    ) -> String {
        var lines = [
            TUIConsoleLine("✓ \(label)", tone: .success),
            TUIConsoleLine("Read-only inventory · no target files changed", tone: .muted),
            TUIConsoleLine(""),
            TUIConsoleLine("CANDIDATES   \(planned.report.candidates.count)"),
            TUIConsoleLine("ALLOCATED    \(KeepFormatting.bytes(planned.report.totalAllocatedBytes))"),
            TUIConsoleLine("RECLAIM      \(KeepFormatting.bytes(planned.report.totalReclaimableBytes))", tone: .success),
        ]
        let hardcoreGroups = Dictionary(
            grouping: planned.report.candidates.filter { $0.ruleID.hasPrefix("hardcore.") },
            by: \.category
        )
        for category in hardcoreGroups.keys.sorted() {
            let candidates = hardcoreGroups[category] ?? []
            let eligible = candidates.filter { $0.actionKind == .trash && !$0.isBlocked }
            let blocked = candidates.count - eligible.count
            let reclaimable = eligible.reduce(UInt64(0)) { $0 &+ $1.reclaimableBytes }
            lines.append(TUIConsoleLine(
                "• \(category)  \(eligible.count) eligible · \(blocked) blocked · \(KeepFormatting.bytes(reclaimable))",
                tone: eligible.isEmpty ? .muted : .normal
            ))
        }
        lines.append(TUIConsoleLine(""))
        lines.append(TUIConsoleLine(
            "PLAN         \(renderer.compactPath(planned.planURL.path, maxWidth: renderer.width - 17))",
            tone: .accent
        ))
        return renderer.card(
            title: label.contains("Analysis") ? "Analysis" : "Scan result",
            badge: "READ-ONLY",
            lines: lines,
            footer: TUIConsoleLine("Nothing moved · review plan before cleanup", tone: .muted)
        )
    }

    static func plan(_ plan: CleanupPlan, path: String) {
        CLIOutput.raw(renderPlan(plan, path: path))
    }

    static func renderPlan(
        _ plan: CleanupPlan,
        path: String,
        renderer: TUIConsoleRenderer = .terminal()
    ) -> String {
        let selected = plan.selectedItems
        let bytes = selected.reduce(UInt64(0)) { $0 &+ $1.candidate.reclaimableBytes }
        return renderer.card(
            title: "Cleanup plan",
            badge: "REVIEWED",
            lines: [
                TUIConsoleLine("SELECTED     \(selected.count) / \(plan.items.count)"),
                TUIConsoleLine("RECLAIM      \(KeepFormatting.bytes(bytes))", tone: .success),
                TUIConsoleLine("PLAN ID      \(plan.id.uuidString)", tone: .muted),
                TUIConsoleLine("FILE         \(renderer.compactPath(path, maxWidth: renderer.width - 17))", tone: .accent),
            ],
            footer: TUIConsoleLine("Immutable review · apply requires the exact plan", tone: .muted)
        )
    }

    static func operation(_ operation: OperationRecord) {
        CLIOutput.raw(renderOperation(operation))
    }

    static func renderOperation(
        _ operation: OperationRecord,
        renderer: TUIConsoleRenderer = .terminal()
    ) -> String {
        let successCount = operation.items.filter { itemTone($0.status) == .success }.count
        var lines = [
            TUIConsoleLine("\(operation.kind.rawValue.capitalized) cleanup · \(successCount)/\(operation.items.count) completed"),
            TUIConsoleLine("ID  \(operation.id.uuidString)", tone: .muted),
            TUIConsoleLine(""),
        ]
        let visibleItems = operation.items.prefix(12)
        for item in visibleItems {
            let compactPath = renderer.compactPath(item.originalPath, maxWidth: renderer.width - 12)
            let message = item.message.map { " · \($0)" } ?? ""
            lines.append(TUIConsoleLine(
                "\(itemGlyph(item.status)) \(itemLabel(item.status))  \(compactPath)\(message)",
                tone: itemTone(item.status),
                continuationIndent: 4
            ))
        }
        if operation.items.count > visibleItems.count {
            lines.append(TUIConsoleLine(
                "… \(operation.items.count - visibleItems.count) more items · use keep history --json for the full record",
                tone: .muted
            ))
        }
        return renderer.card(
            title: "Operation",
            badge: operation.state.rawValue.uppercased(),
            lines: lines,
            footer: TUIConsoleLine(operationFooter(operation), tone: operation.state == .completed ? .success : .warning)
        )
    }

    static func doctor(_ checks: [DoctorCheck]) {
        CLIOutput.raw(renderDoctor(checks))
    }

    static func renderDoctor(
        _ checks: [DoctorCheck],
        renderer: TUIConsoleRenderer = .terminal()
    ) -> String {
        let ready = checks.filter { $0.status == "ok" }.count
        let protected = checks.filter { $0.status == "blocked" && $0.id == "native-execution" }.count
        let blocked = checks.filter { $0.status == "blocked" && $0.id != "native-execution" }.count
        let optional = checks.count - ready - protected - blocked
        var lines = [
            TUIConsoleLine(
                "\(ready) ready · \(protected) protected · \(blocked) blocked · \(optional) optional",
                tone: blocked == 0 ? .success : .warning
            ),
            TUIConsoleLine("Read-only diagnostics · no settings changed", tone: .muted),
            TUIConsoleLine(""),
        ]
        for check in checks {
            let isProtected = check.status == "blocked" && check.id == "native-execution"
            let tone = check.status == "ok" ? TUIConsoleTone.success
                : isProtected ? .muted
                : check.status == "blocked" ? .danger : .warning
            let glyph = check.status == "ok" ? "✓" : isProtected ? "◇" : check.status == "blocked" ? "×" : "!"
            let message = check.message.replacingOccurrences(of: renderer.homePath, with: "~")
            lines.append(TUIConsoleLine(
                "\(glyph) \(humanize(check.id))  ·  \(message)",
                tone: tone,
                continuationIndent: 4
            ))
        }
        return renderer.card(
            title: "Doctor",
            badge: blocked == 0 ? "READY" : "ATTENTION",
            lines: lines,
            footer: TUIConsoleLine("Blocked checks stay protected · ? explains safety in the dashboard", tone: .muted)
        )
    }

    static func emptyHistory() {
        let renderer = TUIConsoleRenderer.terminal()
        CLIOutput.raw(renderer.card(
            title: "History",
            badge: "EMPTY",
            lines: [
                TUIConsoleLine("No KeepItClean operations recorded.", tone: .muted),
                TUIConsoleLine("Completed cleanup and undo operations will appear here.", tone: .muted),
            ],
            footer: TUIConsoleLine("Nothing to undo", tone: .muted)
        ))
    }

    static func trashOutcome(_ operation: OperationRecord) {
        Self.operation(operation)
        switch operation.state {
        case .completed:
            CLIOutput.notice(
                "Undo available",
                "Moved to Trash. Restore with `keep undo \(operation.id.uuidString)`; space is reclaimed only after Trash is emptied.",
                tone: .success
            )
        case .partial:
            CLIOutput.warning("Cleanup completed only partially. Review the operation before retrying.")
            CLIOutput.notice("Recover", "Use `keep undo \(operation.id.uuidString)` for moved items.")
        case .failed, .running, .planned:
            CLIOutput.warning("Cleanup did not complete. No reclaimed-space claim is being made.")
            CLIOutput.notice("Inspect", "Run `keep history` for the journal record.")
        }
    }

    private static func humanize(_ value: String) -> String {
        switch value {
        case "macos": return "macOS"
        case "process-probe": return "Process probe"
        case "native-execution": return "Native execution"
        case "system-helper": return "System helper"
        default: break
        }
        return value.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }

    private static func itemGlyph(_ status: OperationItemStatus) -> String {
        switch status {
        case .movedToTrash, .undone, .finalized, .executed: "✓"
        case .pending: "◐"
        case .skipped: "–"
        case .failed: "×"
        }
    }

    private static func itemLabel(_ status: OperationItemStatus) -> String {
        switch status {
        case .movedToTrash: "Trashed"
        case .undone: "Restored"
        case .finalized: "Finalized"
        case .executed: "Executed"
        case .pending: "Pending"
        case .skipped: "Skipped"
        case .failed: "Failed"
        }
    }

    private static func itemTone(_ status: OperationItemStatus) -> TUIConsoleTone {
        switch status {
        case .movedToTrash, .undone, .finalized, .executed: .success
        case .pending: .warning
        case .skipped: .muted
        case .failed: .danger
        }
    }

    private static func operationFooter(_ operation: OperationRecord) -> String {
        switch (operation.kind, operation.state) {
        case (.trash, .completed), (.trash, .partial):
            "Undo available · keep undo \(operation.id.uuidString)"
        case (.undo, .completed):
            "Restored to original locations"
        case (.finalize, .completed):
            "Permanent finalize completed · cannot be undone"
        case (_, .failed):
            "Operation failed · inspect the journal before retrying"
        default:
            "Journal preserved · inspect with keep history --json"
        }
    }
}

enum TrashApplyUI {
    static func run(
        plan: CleanupPlan,
        service: any KeepCommandServing
    ) async throws -> OperationRecord {
        let selected = plan.selectedItems
        let bytes = selected.reduce(UInt64(0)) { partial, item in
            let (sum, overflow) = partial.addingReportingOverflow(item.candidate.reclaimableBytes)
            return overflow ? .max : sum
        }
        return try await TUITrashProgress.run(
            itemCount: selected.count,
            reclaimableBytes: bytes
        ) {
            try await service.applyTrash(plan: plan)
        }
    }
}
