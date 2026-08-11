import ArgumentParser
import Foundation
import KeepItCleanCore
import KeepItCleanTUI

@main
struct Keep: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keep",
        abstract: "Review and safely reclaim developer storage on macOS.",
        discussion: "Scans are read-only. Cleanup requires a reviewed plan and moves files to Trash by default.",
        version: "KeepItClean \(keepItCleanVersion)",
        subcommands: [
            ScanCommand.self,
            AnalyzeCommand.self,
            CleanCommand.self,
            UndoCommand.self,
            FinalizeCommand.self,
            NativeActionCommand.self,
            HistoryCommand.self,
            RulesCommand.self,
            DoctorCommand.self,
            CompletionCommand.self,
        ]
    )

    mutating func run() async throws {
        let service = KeepRuntimeFactory.make()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let planned = try await service.scan(roots: [home], deep: false)
        let state = TUIAdapter.state(report: planned.report)
        let result = try KeepItCleanTUIRunner().run(initialState: state)

        switch result {
        case .cancelled:
            CLIOutput.text("Review cancelled. No files were changed.")
        case let .accepted(itemIDs):
            guard !itemIDs.isEmpty else {
                CLIOutput.text("No candidates selected. No files were changed.")
                return
            }
            let deepRoots = try TUIAdapter.deepScanRoots(
                report: planned.report,
                selecting: itemIDs
            )
            let deepPlanned = try await service.scan(roots: deepRoots, deep: true)
            let deepReport = try TUIAdapter.deepReviewReport(
                deepPlanned.report,
                retaining: itemIDs
            )
            let deepResult = try KeepItCleanTUIRunner().run(
                initialState: TUIAdapter.state(report: deepReport)
            )
            guard case let .accepted(reviewedItemIDs) = deepResult,
                  !reviewedItemIDs.isEmpty
            else {
                CLIOutput.text("Deep review cancelled. No files were changed.")
                return
            }
            var deepPlan = deepPlanned.plan
            let reviewedSet = Set(deepReport.candidates.map(\.id))
            deepPlan.items = deepPlan.items.filter { reviewedSet.contains($0.candidate.id) }
            let reviewed = TUIAdapter.plan(deepPlan, selecting: reviewedItemIDs)
            let url = try service.save(plan: reviewed)
            HumanOutput.plan(reviewed, path: url.path)
            CLIOutput.text("Nothing was changed. Apply with: keep clean --plan \"\(url.path)\" --apply --trash")
        }
    }
}
