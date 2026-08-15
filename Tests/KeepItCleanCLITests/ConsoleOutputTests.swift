import Foundation
import KeepItCleanCore
import KeepItCleanTUI
import Testing
@testable import KeepItCleanCLI

@Test func consoleCardsStayWithinTerminalWidthAndCompactHomePaths() {
    let renderer = TUIConsoleRenderer(
        width: 60,
        usesANSI: false,
        homePath: "/Users/minh"
    )
    let card = renderer.card(
        title: "Analysis",
        badge: "READ-ONLY",
        lines: [
            TUIConsoleLine("A deliberately long diagnostic sentence that must wrap without crossing the terminal edge."),
            TUIConsoleLine("PLAN  \(renderer.compactPath("/Users/minh/Library/Application Support/KeepItClean/Plans/12345678.cleanup.json", maxWidth: 42))"),
        ],
        footer: TUIConsoleLine("Nothing moved", tone: .muted)
    )

    #expect(card.contains("KEEP IT CLEAN · ANALYSIS"))
    #expect(card.contains("~/…/Plans/"))
    for line in card.split(separator: "\n", omittingEmptySubsequences: false) {
        #expect(line.count <= 60)
    }
}

@Test func doctorAndHistoryUseTheSameBoundedPresentation() {
    let renderer = TUIConsoleRenderer(
        width: 76,
        usesANSI: false,
        homePath: "/Users/minh"
    )
    let doctor = HumanOutput.renderDoctor([
        DoctorCheck(id: "macos", status: "ok", message: "macOS is supported."),
        DoctorCheck(
            id: "native-execution",
            status: "blocked",
            message: "Descriptor-bound execution is unavailable, so this capability remains protected."
        ),
        DoctorCheck(id: "system-helper", status: "optional", message: "Install only when system cleanup is needed."),
    ], renderer: renderer)

    #expect(doctor.contains("KEEP IT CLEAN · DOCTOR"))
    #expect(doctor.contains("[READY]"))
    #expect(doctor.contains("✓ macOS"))
    #expect(doctor.contains("◇ Native execution"))
    #expect(doctor.contains("! System helper"))

    let identity = FileIdentity(
        device: 1,
        inode: 2,
        ownerID: 501,
        fileKind: .regularFile,
        logicalBytes: 1_024,
        allocatedBytes: 1_024,
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let operation = OperationRecord(
        id: UUID(uuidString: "CC2B52EF-739E-44B2-808F-ABA3377BDA22")!,
        kind: .trash,
        state: .completed,
        completedAt: Date(),
        items: (0..<15).map { index in
            OperationItem(
                candidateID: "fixture-\(index)",
                originalPath: "/Users/minh/Desktop/project/very-long-project-name-\(index)/node_modules",
                identity: identity,
                status: .movedToTrash
            )
        }
    )
    let history = HumanOutput.renderOperation(operation, renderer: renderer)

    #expect(history.contains("KEEP IT CLEAN · OPERATION"))
    #expect(history.contains("[COMPLETED]"))
    #expect(history.contains("✓ Trashed"))
    #expect(history.contains("… 3 more items"))
    #expect(history.contains("Undo available · keep undo CC2B52EF"))
    for line in (doctor + history).split(separator: "\n", omittingEmptySubsequences: false) {
        #expect(line.count <= 76)
    }
}

@Test func readOnlyScanSummaryUsesTheSharedCardAndNeverPrintsAnAbsoluteHome() {
    let renderer = TUIConsoleRenderer(width: 84, usesANSI: false, homePath: "/Users/minh")
    let report = ScanReport(durationSeconds: 0.1, candidates: [])
    let plan = CleanupPlan(hostID: "fixture", items: [])
    let planned = PlannedScan(
        report: report,
        plan: plan,
        planURL: URL(fileURLWithPath: "/Users/minh/Library/Application Support/KeepItClean/Plans/fixture.cleanup.json")
    )

    let output = HumanOutput.renderScan(
        planned,
        label: "Analysis complete (read-only)",
        renderer: renderer
    )
    #expect(output.contains("KEEP IT CLEAN · ANALYSIS"))
    #expect(output.contains("[READ-ONLY]"))
    #expect(output.contains("Nothing moved"))
    #expect(!output.contains("/Users/minh/"))
}
