import Foundation
import KeepItCleanCore
import KeepItCleanFS
import KeepItCleanRules
import Testing
@testable import KeepItCleanCLI

private struct MarkerGuardedHome {
    let url: URL
    let marker: URL

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("keepitclean-cli-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let marker = url.appendingPathComponent(".keepitclean-test-home")
        try Data("fixture".utf8).write(to: marker)
        self.url = url
        self.marker = marker
    }

    func remove() throws {
        guard url.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path + "/"),
              FileManager.default.fileExists(atPath: marker.path)
        else {
            throw KeepItCleanError.protectedPath(url.path)
        }
        try FileManager.default.removeItem(at: url)
    }
}

private func fixtureService(home: MarkerGuardedHome) -> ProductionCommandService {
    ProductionCommandService(
        homePath: home.url.path,
        planDirectory: home.url.appendingPathComponent("state/Plans", isDirectory: true),
        operationLogURL: home.url.appendingPathComponent("state/operations.jsonl")
    )
}

private func fixtureService(
    home: MarkerGuardedHome,
    processSnapshotProvider: any ProcessSnapshotProviding,
    nativeRunner: any NativeActionRunning
) -> ProductionCommandService {
    ProductionCommandService(
        homePath: home.url.path,
        planDirectory: home.url.appendingPathComponent("state/Plans", isDirectory: true),
        operationLogURL: home.url.appendingPathComponent("state/operations.jsonl"),
        processSnapshotProvider: processSnapshotProvider,
        nativeRunner: nativeRunner
    )
}

private final class SequencedProcessSnapshotProvider: ProcessSnapshotProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [[ProcessRecord]]

    init(_ snapshots: [[ProcessRecord]]) {
        self.snapshots = snapshots
    }

    func snapshot() throws -> [ProcessRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshot = snapshots.first else { return [] }
        if snapshots.count > 1 {
            snapshots.removeFirst()
        }
        return snapshot
    }
}

private final class RecordingNativeRunner: NativeActionRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var launchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func run(plan: NativeActionPlan, confirmationToken: String) throws -> OperationRecord {
        lock.lock()
        count += 1
        lock.unlock()
        return OperationRecord(
            planID: plan.id,
            kind: .native,
            state: .completed,
            completedAt: Date(),
            items: []
        )
    }
}

private struct FixtureHost: HostIdentifying {
    let id: String

    func currentHostID() -> String { id }
}

private final class RecordingOperationStore: OperationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let rejectAppends: Bool
    private var storage: [OperationRecord] = []

    init(rejectAppends: Bool = false) {
        self.rejectAppends = rejectAppends
    }

    var records: [OperationRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(operation: OperationRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !rejectAppends else {
            throw KeepItCleanError.io("fixture journal rejected append")
        }
        storage.append(operation)
    }

    func operation(id: UUID) throws -> OperationRecord {
        lock.lock()
        defer { lock.unlock() }
        guard let value = storage.last(where: { $0.id == id }) else {
            throw KeepItCleanError.operationNotFound(id.uuidString)
        }
        return value
    }

    func operations(limit: Int) throws -> [OperationRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Array(storage.suffix(limit))
    }
}

private let unrelatedProcessSnapshot = [
    ProcessRecord(executable: "/sbin/launchd", arguments: "/sbin/launchd"),
]

private struct RecordedTrashFixture {
    let service: ProductionCommandService
    let plan: CleanupPlan
    let operation: OperationRecord
    let originalURL: URL
    let trashURL: URL
    let operationStore: JSONLOperationStore
}

