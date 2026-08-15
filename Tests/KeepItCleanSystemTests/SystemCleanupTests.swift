import Darwin
import Foundation
import Testing
@testable import KeepItCleanCore
@testable import KeepItCleanFS
@testable import KeepItCleanSystem

private let markerName = ".keepitclean-system-test-fixture"
private let markerContents = "KEEPITCLEAN_SYSTEM_TEST_FIXTURE"

private func makeFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepitclean-system-fixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    try Data(markerContents.utf8).write(to: root.appendingPathComponent(markerName))
    return root
}

private func removeFixture(_ root: URL) {
    let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
    let marker = root.appendingPathComponent(markerName)
    guard root.standardizedFileURL.path.hasPrefix(temporary + "/"),
          root.lastPathComponent.hasPrefix("keepitclean-system-fixture-"),
          (try? String(contentsOf: marker, encoding: .utf8)) == markerContents
    else { return }
    try? FileManager.default.removeItem(at: root)
}

private func writeOldFile(_ url: URL, ageDays: Int, now: Date) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data(repeating: 0x4B, count: 8_192).write(to: url)
    try FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(TimeInterval(-ageDays * 86_400))],
        ofItemAtPath: url.path
    )
}

private func makeEngine(root: URL) -> SystemCleanupEngine {
    let roots = SystemCacheRoots(
        libraryCaches: root.appendingPathComponent("LibraryCaches").path,
        diagnosticReports: root.appendingPathComponent("DiagnosticReports").path,
        systemLogs: root.appendingPathComponent("SystemLogs").path
    )
    let reader = LocalFileSystemReader()
    return SystemCleanupEngine(
        scanner: SystemCacheScanner(
            fileSystem: reader,
            roots: roots,
            expectedOwnerID: getuid()
        ),
        store: SystemStateStore(
            baseDirectory: root.appendingPathComponent("State", isDirectory: true),
            ownerID: getuid()
        ),
        reader: reader
    )
}

@Test func systemScannerUsesExactLeavesRetentionAndProtectedAppleScope() throws {
    let root = try makeFixture()
    defer { removeFixture(root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let oldCache = root.appendingPathComponent("LibraryCaches/vendor/stale.cache")
    let recentCache = root.appendingPathComponent("LibraryCaches/vendor/recent.cache")
    let appleCache = root.appendingPathComponent("LibraryCaches/com.apple.SoftwareUpdate/stale.cache")
    let crash = root.appendingPathComponent("DiagnosticReports/tool.ips")
    let rotated = root.appendingPathComponent("SystemLogs/service.log.2")
    let liveLog = root.appendingPathComponent("SystemLogs/service.log")
    try writeOldFile(oldCache, ageDays: 8, now: now)
    try writeOldFile(recentCache, ageDays: 6, now: now)
    try writeOldFile(appleCache, ageDays: 30, now: now)
    try writeOldFile(crash, ageDays: 8, now: now)
    try writeOldFile(rotated, ageDays: 15, now: now)
    try writeOldFile(liveLog, ageDays: 30, now: now)

    let result = try makeEngine(root: root).scan(now: now)
    let paths = Set(result.plan.candidates.map(\.path))

    #expect(paths == Set([oldCache, crash, rotated].map {
        PathValidationPolicy.canonicalSystemAlias($0.path)
    }))
    #expect(result.plan.expiresAt == now.addingTimeInterval(15 * 60))
    #expect(result.plan.candidates.allSatisfy { $0.identity.fileKind == .regularFile })
}

