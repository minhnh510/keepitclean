import ArgumentParser
import Foundation
import KeepItCleanCore

struct UndoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "undo",
        abstract: "Restore a KeepItClean Trash operation when its Trash entries still exist."
    )

    @Argument(help: "Trash operation UUID.")
    var operation: String

    @Flag(name: .long, help: "Emit the versioned JSON schema.")
    var json = false

    mutating func run() throws {
        let id = try CLIValidation.uuid(operation, label: "operation")
        let result = try KeepRuntimeFactory.make().undo(operationID: id)
        if json {
            try CLIOutput.json(command: "undo", data: result)
        } else {
            HumanOutput.operation(result)
        }
    }
}

struct FinalizeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "finalize",
        abstract: "Permanently remove one operation's entries from Trash. This cannot be undone."
    )

    @Argument(help: "Trash operation UUID.")
    var operation: String

    @Option(name: .long, help: "Exact typed confirmation token shown in the warning.")
    var confirm: String?

    @Flag(name: .long, help: "Emit the versioned JSON schema.")
    var json = false

    mutating func run() throws {
        let id = try CLIValidation.uuid(operation, label: "operation")
        let expected = "FINALIZE-\(id.uuidString.prefix(8).uppercased())"
        let warning = "Finalizing permanently deletes this operation's Trash entries and cannot be undone. Token: \(expected)"
        if !json { CLIOutput.warning(warning) }
        let token = try CLIValidation.requireConfirmation(confirm, expected: expected)
        let result = try KeepRuntimeFactory.make().finalize(operationID: id, confirmationToken: token)
        if json {
            try CLIOutput.json(command: "finalize", data: result, warnings: [warning])
        } else {
            HumanOutput.operation(result)
        }
    }
}

struct HistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Show the local operation audit history."
    )

    @Option(name: .long, help: "Maximum records to show.")
    var limit = 20

    @Flag(name: .long, help: "Emit the versioned JSON schema.")
    var json = false

    mutating func validate() throws {
        guard (1...500).contains(limit) else {
            throw ValidationError("--limit must be between 1 and 500.")
        }
    }

    mutating func run() throws {
        let records = try KeepRuntimeFactory.make().history(limit: limit)
        if json {
            try CLIOutput.json(command: "history", data: records)
        } else if records.isEmpty {
            HumanOutput.emptyHistory()
        } else {
            records.forEach(HumanOutput.operation)
        }
    }
}