private func recordedTrashFixture(
    home: MarkerGuardedHome,
    interrupted: Bool = false
) throws -> RecordedTrashFixture {
    let fixtureHomePath = home.url.standardizedFileURL.path
    let canonicalHome = URL(fileURLWithPath: fixtureHomePath.hasPrefix("/var/")
        ? "/private\(fixtureHomePath)"
        : fixtureHomePath)
    let originalDirectory = canonicalHome.appendingPathComponent("Caches", isDirectory: true)
    let originalURL = originalDirectory.appendingPathComponent("artifact.bin")
    let trashDirectory = canonicalHome.appendingPathComponent(".Trash", isDirectory: true)
    let operationID = UUID()
    let trashURL = trashDirectory.appendingPathComponent(
        ".keepitclean-\(operationID.uuidString.lowercased())-0"
    )
    try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: trashDirectory.path
    )
    try Data("fixture artifact".utf8).write(to: originalURL)

    let identity = try LocalFileSystemReader().identity(at: originalURL.path)
    let candidate = Candidate(
        ruleID: "fixture.cache",
        category: "Fixture",
        path: originalURL.path,
        displayName: originalURL.lastPathComponent,
        evidence: "CLI provenance fixture.",
        identity: identity,
        actionKind: .trash,
        risk: .low,
        rebuildCost: .low,
        activeState: .inactive,
        defaultSelected: true
    )
    let now = Date()
    let plan = CleanupPlan(
        createdAt: now.addingTimeInterval(-5),
        expiresAt: now.addingTimeInterval(300),
        hostID: DefaultHostIdentifier().currentHostID(),
        items: [CleanupPlanItem(candidate: candidate, selected: true)]
    )
    let planDirectory = home.url.appendingPathComponent("state/Plans", isDirectory: true)
    _ = try JSONPlanStore(baseDirectory: planDirectory).save(plan: plan)

    try FileManager.default.moveItem(at: originalURL, to: trashURL)
    let operation = OperationRecord(
        id: operationID,
        planID: plan.id,
        kind: .trash,
        state: interrupted ? .running : .completed,
        startedAt: now,
        completedAt: interrupted ? nil : now,
        items: [OperationItem(
            candidateID: candidate.id,
            originalPath: originalURL.path,
            resultingTrashPath: trashURL.path,
            identity: identity,
            status: interrupted ? .pending : .movedToTrash
        )]
    )
    let operationStore = JSONLOperationStore(
        logURL: home.url.appendingPathComponent("state/operations.jsonl")
    )
    try operationStore.append(operation: operation)
    return RecordedTrashFixture(
        service: fixtureService(home: home),
        plan: plan,
        operation: operation,
        originalURL: originalURL,
        trashURL: trashURL,
        operationStore: operationStore
    )
}

private func tamperStoredPlan(_ plan: CleanupPlan, home: MarkerGuardedHome) throws {
    let url = home.url
        .appendingPathComponent("state/Plans", isDirectory: true)
        .appendingPathComponent("\(plan.id.uuidString).cleanup.json")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(plan).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

@Test func productionRuntimeIsComposedWithRules() throws {
    let home = try MarkerGuardedHome()
    defer { try? home.remove() }

    #expect(!fixtureService(home: home).ruleDescriptors().isEmpty)
}

@Test func tuiReviewDerivesANewImmutablePlanID() {
    let candidate = Candidate(
        ruleID: "fixture.cache",
        category: "Fixture",
        path: "/tmp/fixture-cache",
        displayName: "fixture-cache",
        evidence: "Fixture candidate.",
        identity: nil,
        actionKind: .trash,
        risk: .low,
        rebuildCost: .low,
        activeState: .inactive,
        defaultSelected: false
    )
    let original = CleanupPlan(
        hostID: "fixture-host",
        items: [CleanupPlanItem(candidate: candidate, selected: false)]
    )
    let reviewed = TUIAdapter.plan(original, selecting: [candidate.id])

    #expect(reviewed.id != original.id)
    #expect(reviewed.hostID == original.hostID)
    #expect(reviewed.items.first?.selected == true)
    #expect(original.items.first?.selected == false)
}

@Test func tuiDeepPhaseUsesExactOrParentScopedRootsAndRevalidatesSelection() throws {
    let exact = Candidate(
        ruleID: "lldb.module-cache",
        category: "LLDB",
        path: "/tmp/home/.lldb/module_cache",
        displayName: "module_cache",
        evidence: "Exact cache leaf.",
        identity: nil,
        actionKind: .trash,
        risk: .low,
        rebuildCost: .medium,
        activeState: .inactive,
        defaultSelected: false
    )
    let project = Candidate(
        ruleID: "project.artifacts",
        category: "Projects",
        path: "/tmp/workspace/App/node_modules",
        displayName: "node_modules",
        evidence: "Project-owned artifact.",
        identity: nil,
        actionKind: .trash,
        risk: .review,
        rebuildCost: .high,
        activeState: .inactive,
        defaultSelected: false
    )
    let report = ScanReport(durationSeconds: 0, candidates: [exact, project])
    let roots = try TUIAdapter.deepScanRoots(
        report: report,
        selecting: [exact.id, project.id]
    )
    #expect(roots == [exact.path, "/tmp/workspace/App"].sorted())

    let deep = try TUIAdapter.deepReviewReport(
        report,
        retaining: [exact.id, project.id]
    )
    #expect(deep.candidates.allSatisfy { $0.defaultSelected })
    #expect(throws: KeepItCleanError.self) {
        _ = try TUIAdapter.deepReviewReport(report, retaining: ["missing"])
    }
}

