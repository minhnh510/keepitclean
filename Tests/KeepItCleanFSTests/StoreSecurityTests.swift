import Foundation
import KeepItCleanCore
import Testing
@testable import KeepItCleanFS

private struct StoreFixture {
    let root: URL
    let marker: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("keepitclean-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        marker = root.appendingPathComponent(".keepitclean-store-fixture")
        try Data("fixture".utf8).write(to: marker)
    }

    func remove() throws {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        guard root.standardizedFileURL.path.hasPrefix(temporary + "/"),
              FileManager.default.fileExists(atPath: marker.path)
        else {
            throw KeepItCleanError.protectedPath(root.path)
        }
        try FileManager.default.removeItem(at: root)
    }
}

@Test func planStoreRejectsSymbolicLinkDirectory() throws {
    let fixture = try StoreFixture()
    defer { try? fixture.remove() }
    let real = fixture.root.appendingPathComponent("real-plans", isDirectory: true)
    let linked = fixture.root.appendingPathComponent("linked-plans", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)

    #expect(throws: (any Error).self) {
        _ = try JSONPlanStore(baseDirectory: linked).save(
            plan: CleanupPlan(hostID: "fixture-host", items: [])
        )
    }
    #expect((try FileManager.default.contentsOfDirectory(atPath: real.path)).isEmpty)
}

@Test func operationStoreRejectsSymbolicLinkDirectory() throws {
    let fixture = try StoreFixture()
    defer { try? fixture.remove() }
    let real = fixture.root.appendingPathComponent("real-logs", isDirectory: true)
    let linked = fixture.root.appendingPathComponent("linked-logs", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
    let store = JSONLOperationStore(logURL: linked.appendingPathComponent("operations.jsonl"))

    #expect(throws: (any Error).self) {
        try store.append(operation: OperationRecord(kind: .trash, state: .running))
    }
    #expect((try FileManager.default.contentsOfDirectory(atPath: real.path)).isEmpty)
}

@Test func storesDoNotCreateThroughSymbolicLinkAncestors() throws {
    let fixture = try StoreFixture()
    defer { try? fixture.remove() }
    let real = fixture.root.appendingPathComponent("redirect-target", isDirectory: true)
    let linked = fixture.root.appendingPathComponent("redirect", isDirectory: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)

    let planStore = JSONPlanStore(
        baseDirectory: linked.appendingPathComponent("KeepItClean/Plans", isDirectory: true)
    )
    #expect(throws: (any Error).self) {
        _ = try planStore.save(plan: CleanupPlan(hostID: "fixture-host", items: []))
    }

    let operationStore = JSONLOperationStore(
        logURL: linked.appendingPathComponent("KeepItClean/operations.jsonl")
    )
    #expect(throws: (any Error).self) {
        try operationStore.append(operation: OperationRecord(kind: .trash, state: .running))
    }
    #expect((try FileManager.default.contentsOfDirectory(atPath: real.path)).isEmpty)
}

@Test func planStoreRejectsPermissionsWeakenedAfterSave() throws {
    let fixture = try StoreFixture()
    defer { try? fixture.remove() }
    let directory = fixture.root.appendingPathComponent("plans", isDirectory: true)
    let store = JSONPlanStore(baseDirectory: directory)
    let plan = CleanupPlan(hostID: "fixture-host", items: [])
    let url = try store.save(plan: plan)
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)

    #expect(throws: (any Error).self) {
        _ = try store.loadPlan(at: url)
    }
}

@Test func planStoreNeverOverwritesAnExistingPlanID() throws {
    let fixture = try StoreFixture()
    defer { try? fixture.remove() }
    let store = JSONPlanStore(
        baseDirectory: fixture.root.appendingPathComponent("plans", isDirectory: true)
    )
    let original = CleanupPlan(hostID: "fixture-host", items: [])
    let url = try store.save(plan: original)
    var replacement = original
    replacement.expiresAt = original.expiresAt.addingTimeInterval(3_600)

    #expect(throws: (any Error).self) {
        _ = try store.save(plan: replacement)
    }
    #expect(try store.loadPlan(at: url) == original)
}

@Test func operationStoreRejectsOneRecordLargerThanItsReadLimit() throws {
    let fixture = try StoreFixture()
    defer { try? fixture.remove() }
    let log = fixture.root.appendingPathComponent("history/operations.jsonl")
    let store = JSONLOperationStore(
        logURL: log,
        maximumRecords: 10,
        maximumBytes: 1_024
    )
    let identity = FileIdentity(
        device: 1,
        inode: 2,
        ownerID: 3,
        fileKind: .regularFile,
        logicalBytes: 1,
        allocatedBytes: 1,
        modifiedAt: Date(timeIntervalSince1970: 1)
    )
    let oversized = OperationRecord(
        kind: .trash,
        state: .running,
        items: [OperationItem(
            candidateID: "fixture",
            originalPath: "/fixture",
            identity: identity,
            status: .failed,
            message: String(repeating: "x", count: 2_048)
        )]
    )

    #expect(throws: KeepItCleanError.self) {
        try store.append(operation: oversized)
    }
    #expect(!FileManager.default.fileExists(atPath: log.path))
    #expect(try store.operations(limit: 10).isEmpty)
}
