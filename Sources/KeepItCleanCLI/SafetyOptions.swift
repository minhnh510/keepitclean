import ArgumentParser
import Foundation
import KeepItCleanCore

struct ReadOnlyOrTrashOptions: ParsableArguments {
    @Flag(name: .long, help: "Apply a previously reviewed, still-valid plan.")
    var apply = false

    @Flag(name: .long, help: "Move eligible items to macOS Trash. Required together with --apply.")
    var trash = false

    var requestsTrashMutation: Bool { apply && trash }

    var incompleteWarning: String? {
        guard apply != trash else { return nil }
        return "Both --apply and --trash are required. This invocation remains read-only."
    }
}

enum CLIValidation {
    static func uuid(_ value: String, label: String) throws -> UUID {
        guard let id = UUID(uuidString: value) else {
            throw ValidationError("\(label) must be a UUID.")
        }
        return id
    }

    static func requireConfirmation(_ supplied: String?, expected: String) throws -> String {
        guard let supplied, supplied == expected else {
            throw ValidationError("Type the exact confirmation token with --confirm \"\(expected)\".")
        }
        return supplied
    }
}
