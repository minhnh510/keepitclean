import ArgumentParser
import Foundation
import KeepItCleanCore
import KeepItCleanSystem
import KeepItCleanTUI

struct SystemCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "system",
        abstract: "Root-owned system-cache cleanup through the installed privileged helper.",
        subcommands: [
            SystemScanCommand.self,
            SystemApplyCommand.self,
            SystemUndoCommand.self,
            SystemFinalizeCommand.self,
            SystemDoctorCommand.self,
        ]
    )
}

struct SystemScanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Create a 15-minute root-owned system-cache plan; never mutates files."
    )

    @Flag(name: .long, help: "Emit the schema-v1 system plan as JSON.")
    var json = false

    mutating func run() throws {
        let result = try PrivilegedHelperClient().scan()
        if json {
            try CLIOutput.json(command: "system scan", data: result, warnings: result.warnings)
        } else {
            SystemHumanOutput.scan(result)
        }
    }
}

struct SystemApplyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Move one privileged plan into root-owned quarantine."
    )

    @Argument var plan: String
    @Option(name: .long, help: "Type the exact token SYSTEM-CLEAN-<PLAN_PREFIX>.")
    var confirm: String
    @Flag(name: .long) var json = false

    mutating func run() throws {
        let id = try CLIValidation.uuid(plan, label: "system plan")
        let expected = SystemCleanupEngine.applyToken(for: id)
        guard confirm == expected else { throw ValidationError("Type exactly: \(expected)") }
        let operation = try PrivilegedHelperClient().apply(
            planID: id,
            confirmationToken: confirm
        )
        if json {
            try CLIOutput.json(command: "system apply", data: operation)
        } else {
            SystemHumanOutput.operation(operation)
        }
    }
}

struct SystemUndoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "undo",
        abstract: "Restore quarantined system-cache leaves."
    )

    @Argument var operation: String
    @Flag(name: .long) var json = false

    mutating func run() throws {
        let id = try CLIValidation.uuid(operation, label: "system operation")
        let result = try PrivilegedHelperClient().undo(operationID: id)
        if json {
            try CLIOutput.json(command: "system undo", data: result)
        } else {
            SystemHumanOutput.operation(result)
        }
    }
}

struct SystemFinalizeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "finalize",
        abstract: "Permanently delete one operation's root-owned quarantine entries."
    )

    @Argument var operation: String
    @Option(name: .long) var confirm: String
    @Flag(name: .long) var json = false

    mutating func run() throws {
        let id = try CLIValidation.uuid(operation, label: "system operation")
        let expected = SystemCleanupEngine.finalizeToken(for: id)
        guard confirm == expected else { throw ValidationError("Type exactly: \(expected)") }
        let result = try PrivilegedHelperClient().finalize(operationID: id, token: confirm)
        if json {
            try CLIOutput.json(command: "system finalize", data: result)
        } else {
            SystemHumanOutput.operation(result)
        }
    }
}

struct SystemDoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check whether the root-owned helper is safely installed."
    )

    mutating func run() {
        HumanOutput.doctor([PrivilegedHelperClient().doctorCheck()])
    }
}

enum SystemHumanOutput {
    static func scan(_ result: SystemCleanupScanResult) {
        let renderer = TUIConsoleRenderer.terminal()
        var lines = [
            TUIConsoleLine("✓ Privileged preview complete", tone: .success),
            TUIConsoleLine("Fixed allowlist · exact root-owned leaves only", tone: .muted),
            TUIConsoleLine(""),
            TUIConsoleLine("CANDIDATES   \(result.plan.candidates.count)"),
            TUIConsoleLine("QUARANTINE   \(KeepFormatting.bytes(result.plan.reclaimableBytes))", tone: .success),
            TUIConsoleLine("PLAN ID      \(result.plan.id.uuidString)", tone: .muted),
            TUIConsoleLine("EXPIRES      15 minutes", tone: .warning),
            TUIConsoleLine(""),
            TUIConsoleLine(
                "APPLY        keep system apply \(result.plan.id.uuidString) --confirm \(SystemCleanupEngine.applyToken(for: result.plan.id))",
                tone: .accent
            ),
        ]
        if result.plan.candidates.isEmpty {
            lines.append(TUIConsoleLine("No eligible system-cache leaves were found.", tone: .muted))
        }
        CLIOutput.raw(renderer.card(
            title: "System preview",
            badge: "READ-ONLY",
            lines: lines,
            footer: TUIConsoleLine("No system files moved · apply uses protected quarantine", tone: .muted)
        ))
        result.warnings.forEach(CLIOutput.warning)
    }

    static func operation(_ operation: SystemCleanupOperation) {
        let renderer = TUIConsoleRenderer.terminal()
        let successful = operation.items.filter {
            $0.status == .quarantined || $0.status == .restored || $0.status == .finalized
        }.count
        var lines = [
            TUIConsoleLine("\(operation.action.rawValue.capitalized) · \(successful)/\(operation.items.count) completed"),
            TUIConsoleLine("ID  \(operation.id.uuidString)", tone: .muted),
            TUIConsoleLine(""),
        ]
        for item in operation.items.prefix(12) {
            let tone: TUIConsoleTone = item.status == .failed ? .danger
                : item.status == .pending ? .warning : .success
            let glyph = item.status == .failed ? "×" : item.status == .pending ? "◐" : "✓"
            lines.append(TUIConsoleLine(
                "\(glyph) \(item.status.rawValue.capitalized)  \(renderer.compactPath(item.originalPath, maxWidth: renderer.width - 16))",
                tone: tone
            ))
        }
        if operation.items.count > 12 {
            lines.append(TUIConsoleLine("… \(operation.items.count - 12) more items", tone: .muted))
        }
        var footer = "Root-private journal preserved"
        if operation.state == .quarantined || operation.state == .partial {
            lines.append(TUIConsoleLine(""))
            lines.append(TUIConsoleLine("UNDO      keep system undo \(operation.id.uuidString)", tone: .accent))
            lines.append(TUIConsoleLine(
                "FINALIZE  keep system finalize \(operation.id.uuidString) --confirm \(SystemCleanupEngine.finalizeToken(for: operation.id))",
                tone: .warning
            ))
            footer = "Undo available · finalize is permanent"
        }
        CLIOutput.raw(renderer.card(
            title: "System operation",
            badge: operation.state.rawValue.uppercased(),
            lines: lines,
            footer: TUIConsoleLine(footer, tone: operation.state == .failed ? .danger : .success)
        ))
    }
}