@Test func forgedUnknownRuleCannotAuthorizeTrashMutation() async throws {
    let home = try MarkerGuardedHome()
    defer { try? home.remove() }
    let source = home.url.appendingPathComponent("arbitrary-user-file.txt")
    try Data("preserve me".utf8).write(to: source)
    let identity = try LocalFileSystemReader().identity(at: source.path)
    let candidate = Candidate(
        ruleID: "forged.unknown-rule",
        category: "Forged",
        path: source.path,
        displayName: source.lastPathComponent,
        evidence: "Untrusted fixture plan.",
        identity: identity,
        actionKind: .trash,
        risk: .low,
        rebuildCost: .low,
        activeState: .inactive,
        defaultSelected: true
    )
    let plan = CleanupPlan(
        hostID: DefaultHostIdentifier().currentHostID(),
        items: [CleanupPlanItem(candidate: candidate, selected: true)]
    )

    await #expect(throws: (any Error).self) {
        _ = try await fixtureService(home: home).applyTrash(plan: plan)
    }
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(try fixtureService(home: home).history(limit: 10).isEmpty)
}

@Test func productionRuntimeRejectsPlanOutsidePrivateStore() throws {
    let home = try MarkerGuardedHome()
    defer { try? home.remove() }
    let external = home.url.appendingPathComponent("external.cleanup.json")
    let plan = CleanupPlan(hostID: DefaultHostIdentifier().currentHostID(), items: [])
    try JSONEncoder().encode(plan).write(to: external)

    #expect(throws: (any Error).self) {
        _ = try fixtureService(home: home).loadPlan(reference: external.path)
    }
    #expect(FileManager.default.fileExists(atPath: external.path))
}

@Test func applyFailsWhenExternalHardlinkChangesReviewedReclaimEstimate() async throws {
    let home = try MarkerGuardedHome()
    defer { try? home.remove() }
    let cache = home.url.appendingPathComponent(".lldb/module_cache", isDirectory: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let payload = cache.appendingPathComponent("module.pcm")
    try Data(repeating: 0x43, count: 8_192).write(to: payload)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-10 * 86_400)],
        ofItemAtPath: cache.path
    )

    let service = fixtureService(
        home: home,
        processSnapshotProvider: SequencedProcessSnapshotProvider([unrelatedProcessSnapshot]),
        nativeRunner: RecordingNativeRunner()
    )
    let scanned = try await service.scan(roots: [home.url.path], deep: true)
    var plan = scanned.plan
    let index = try #require(plan.items.firstIndex {
        $0.candidate.ruleID == "lldb.module-cache" && $0.candidate.path == cache.path
    })
    #expect(plan.items[index].candidate.reclaimableBytes > 0)
    plan.items[index].selected = true

    let outside = home.url.appendingPathComponent("outside-hardlink.pcm")
    try FileManager.default.linkItem(at: payload, to: outside)
    let freshUsage = try LocalFileSystemReader().usage(at: cache.path)
    #expect(freshUsage.reclaimableBytes < plan.items[index].candidate.reclaimableBytes)

    await #expect(throws: KeepItCleanError.self) {
        _ = try await service.applyTrash(plan: plan)
    }
    #expect(FileManager.default.fileExists(atPath: payload.path))
    #expect(FileManager.default.fileExists(atPath: outside.path))
    #expect(try service.history(limit: 10).isEmpty)
}

