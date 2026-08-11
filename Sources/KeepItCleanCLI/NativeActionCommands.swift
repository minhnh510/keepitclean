import ArgumentParser
import Foundation
import KeepItCleanCore

struct NativeActionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "native-action",
        abstract: "Review or run an allowlisted tool-native action.",
        subcommands: [
            NativeActionListCommand.self,
            NativeActionPlanCommand.self,
            NativeActionRunCommand.self,
        ]
    )
}

struct NativeActionListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List allowlisted actions.")
    private static let parameterizedHint = "Parameterized actions use exact IDs: colima.stop.<PROFILE>, android.avd-delete.<NAME>, and vscode.extension-uninstall.<PUBLISHER.NAME>. Run the corresponding read-only status/list action first."

    @Flag(name: .long, help: "Emit the versioned JSON schema.")
    var json = false

    mutating func run() throws {
        let actions = KeepRuntimeFactory.make().nativeActions()
        if json {
            try CLIOutput.json(
                command: "native-action list",
                data: actions,
                warnings: [Self.parameterizedHint]
            )
            return
        }
        if actions.isEmpty {
            CLIOutput.text("No native actions are currently available.")
        }
        for action in actions {
            let mode = action.isReadOnly ? "read-only" : "changes state"
            CLIOutput.text("\(action.descriptor.id) [\(mode)] — \(action.descriptor.title)")
            CLIOutput.text("  \(action.descriptor.summary)")
        }
        CLIOutput.text(Self.parameterizedHint)
    }
}

struct NativeActionPlanOutput: Encodable {
    let plan: NativeActionPlan
    let planPath: String
    let isReadOnly: Bool
    let nonUndoable: Bool
}

struct NativeActionPlanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "plan", abstract: "Write a short-lived native-action plan.")

    @Argument(help: "Exact allowlisted action ID.")
    var actionID: String

    @Flag(name: .long, help: "Emit the versioned JSON schema.")
    var json = false

    mutating func run() throws {
        let service = KeepRuntimeFactory.make()
        let (plan, url) = try service.makeNativeActionPlan(actionID: actionID)
        let isReadOnly = service.nativeActionIsReadOnly(actionID: actionID) ?? false
        let warnings = isReadOnly
            ? []
            : ["Tool-native changes may be non-undoable. Review executable, argv, and affected state before run."]
        if json {
            try CLIOutput.json(
                command: "native-action plan",
                data: NativeActionPlanOutput(
                    plan: plan,
                    planPath: url.path,
                    isReadOnly: isReadOnly,
                    nonUndoable: !isReadOnly
                ),
                warnings: warnings
            )
        } else {
            warnings.forEach(CLIOutput.warning)
            CLIOutput.text("Plan: \(url.path)")
            CLIOutput.text("Mode: \(isReadOnly ? "read-only" : "changes tool-managed state")")
            CLIOutput.text("Executable: \(plan.descriptor.executable)")
            CLIOutput.text("Arguments: \(plan.descriptor.arguments.joined(separator: " "))")
            CLIOutput.text("Confirmation token: \(plan.confirmationToken)")
        }
    }
}

struct NativeActionRunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Run one reviewed native-action plan.")

    @Option(name: .long, help: "Native-action plan UUID or path.")
    var plan: String

    @Option(name: .long, help: "Exact typed confirmation token stored in the plan.")
    var confirm: String?

    @Flag(name: .long, help: "Emit the versioned JSON schema.")
    var json = false

    mutating func run() throws {
        let service = KeepRuntimeFactory.make()
        let reviewed = try service.loadNativeActionPlan(reference: plan)
        let isReadOnly = service.nativeActionIsReadOnly(actionID: reviewed.descriptor.id) ?? false
        let warnings = isReadOnly
            ? []
            : ["This native action can change tool-managed state and may not be undoable: \(reviewed.descriptor.affectedState)"]
        if !json { warnings.forEach(CLIOutput.warning) }
        let token = try CLIValidation.requireConfirmation(confirm, expected: reviewed.confirmationToken)
        let result = try service.runNativeAction(plan: reviewed, confirmationToken: token)
        if json {
            try CLIOutput.json(command: "native-action run", data: result, warnings: warnings)
        } else {
            HumanOutput.operation(result)
        }
    }
}