@Test func systemCleanupQuarantinesThenUndoesWithoutPermanentDeletion() throws {
    let root = try makeFixture()
    defer { removeFixture(root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let target = root.appendingPathComponent("LibraryCaches/vendor/stale.tmp")
    try writeOldFile(target, ageDays: 8, now: now)
    let engine = makeEngine(root: root)
    let plan = try engine.scan(now: now).plan

    #expect(throws: KeepItCleanError.self) {
        _ = try engine.apply(planID: plan.id, confirmationToken: "wrong", now: now)
    }
    let operation = try engine.apply(
        planID: plan.id,
        confirmationToken: SystemCleanupEngine.applyToken(for: plan.id),
        now: now
    )
    #expect(operation.state == .quarantined)
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(FileManager.default.fileExists(atPath: operation.items[0].quarantinePath))

    let restored = try engine.undo(operationID: operation.id, now: now)
    #expect(restored.state == .restored)
    #expect(FileManager.default.fileExists(atPath: target.path))
    #expect(!FileManager.default.fileExists(atPath: operation.items[0].quarantinePath))
}

@Test func systemFinalizeRequiresExactTokenAndDeletesOnlyCapturedRegularLeaf() throws {
    let root = try makeFixture()
    defer { removeFixture(root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let target = root.appendingPathComponent("DiagnosticReports/old.crash")
    try writeOldFile(target, ageDays: 8, now: now)
    let engine = makeEngine(root: root)
    let plan = try engine.scan(now: now).plan
    let operation = try engine.apply(
        planID: plan.id,
        confirmationToken: SystemCleanupEngine.applyToken(for: plan.id),
        now: now
    )

    #expect(throws: KeepItCleanError.self) {
        _ = try engine.finalize(
            operationID: operation.id,
            confirmationToken: "wrong",
            now: now
        )
    }
    #expect(FileManager.default.fileExists(atPath: operation.items[0].quarantinePath))
    let finalized = try engine.finalize(
        operationID: operation.id,
        confirmationToken: SystemCleanupEngine.finalizeToken(for: operation.id),
        now: now
    )
    #expect(finalized.state == .finalized)
    #expect(!FileManager.default.fileExists(atPath: operation.items[0].quarantinePath))
}

@Test func systemRecoveryReconcilesCrashAfterQuarantineBeforeJournalUpdate() throws {
    let root = try makeFixture()
    defer { removeFixture(root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let target = root.appendingPathComponent("LibraryCaches/vendor/recover.cache")
    try writeOldFile(target, ageDays: 8, now: now)
    let engine = makeEngine(root: root)
    let store = SystemStateStore(
        baseDirectory: root.appendingPathComponent("State", isDirectory: true),
        ownerID: getuid()
    )
    let plan = try engine.scan(now: now).plan
    let candidate = try #require(plan.candidates.first)
    let operationID = UUID()
    let quarantine = try store.prepareQuarantine(operationID: operationID)
        .appendingPathComponent("000000-recover.cache")
    let running = SystemCleanupOperation(
        id: operationID,
        planID: plan.id,
        action: .apply,
        items: [SystemCleanupOperationItem(
            candidateID: candidate.id,
            originalPath: candidate.path,
            quarantinePath: quarantine.path,
            identity: candidate.identity
        )]
    )
    try store.save(operation: running)
    _ = try FDRelativeFileSystem().renameExclusively(
        fromAbsolutePath: candidate.path,
        expectedIdentity: candidate.identity,
        toAbsolutePath: quarantine.path
    )

    let recoveredAndRestored = try engine.undo(operationID: operationID, now: now)
    #expect(recoveredAndRestored.state == .restored)
    #expect(FileManager.default.fileExists(atPath: target.path))
    #expect(!FileManager.default.fileExists(atPath: quarantine.path))
}

@Test func systemRecoveryMarksInterruptedFinalizeOnlyInsidePrivateQuarantine() throws {
    let root = try makeFixture()
    defer { removeFixture(root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let target = root.appendingPathComponent("SystemLogs/recover.log.9")
    try writeOldFile(target, ageDays: 15, now: now)
    let engine = makeEngine(root: root)
    let store = SystemStateStore(
        baseDirectory: root.appendingPathComponent("State", isDirectory: true),
        ownerID: getuid()
    )
    let plan = try engine.scan(now: now).plan
    var operation = try engine.apply(
        planID: plan.id,
        confirmationToken: SystemCleanupEngine.applyToken(for: plan.id),
        now: now
    )
    operation.action = .finalize
    operation.state = .running
    operation.completedAt = nil
    operation.items[0].status = .pending
    try store.save(operation: operation)
    try FDRelativeFileSystem().removeCapturedItemRecursively(
        atAbsolutePath: operation.items[0].quarantinePath,
        expectedIdentity: operation.items[0].identity,
        privateParentAbsolutePath: store.quarantineDirectory
            .appendingPathComponent(operation.id.uuidString, isDirectory: true).path,
        ownerID: getuid(),
        maximumEntries: 1
    )

    let recovered = try engine.finalize(
        operationID: operation.id,
        confirmationToken: SystemCleanupEngine.finalizeToken(for: operation.id),
        now: now
    )
    #expect(recovered.state == .finalized)
    #expect(recovered.items[0].status == .finalized)
}
