import ArgumentParser
import Foundation
import KeepItCleanCore
import KeepItCleanSystem
import KeepItCleanTUI

struct Keep: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keep",
        abstract: "Review and safely reclaim developer storage on macOS.",
        discussion: "Scans are read-only. Dashboard Clean combines normal, hardcore, and optional system cleanup in one review. Direct subcommands remain available for scripting.",
        version: "KeepItClean \(keepItCleanVersion)",
        subcommands: [
            ScanCommand.self,
            AnalyzeCommand.self,
            CleanCommand.self,
            UndoCommand.self,
            FinalizeCommand.self,
            NativeActionCommand.self,
            SystemCommand.self,
            HistoryCommand.self,
            RulesCommand.self,
            DoctorCommand.self,
            CompletionCommand.self,
        ]
    )

    mutating func run() async throws {
        let service = KeepRuntimeFactory.make()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let choice = try KeepItCleanHomeRunner().choose() else {
            CLIOutput.text("KeepItClean closed. No files were changed.")
            return
        }
        switch choice {
        case .clean:
            try await runClean(service: service, home: home)
        case .analyze:
            let planned = try await TUIScanProgress.run(
                title: "Storage overview",
                detail: "Read-only top-level allocation analysis."
            ) {
                try await service.analyze(path: home, deep: false)
            }
            HumanOutput.scan(planned, label: "Analysis complete (read-only)")
        case .doctor:
            let checks = await service.doctor()
            for check in checks {
                CLIOutput.text("[\(check.status)] \(check.id): \(check.message)")
            }
        case .history:
            let records = try service.history(limit: 20)
            if records.isEmpty {
                CLIOutput.text("No KeepItClean operations recorded.")
            } else {
                records.forEach(HumanOutput.operation)
            }
        }
    }

    private func runClean(
        service: any KeepCommandServing,
        home: String
    ) async throws {
        let planned = try await TUIScanProgress.run(
            title: "All-in-one cleanup inventory",
            detail: "Normal caches, 7-day retention, toolchains, and generated artifacts."
        ) {
            try await service.scan(roots: [home], deep: true, hardcore: true)
        }
        let systemClient = PrivilegedHelperClient()
        let systemResult = scanSystemIfAvailable(client: systemClient)
        let initialState = TUIAdapter.unifiedAutomaticReviewState(
            plan: planned.plan,
            system: systemResult
        )
        guard !initialState.selectedItemIDs.isEmpty else {
            CLIOutput.text("No eligible cleanup candidates were found. No files were changed.")
            return
        }
        let result = try KeepItCleanTUIRunner().run(
            initialState: initialState
        )
        switch result {
        case .cancelled:
            CLIOutput.text("Cleanup cancelled. No files were changed.")
        case let .accepted(ids):
            try saveUnifiedPreview(
                selectedItemIDs: ids,
                userPlan: planned.plan,
                systemResult: systemResult,
                service: service
            )
        case let .applyRequested(ids):
            try await applyUnifiedCleanup(
                selectedItemIDs: ids,
                userPlan: planned.plan,
                systemResult: systemResult,
                systemClient: systemClient,
                service: service
            )
        }
    }

    private func scanSystemIfAvailable(
        client: PrivilegedHelperClient
    ) -> SystemCleanupScanResult? {
        guard client.isReady else {
            CLIOutput.warning(
                "System caches were skipped because the optional helper is not installed. "
                    + "Run `make install-helper` from the source directory to include them."
            )
            return nil
        }
        CLIOutput.text("Including allowlisted system caches; macOS may request administrator access.")
        do {
            let result = try client.scan()
            CLIOutput.text(
                "System inventory: \(result.plan.candidates.count) files, "
                    + "\(KeepFormatting.bytes(result.plan.reclaimableBytes)) potential."
            )
            result.warnings.forEach(CLIOutput.warning)
            return result
        } catch {
            CLIOutput.warning(
                "System caches were skipped: \(error.localizedDescription)"
            )
            return nil
        }
    }

    private func saveUnifiedPreview(
        selectedItemIDs: [String],
        userPlan: CleanupPlan,
        systemResult: SystemCleanupScanResult?,
        service: any KeepCommandServing
    ) throws {
        let userIDs = TUIAdapter.userItemIDs(from: selectedItemIDs)
        if !userIDs.isEmpty {
            let reviewed = TUIAdapter.plan(userPlan, selecting: userIDs)
            let url = try service.save(plan: reviewed)
            HumanOutput.plan(reviewed, path: url.path)
        }
        if let systemResult,
           TUIAdapter.selectsEverySystemCandidate(selectedItemIDs, result: systemResult) {
            let id = systemResult.plan.id
            CLIOutput.text("System plan: \(id.uuidString)")
            CLIOutput.text(
                "Apply separately with: keep system apply \(id.uuidString) "
                    + "--confirm \(SystemCleanupEngine.applyToken(for: id))"
            )
        }
        CLIOutput.text("Nothing was changed.")
    }

    private func applyUnifiedCleanup(
        selectedItemIDs: [String],
        userPlan: CleanupPlan,
        systemResult: SystemCleanupScanResult?,
        systemClient: PrivilegedHelperClient,
        service: any KeepCommandServing
    ) async throws {
        var failures: [String] = []
        let userIDs = TUIAdapter.userItemIDs(from: selectedItemIDs)
        if !userIDs.isEmpty {
            do {
                let reviewed = TUIAdapter.plan(userPlan, selecting: userIDs)
                let url = try service.save(plan: reviewed)
                HumanOutput.plan(reviewed, path: url.path)
                let operation = try await TrashApplyUI.run(plan: reviewed, service: service)
                HumanOutput.trashOutcome(operation)
            } catch {
                failures.append("User/developer cleanup: \(error.localizedDescription)")
            }
        }

        if let systemResult,
           TUIAdapter.selectsEverySystemCandidate(selectedItemIDs, result: systemResult) {
            do {
                let planID = systemResult.plan.id
                let operation = try systemClient.apply(
                    planID: planID,
                    confirmationToken: SystemCleanupEngine.applyToken(for: planID)
                )
                SystemHumanOutput.operation(operation)
            } catch {
                failures.append("System cleanup: \(error.localizedDescription)")
            }
        }

        if failures.isEmpty {
            CLIOutput.text("All-in-one cleanup completed. Trash/quarantine items remain undoable.")
        } else {
            failures.forEach(CLIOutput.warning)
            throw KeepItCleanError.io("All-in-one cleanup completed partially; review the operation IDs above.")
        }
    }
}

enum KeepArgumentRouting {
    static func normalized(_ arguments: [String]) -> [String] {
        switch arguments {
        case ["--hardcore"]:
            return ["clean", "--hardcore", "--interactive"]
        case ["--hardcore", "--help"]:
            return ["clean", "--help"]
        default:
            return arguments
        }
    }
}

@main
enum KeepEntryPoint {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        await Keep.main(KeepArgumentRouting.normalized(arguments))
    }
}
