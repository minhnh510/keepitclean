import ArgumentParser
import Foundation
import KeepItCleanCore
import KeepItCleanSystem

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
        CLIOutput.text(PrivilegedHelperClient().doctor())
    }
}

enum SystemHumanOutput {
    static func scan(_ result: SystemCleanupScanResult) {
        CLIOutput.text("System cache preview: \(result.plan.candidates.count) exact files")
        CLIOutput.text("Potential quarantine: \(KeepFormatting.bytes(result.plan.reclaimableBytes))")
        CLIOutput.text("Plan: \(result.plan.id.uuidString) (expires in 15 minutes)")
        result.warnings.forEach(CLIOutput.warning)
        CLIOutput.text(
            "Apply to quarantine: keep system apply \(result.plan.id.uuidString) --confirm \(SystemCleanupEngine.applyToken(for: result.plan.id))"
        )
    }

    static func operation(_ operation: SystemCleanupOperation) {
        CLIOutput.text("System operation \(operation.id.uuidString): \(operation.state.rawValue)")
        let successful = operation.items.filter {
            $0.status == .quarantined || $0.status == .restored || $0.status == .finalized
        }.count
        CLIOutput.text("Items: \(successful)/\(operation.items.count)")
        if operation.state == .quarantined || operation.state == .partial {
            CLIOutput.text("Undo: keep system undo \(operation.id.uuidString)")
            CLIOutput.text(
                "Permanently reclaim: keep system finalize \(operation.id.uuidString) --confirm \(SystemCleanupEngine.finalizeToken(for: operation.id))"
            )
        }
    }
}