@Test func statefulNativePlansFailClosedWhenOwningToolsAreActive() throws {
    let scenarios: [(actionID: String, active: ProcessRecord)] = [
        (
            "cocoapods.cache-clean-all",
            ProcessRecord(executable: "/opt/homebrew/bin/pod", arguments: "pod install")
        ),
        (
            "android.avd-delete.Pixel_9",
            ProcessRecord(executable: "/sdk/emulator/emulator", arguments: "emulator -avd Pixel_9")
        ),
        (
            "vscode.extension-uninstall.publisher.extension",
            ProcessRecord(
                executable: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
                arguments: "Visual Studio Code.app"
            )
        ),
    ]

    for scenario in scenarios {
        let home = try MarkerGuardedHome()
        defer { try? home.remove() }
        let runner = RecordingNativeRunner()
        let service = fixtureService(
            home: home,
            processSnapshotProvider: SequencedProcessSnapshotProvider([[scenario.active]]),
            nativeRunner: runner
        )

        #expect(throws: KeepItCleanError.self) {
            _ = try service.makeNativeActionPlan(actionID: scenario.actionID)
        }
        #expect(runner.launchCount == 0)
    }
}

@Test func statefulNativeRunRechecksActivityAndNeverCallsRunnerWhenStateChanges() throws {
    let scenarios: [(actionID: String, active: ProcessRecord)] = [
        (
            "cocoapods.cache-clean-all",
            ProcessRecord(executable: "/usr/local/bin/pod", arguments: "pod update")
        ),
        (
            "android.avd-delete.Pixel_9",
            ProcessRecord(executable: "/sdk/emulator/emulator", arguments: "emulator -avd Pixel_9")
        ),
        (
            "vscode.extension-uninstall.publisher.extension",
            ProcessRecord(executable: "/usr/local/bin/code", arguments: "code --verbose")
        ),
    ]

    for scenario in scenarios {
        let home = try MarkerGuardedHome()
        defer { try? home.remove() }
        let runner = RecordingNativeRunner()
        let provider = SequencedProcessSnapshotProvider([unrelatedProcessSnapshot, [scenario.active]])
        let service = fixtureService(
            home: home,
            processSnapshotProvider: provider,
            nativeRunner: runner
        )
        let (plan, _) = try service.makeNativeActionPlan(actionID: scenario.actionID)

        #expect(throws: KeepItCleanError.self, "\(scenario.actionID) must recheck activity") {
            _ = try service.runNativeAction(plan: plan, confirmationToken: plan.confirmationToken)
        }
        #expect(runner.launchCount == 0, "\(scenario.actionID) reached the fake runner")
    }
}

@Test func stopActionsAllowActiveStateButFailClosedWhenObservationBecomesUnknown() throws {
    let scenarios: [(actionID: String, active: ProcessRecord)] = [
        (
            "gradle.stop",
            ProcessRecord(executable: "/usr/local/bin/gradle", arguments: "gradle --daemon")
        ),
        (
            "colima.stop.default",
            ProcessRecord(executable: "/opt/homebrew/bin/colima", arguments: "colima start --profile default")
        ),
    ]

    for scenario in scenarios {
        let home = try MarkerGuardedHome()
        defer { try? home.remove() }
        let runner = RecordingNativeRunner()
        let provider = SequencedProcessSnapshotProvider([[scenario.active], []])
        let service = fixtureService(
            home: home,
            processSnapshotProvider: provider,
            nativeRunner: runner
        )
        let (plan, _) = try service.makeNativeActionPlan(actionID: scenario.actionID)

        #expect(throws: KeepItCleanError.self) {
            _ = try service.runNativeAction(plan: plan, confirmationToken: plan.confirmationToken)
        }
        #expect(runner.launchCount == 0)
    }
}

