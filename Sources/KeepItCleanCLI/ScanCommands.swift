import ArgumentParser
import Foundation
import KeepItCleanCore
import KeepItCleanTUI

struct ScanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Scan rule-backed developer storage and write a short-lived cleanup plan."
    )

    @Option(name: .long, help: "Root to inspect. Repeat for multiple roots.")
    var root: [String] = []

    @Flag(name: .long, help: "Enable conservative deep rule checks.")
    var deep = false

    @Flag(
        name: .long,
        help: "Opt in to aggressive version/artifact retention; implies --deep and remains read-only."
    )
    var hardcore = false

    @Flag(name: .long, help: "Emit the versioned JSON schema.")
    var json = false

    mutating func run() async throws {
        let service = KeepRuntimeFactory.make()
        let roots = root.isEmpty ? [FileManager.default.homeDirectoryForCurrentUser.path] : root
        let planned = try await service.scan(
            roots: roots,
            deep: deep || hardcore,
            hardcore: hardcore
        )

        if json {
            try CLIOutput.json(
                command: "scan",
                data: PlanOutput(
                    report: planned.report,
                    plan: planned.plan,
                    planPath: planned.planURL.path,
                    mode: hardcore ? "read-only-hardcore" : "read-only"
                )
            )
        } else {
            HumanOutput.scan(
                planned,
                label: hardcore ? "Hardcore scan complete (read-only)" : "Scan complete (read-only)"
            )
        }
    }
}

struct AnalyzeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Analyze one path using the same read-only planning pipeline."
    )

    @Argument(help: "Path to analyze. Defaults to your home directory.")
    var path: String?

    @Flag(name: .long, help: "Enable conservative deep rule checks.")
    var deep = false

    @Flag(name: .long, help: "Emit the versioned JSON schema.")
    var json = false

    mutating func run() async throws {
        let service = KeepRuntimeFactory.make()
        let root = path ?? FileManager.default.homeDirectoryForCurrentUser.path
        let planned = try await service.analyze(path: root, deep: deep)

        if json {
            try CLIOutput.json(
                command: "analyze",
                data: PlanOutput(
                    report: planned.report,
                    plan: planned.plan,
                    planPath: planned.planURL.path,
                    mode: "read-only"
                )
            )
        } else {
            HumanOutput.scan(planned, label: "Analysis complete (read-only)")
        }
    }
}

struct CleanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Review a plan, or explicitly apply one by moving selected items to Trash."
    )

    @Option(name: .long, help: "Cleanup plan UUID or path created by scan/analyze/TUI review.")
    var plan: String?

    @Flag(name: .long, help: "Emit the versioned JSON schema.")
    var json = false

    @Flag(
        name: .long,
        help: "Create an aggressive version/artifact-retention preview; never applies by itself."
    )
    var hardcore = false

    @Flag(
        name: .long,
        help: "Open a TUI to select candidates and save a new reviewed plan; never applies by itself."
    )
    var interactive = false

    @OptionGroup var safety: ReadOnlyOrTrashOptions

    mutating func run() async throws {
        let service = KeepRuntimeFactory.make()
        let warnings = [safety.incompleteWarning].compactMap { $0 }

        if hardcore, plan != nil {
            throw ValidationError(
                "--hardcore creates a new preview. Omit it when reviewing or applying an existing plan."
            )
        }
        if interactive, json {
            throw ValidationError("--interactive cannot be combined with --json.")
        }
        if interactive, safety.requestsTrashMutation {
            throw ValidationError(
                "--interactive only reviews. Save the reviewed plan, then apply it in a separate command."
            )
        }

        if safety.requestsTrashMutation {
            guard let plan else {
                throw ValidationError("--plan is required with --apply --trash. Scan and review first.")
            }
            let reviewed = try service.loadPlan(reference: plan)
            let operation = try await service.applyTrash(plan: reviewed)
            if json {
                try CLIOutput.json(command: "clean", data: operation, warnings: warnings)
            } else {
                HumanOutput.operation(operation)
                CLIOutput.text("Items were moved to Trash. Space is not reclaimed until Trash is emptied.")
            }
            return
        }

        if let plan {
            let reviewed = try service.loadPlan(reference: plan)
            if interactive {
                try saveInteractiveReview(reviewed, service: service)
                return
            }
            if json {
                try CLIOutput.json(
                    command: "clean",
                    data: PlanOutput(report: nil, plan: reviewed, planPath: plan, mode: "read-only"),
                    warnings: warnings
                )
            } else {
                warnings.forEach(CLIOutput.warning)
                HumanOutput.plan(reviewed, path: plan)
                CLIOutput.text("Read-only review. Add --apply --trash to move the selected items to Trash.")
            }
            return
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let hardcoreMode = hardcore
        let planned: PlannedScan
        if interactive {
            planned = try await TUIScanProgress.run(
                title: hardcoreMode ? "Hardcore developer cleanup" : "Developer storage review",
                detail: hardcoreMode
                    ? "Finding stale toolchains and older generated artifacts."
                    : "Finding rule-backed cleanup candidates."
            ) {
                try await service.scan(
                    roots: [home],
                    deep: hardcoreMode,
                    hardcore: hardcoreMode
                )
            }
        } else {
            planned = try await service.scan(
                roots: [home],
                deep: hardcoreMode,
                hardcore: hardcoreMode
            )
        }
        if interactive {
            try saveInteractiveReview(planned.plan, service: service)
            return
        }
        if json {
            try CLIOutput.json(
                command: "clean",
                data: PlanOutput(
                    report: planned.report,
                    plan: planned.plan,
                    planPath: planned.planURL.path,
                    mode: hardcore ? "read-only-hardcore" : "read-only"
                ),
                warnings: warnings
            )
        } else {
            warnings.forEach(CLIOutput.warning)
            HumanOutput.scan(
                planned,
                label: hardcore
                    ? "Hardcore clean preview complete (read-only)"
                    : "Clean preview complete (read-only)"
            )
        }
    }

    private func saveInteractiveReview(
        _ original: CleanupPlan,
        service: any KeepCommandServing
    ) throws {
        let result = try KeepItCleanTUIRunner().run(
            initialState: TUIAdapter.state(plan: original)
        )
        switch result {
        case .cancelled:
            CLIOutput.text("Review cancelled. No files were changed.")
        case let .accepted(itemIDs):
            guard !itemIDs.isEmpty else {
                CLIOutput.text("No candidates selected. No files were changed.")
                return
            }
            let reviewed = TUIAdapter.plan(original, selecting: itemIDs)
            let url = try service.save(plan: reviewed)
            HumanOutput.plan(reviewed, path: url.path)
            CLIOutput.text(
                "Nothing was changed. Apply with: keep clean --plan \"\(url.path)\" --apply --trash"
            )
        }
    }
}
