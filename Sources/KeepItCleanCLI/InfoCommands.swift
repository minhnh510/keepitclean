import ArgumentParser
import Foundation
import KeepItCleanCore

struct RulesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rules", abstract: "List conservative cleanup rules and exclusions.")

    @Flag(name: .long, help: "Emit the versioned JSON schema.")
    var json = false

    mutating func run() throws {
        let rules = KeepRuntimeFactory.make().ruleDescriptors()
        if json {
            try CLIOutput.json(command: "rules", data: rules)
            return
        }
        if rules.isEmpty { CLIOutput.text("No cleanup rules are currently registered.") }
        for rule in rules {
            CLIOutput.text("\(rule.id) — \(rule.name) [\(rule.category)]")
            CLIOutput.text("  \(rule.summary)")
            if !rule.explicitNonTargets.isEmpty {
                CLIOutput.text("  Never targets: \(rule.explicitNonTargets.joined(separator: ", "))")
            }
        }
    }
}

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Check runtime readiness without changing files.")

    @Flag(name: .long, help: "Emit the versioned JSON schema.")
    var json = false

    mutating func run() async throws {
        let checks = await KeepRuntimeFactory.make().doctor()
        if json {
            try CLIOutput.json(command: "doctor", data: checks)
        } else {
            for check in checks {
                CLIOutput.text("[\(check.status)] \(check.id): \(check.message)")
            }
        }
    }
}

struct CompletionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "completion", abstract: "Print a shell completion script.")

    @Argument(help: "Shell name: zsh, bash, or fish.")
    var shell = "zsh"

    mutating func run() throws {
        guard let requestedShell = CompletionShell(rawValue: shell.lowercased()) else {
            throw ValidationError("Unsupported shell \"\(shell)\". Choose zsh, bash, or fish.")
        }
        CLIOutput.text(Keep.completionScript(for: requestedShell))
    }
}