@Test func stopActionsMayRunThroughFakeRunnerWhileRelevantStateIsActive() throws {
    let scenarios: [(actionID: String, active: ProcessRecord)] = [
        (
            "gradle.stop",
            ProcessRecord(executable: "/usr/local/bin/gradle", arguments: "gradle --daemon")
        ),
        (
            "colima.stop.default",
            ProcessRecord(executable: "/opt/homebrew/bin/colima", arguments: "colima start --profile default")
        ),
    ]

    for scenario in scenarios {
        let home = try MarkerGuardedHome()
        defer { try? home.remove() }
        let runner = RecordingNativeRunner()
        let service = fixtureService(
            home: home,
            processSnapshotProvider: SequencedProcessSnapshotProvider([[scenario.active]]),
            nativeRunner: runner
        )
        let (plan, _) = try service.makeNativeActionPlan(actionID: scenario.actionID)

        _ = try service.runNativeAction(plan: plan, confirmationToken: plan.confirmationToken)
        #expect(runner.launchCount == 1)
    }
}

@Test func avdDeleteIgnoresADBAndOtherIdentifiedAVDsButBlocksUnidentifiedEmulators() throws {
    let allowedSnapshots: [[ProcessRecord]] = [
        [ProcessRecord(executable: "/sdk/platform-tools/adb", arguments: "adb devices")],
        [ProcessRecord(executable: "/sdk/emulator/emulator", arguments: "emulator -avd Other_AVD")],
    ]

    for snapshot in allowedSnapshots {
        let home = try MarkerGuardedHome()
        defer { try? home.remove() }
        let runner = RecordingNativeRunner()
        let service = fixtureService(
            home: home,
            processSnapshotProvider: SequencedProcessSnapshotProvider([snapshot]),
            nativeRunner: runner
        )
        let (plan, _) = try service.makeNativeActionPlan(actionID: "android.avd-delete.Pixel_9")

        _ = try service.runNativeAction(plan: plan, confirmationToken: plan.confirmationToken)
        #expect(runner.launchCount == 1)
    }

    let home = try MarkerGuardedHome()
    defer { try? home.remove() }
    let runner = RecordingNativeRunner()
    let service = fixtureService(
        home: home,
        processSnapshotProvider: SequencedProcessSnapshotProvider([[
            ProcessRecord(executable: "/sdk/emulator/emulator", arguments: "emulator -gpu host"),
        ]]),
        nativeRunner: runner
    )
    #expect(throws: KeepItCleanError.self) {
        _ = try service.makeNativeActionPlan(actionID: "android.avd-delete.Pixel_9")
    }
    #expect(runner.launchCount == 0)
}

@Test func exactReadOnlyAndDockerDaemonNativeActionsKeepTheirIntentionalExceptions() throws {
    let scenarios: [(actionID: String, snapshots: [[ProcessRecord]])] = [
        (
            "cocoapods.cache-list",
            [[ProcessRecord(executable: "/opt/homebrew/bin/pod", arguments: "pod install")]]
        ),
        ("docker.image-prune", [[]]),
    ]

    for scenario in scenarios {
        let home = try MarkerGuardedHome()
        defer { try? home.remove() }
        let runner = RecordingNativeRunner()
        let service = fixtureService(
            home: home,
            processSnapshotProvider: SequencedProcessSnapshotProvider(scenario.snapshots),
            nativeRunner: runner
        )
        let (plan, _) = try service.makeNativeActionPlan(actionID: scenario.actionID)

        _ = try service.runNativeAction(plan: plan, confirmationToken: plan.confirmationToken)
        #expect(runner.launchCount == 1)
    }
}

@Test func productionNativeRunnerFailsClosedWithoutDescriptorBoundExec() throws {
    let operationStore = RecordingOperationStore()
    let host = FixtureHost(id: "fixture-host")
    let plan = NativeActionPlan(
        descriptor: NativeActionCatalog.dockerDiskUsage.descriptor,
        hostID: host.currentHostID(),
        confirmationToken: "INSPECT DOCKER"
    )
    let runner = SystemNativeActionRunner(
        operationStore: operationStore,
        host: host
    )

    #expect(throws: KeepItCleanError.self) {
        _ = try runner.run(plan: plan, confirmationToken: plan.confirmationToken)
    }
    #expect(operationStore.records.isEmpty)
}

@Test func undoRecoversInterruptedTrashApplyOnlyAfterPrivatePlanProvenanceValidation() throws {
    let home = try MarkerGuardedHome()
    defer { try? home.remove() }
    let fixture = try recordedTrashFixture(home: home, interrupted: true)

    let undone = try fixture.service.undo(operationID: fixture.operation.id)
    let recovered = try fixture.operationStore.operation(id: fixture.operation.id)

    #expect(recovered.kind == .trash)
    #expect(recovered.state == .completed)
    #expect(recovered.completedAt != nil)
    #expect(recovered.items.first?.status == .movedToTrash)
    #expect(undone.kind == .undo)
    #expect(undone.state == .completed)
    #expect(FileManager.default.fileExists(atPath: fixture.originalURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.trashURL.path))
}

@Test func finalizeRecoversInterruptedTrashApplyBeforeCapturingItsExactItem() throws {
    let home = try MarkerGuardedHome()
    defer { try? home.remove() }
    let fixture = try recordedTrashFixture(home: home, interrupted: true)
    let token = FileMutationGateway.finalizeToken(for: fixture.operation.id)

    let finalized = try fixture.service.finalize(
        operationID: fixture.operation.id,
        confirmationToken: token
    )
    let recovered = try fixture.operationStore.operation(id: fixture.operation.id)

    #expect(recovered.state == .completed)
    #expect(recovered.items.first?.status == .movedToTrash)
    #expect(finalized.kind == .finalize)
    #expect(finalized.state == .completed)
    #expect(!FileManager.default.fileExists(atPath: fixture.originalURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.trashURL.path))
}

@Test func interruptedTrashApplyRecoveryRejectsForgedPlanItemBeforeFilesystemReconciliation() throws {
    let home = try MarkerGuardedHome()
    defer { try? home.remove() }
    let fixture = try recordedTrashFixture(home: home, interrupted: true)
    var forged = fixture.operation
    forged.items[0].candidateID = "forged-candidate"
    try fixture.operationStore.append(operation: forged)

    #expect(throws: KeepItCleanError.self) {
        _ = try fixture.service.undo(operationID: forged.id)
    }
    #expect(try fixture.operationStore.operation(id: forged.id) == forged)
    #expect(!FileManager.default.fileExists(atPath: fixture.originalURL.path))
    #expect(FileManager.default.fileExists(atPath: fixture.trashURL.path))
}

@Test func reviewedTrashOperationProvenanceAllowsLegitimateRecordToReachGateway() throws {
    let home = try MarkerGuardedHome()
    defer { try? home.remove() }
    let fixture = try recordedTrashFixture(home: home)

    let result = try fixture.service.undo(operationID: fixture.operation.id)

    #expect(result.kind == .undo)
    #expect(result.planID == fixture.plan.id)
}

@Test func trashOperationProvenanceRejectsDuplicateAndUnknownJournalItems() throws {
    do {
        let home = try MarkerGuardedHome()
        defer { try? home.remove() }
        let fixture = try recordedTrashFixture(home: home)
        var forged = fixture.operation
        forged.items.append(forged.items[0])
        try fixture.operationStore.append(operation: forged)

        #expect(throws: KeepItCleanError.self) {
            _ = try fixture.service.undo(operationID: forged.id)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.trashURL.path))
    }

    do {
        let home = try MarkerGuardedHome()
        defer { try? home.remove() }
        let fixture = try recordedTrashFixture(home: home)
        var forged = fixture.operation
        forged.items[0].candidateID = "unknown-candidate"
        try fixture.operationStore.append(operation: forged)

        #expect(throws: KeepItCleanError.self) {
            _ = try fixture.service.undo(operationID: forged.id)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.trashURL.path))
    }
}

@Test func finalizeRequiresPlanIDAndOperationInsideReviewWindow() throws {
    do {
        let home = try MarkerGuardedHome()
        defer { try? home.remove() }
        let fixture = try recordedTrashFixture(home: home)
        var forged = fixture.operation
        forged.planID = nil
        try fixture.operationStore.append(operation: forged)
        let token = FileMutationGateway.finalizeToken(for: forged.id)

        #expect(throws: KeepItCleanError.self) {
            _ = try fixture.service.finalize(operationID: forged.id, confirmationToken: token)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.trashURL.path))
    }

    do {
        let home = try MarkerGuardedHome()
        defer { try? home.remove() }
        let fixture = try recordedTrashFixture(home: home)
        var forged = fixture.operation
        forged.startedAt = fixture.plan.createdAt.addingTimeInterval(-1)
        try fixture.operationStore.append(operation: forged)
        let token = FileMutationGateway.finalizeToken(for: forged.id)

        #expect(throws: KeepItCleanError.self) {
            _ = try fixture.service.finalize(operationID: forged.id, confirmationToken: token)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.trashURL.path))
    }
}

@Test func trashOperationProvenanceRejectsSchemaHostCompletionAndIneligiblePlan() throws {
    do {
        let home = try MarkerGuardedHome()
        defer { try? home.remove() }
        let fixture = try recordedTrashFixture(home: home)
        var forged = fixture.operation
        forged.schemaVersion = keepItCleanSchemaVersion + 1
        try fixture.operationStore.append(operation: forged)

        #expect(throws: KeepItCleanError.self) {
            _ = try fixture.service.undo(operationID: forged.id)
        }
    }

    do {
        let home = try MarkerGuardedHome()
        defer { try? home.remove() }
        let fixture = try recordedTrashFixture(home: home)
        var forged = fixture.operation
        forged.completedAt = nil
        try fixture.operationStore.append(operation: forged)

        #expect(throws: KeepItCleanError.self) {
            _ = try fixture.service.undo(operationID: forged.id)
        }
    }

    do {
        let home = try MarkerGuardedHome()
        defer { try? home.remove() }
        let fixture = try recordedTrashFixture(home: home)
        var forgedPlan = fixture.plan
        forgedPlan.hostID = "different-host"
        try tamperStoredPlan(forgedPlan, home: home)

        #expect(throws: KeepItCleanError.self) {
            _ = try fixture.service.undo(operationID: fixture.operation.id)
        }
    }

    do {
        let home = try MarkerGuardedHome()
        defer { try? home.remove() }
        let fixture = try recordedTrashFixture(home: home)
        var forgedPlan = fixture.plan
        forgedPlan.items[0].candidate.actionKind = .reportOnly
        try tamperStoredPlan(forgedPlan, home: home)

        #expect(throws: KeepItCleanError.self) {
            _ = try fixture.service.undo(operationID: fixture.operation.id)
        }
    }
}

@Test func trashOperationProvenanceRejectsSubsetAndDuplicateTrashDestination() throws {
    do {
        let home = try MarkerGuardedHome()
        defer { try? home.remove() }
        let fixture = try recordedTrashFixture(home: home)
        var expandedPlan = fixture.plan
        var second = expandedPlan.items[0].candidate
        second.id += ":second"
        second.path += ".second"
        expandedPlan.items.append(CleanupPlanItem(candidate: second, selected: true))
        try tamperStoredPlan(expandedPlan, home: home)

        #expect(throws: KeepItCleanError.self) {
            _ = try fixture.service.undo(operationID: fixture.operation.id)
        }
    }

    do {
        let home = try MarkerGuardedHome()
        defer { try? home.remove() }
        let fixture = try recordedTrashFixture(home: home)
        var expandedPlan = fixture.plan
        var secondCandidate = expandedPlan.items[0].candidate
        secondCandidate.id += ":second"
        secondCandidate.path += ".second"
        expandedPlan.items.append(CleanupPlanItem(candidate: secondCandidate, selected: true))
        try tamperStoredPlan(expandedPlan, home: home)

        var forged = fixture.operation
        var secondOperationItem = forged.items[0]
        secondOperationItem.candidateID = secondCandidate.id
        secondOperationItem.originalPath = secondCandidate.path
        forged.items.append(secondOperationItem)
        try fixture.operationStore.append(operation: forged)

        #expect(throws: KeepItCleanError.self) {
            _ = try fixture.service.undo(operationID: forged.id)
        }
    }
}
