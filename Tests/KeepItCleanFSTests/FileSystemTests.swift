import Darwin
import Foundation
import Testing
@testable import KeepItCleanCore
@testable import KeepItCleanFS

private let fixtureMarkerName = ".keepitclean-test-fixture"
private let fixtureMarkerContents = "KEEPITCLEAN_TEST_FIXTURE"

private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("keepitclean-fixture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(fixtureMarkerContents.utf8).write(
        to: root.appendingPathComponent(fixtureMarkerName)
    )
    return root
}

private func removeTemporaryRoot(_ root: URL) {
    let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL.path
    let normalizedRoot = root.standardizedFileURL.path
    let marker = root.appendingPathComponent(fixtureMarkerName)
    guard normalizedRoot.hasPrefix(temporaryDirectory + "/"),
          root.lastPathComponent.hasPrefix("keepitclean-fixture-"),
          (try? String(contentsOf: marker, encoding: .utf8)) == fixtureMarkerContents
    else { return }
    try? FileManager.default.removeItem(at: root)
}

@Test func diskUsageDeduplicatesHardlinks() throws {
    let root = try temporaryRoot()
    defer { removeTemporaryRoot(root) }
    let first = root.appendingPathComponent("first.bin")
    let second = root.appendingPathComponent("second.bin")
    try Data(repeating: 0x41, count: 8_192).write(to: first)
    try FileManager.default.linkItem(at: first, to: second)

    let reader = LocalFileSystemReader()
    let firstIdentity = try reader.identity(at: first.path)
    let usage = try reader.usage(at: root.path)

    // Root directory + fixture marker + two hardlink paths, but only three
    // unique physical inodes.
    #expect(usage.fileCount == 4)
    #expect(usage.uniqueFileCount == 3)
    #expect(usage.logicalBytes >= firstIdentity.logicalBytes * 2)
    #expect(usage.allocatedBytes >= firstIdentity.allocatedBytes)
    #expect(usage.allocatedBytes < firstIdentity.allocatedBytes * 2 + 65_536)
    #expect(usage.reclaimableBytes == usage.allocatedBytes)
    #expect(usage.reclaimableBytes <= usage.allocatedBytes)
}

@Test func diskUsageDoesNotClaimExternalHardlinkAllocation() throws {
    let root = try temporaryRoot()
    defer { removeTemporaryRoot(root) }
    let candidate = root.appendingPathComponent("candidate", isDirectory: true)
    try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
    let outside = root.appendingPathComponent("outside.bin")
    let inside = candidate.appendingPathComponent("inside.bin")
    let secondInside = candidate.appendingPathComponent("second-inside.bin")
    try Data(repeating: 0x42, count: 8_192).write(to: outside)
    try FileManager.default.linkItem(at: outside, to: inside)
    try FileManager.default.linkItem(at: outside, to: secondInside)

    let reader = LocalFileSystemReader()
    let outsideIdentity = try reader.identity(at: outside.path)
    let insideIdentity = try reader.identity(at: inside.path)
    let singleFileUsage = try reader.usage(at: inside.path)
    let usage = try reader.usage(at: candidate.path)

    #expect(outsideIdentity.linkCount == 3)
    #expect(insideIdentity.reclaimableBytes == 0)
    #expect(singleFileUsage.reclaimableBytes == 0)
    #expect(usage.allocatedBytes >= outsideIdentity.allocatedBytes)
    #expect(usage.allocatedBytes - usage.reclaimableBytes >= outsideIdentity.allocatedBytes)
    #expect(usage.reclaimableBytes <= usage.allocatedBytes)
}

@Test func validatorRejectsTraversalProtectedRootsAndSymlinks() throws {
    let root = try temporaryRoot()
    defer { removeTemporaryRoot(root) }
    let target = root.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let policy = PathValidationPolicy(homePath: root.path, allowedRoots: [root.path], protectedSubtrees: [])
    let validator = PathValidator(policy: policy)

    #expect(throws: KeepItCleanError.self) { try validator.validateExistingTarget(root.path) }
    #expect(throws: KeepItCleanError.self) { try validator.validateExistingTarget(root.path + "/../escape") }
    #expect(throws: KeepItCleanError.self) { try validator.validateExistingTarget(link.path) }
    #expect(try validator.validateExistingTarget(target.path).fileKind == .directory)
}

@Test func planAndOperationStoresRoundTripAndStayBounded() throws {
    let root = try temporaryRoot()
    defer { removeTemporaryRoot(root) }
    let planStore = JSONPlanStore(baseDirectory: root.appendingPathComponent("plans"))
    let plan = CleanupPlan(hostID: "host", items: [])
    let url = try planStore.save(plan: plan)
    #expect(try planStore.loadPlan(at: url) == plan)

    let log = JSONLOperationStore(logURL: root.appendingPathComponent("operations.jsonl"), maximumRecords: 2)
    let first = OperationRecord(kind: .trash, state: .completed)
    let second = OperationRecord(kind: .undo, state: .completed)
    let third = OperationRecord(kind: .finalize, state: .completed)
    try log.append(operation: first)
    try log.append(operation: second)
    try log.append(operation: third)
    let records = try log.operations(limit: 10)
    #expect(records.map(\.id) == [third.id, second.id])
}

@Test func storesRejectExternalPlanAliasesAndCorruptHistory() throws {
    let root = try temporaryRoot()
    defer { removeTemporaryRoot(root) }
    let planDirectory = root.appendingPathComponent("plans", isDirectory: true)
    let planStore = JSONPlanStore(baseDirectory: planDirectory)
    let plan = CleanupPlan(hostID: "host", items: [])
    let stored = try planStore.save(plan: plan)

    let external = root.appendingPathComponent("external.cleanup.json")
    try FileManager.default.copyItem(at: stored, to: external)
    #expect(throws: KeepItCleanError.self) {
        try planStore.loadPlan(at: external)
    }

    let alias = planDirectory.appendingPathComponent("alias.cleanup.json")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: stored)
    #expect(throws: KeepItCleanError.self) {
        try planStore.loadPlan(at: alias)
    }

    let logURL = root.appendingPathComponent("operations.jsonl")
    let log = JSONLOperationStore(logURL: logURL)
    try log.append(operation: OperationRecord(kind: .trash, state: .completed))
    try Data("not-json\n".utf8).write(to: logURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
    #expect(throws: KeepItCleanError.self) {
        try log.operations(limit: 10)
    }
}

@Test func trashUndoAndFinalizeAreBoundToRecordedIdentity() throws {
    let root = try temporaryRoot()
    defer { removeTemporaryRoot(root) }
    let trash = root.appendingPathComponent(".TrashFixture", isDirectory: true)
    let source = root.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("payload".utf8).write(to: source.appendingPathComponent("file"))

    let reader = LocalFileSystemReader()
    let identity = try reader.identity(at: source.path)
    let candidate = Candidate(
        ruleID: "fixture",
        category: "Fixture",
        path: source.path,
        displayName: "cache",
        evidence: "test fixture",
        identity: identity,
        actionKind: .trash,
        risk: .low,
        rebuildCost: .low,
        activeState: .inactive,
        defaultSelected: true
    )
    let host = "fixture-host"
    let plan = CleanupPlan(hostID: host, items: [CleanupPlanItem(candidate: candidate)])
    let operations = JSONLOperationStore(logURL: root.appendingPathComponent("operations.jsonl"))
    let gateway = FileMutationGateway(
        validator: PathValidator(policy: PathValidationPolicy(
            homePath: root.path,
            allowedRoots: [root.path],
            protectedSubtrees: []
        )),
        reader: reader,
        mover: DirectoryTrashMover(trashDirectory: trash),
        operationStore: operations
    )

    let trashed = try gateway.applyTrash(plan: plan, hostID: host)
    #expect(trashed.state == .completed)
    #expect(!reader.fileExists(at: source.path))
    let restored = try gateway.undo(operation: trashed)
    #expect(restored.items.first?.message == nil)
    #expect(restored.state == .completed)
    #expect(reader.fileExists(at: source.path))

    let refreshedIdentity = try reader.identity(at: source.path)
    var secondCandidate = candidate
    secondCandidate.identity = refreshedIdentity
    let secondPlan = CleanupPlan(hostID: host, items: [CleanupPlanItem(candidate: secondCandidate)])
    let secondTrash = try gateway.applyTrash(plan: secondPlan, hostID: host)
    #expect(throws: KeepItCleanError.self) {
        try gateway.finalize(operation: secondTrash, confirmationToken: "wrong")
    }
    let finalized = try gateway.finalize(
        operation: secondTrash,
        confirmationToken: FileMutationGateway.finalizeToken(for: secondTrash.id)
    )
    #expect(finalized.state == .completed)
    #expect(secondTrash.items.first?.resultingTrashPath.map(reader.fileExists(at:)) == false)
}

@Test func sparseFileReportsLogicalAndAllocatedBytesSeparately() throws {
    let root = try temporaryRoot()
    defer { removeTemporaryRoot(root) }
    let sparseFile = root.appendingPathComponent("sparse-64mb.bin")
    let logicalSize = off_t(64 * 1_024 * 1_024)

    let descriptor = sparseFile.path.withCString {
        Darwin.open($0, O_CREAT | O_EXCL | O_RDWR, mode_t(0o600))
    }
    guard descriptor >= 0 else {
        throw KeepItCleanError.io("Unable to create sparse fixture: \(String(cString: strerror(errno)))")
    }
    defer { Darwin.close(descriptor) }
    guard Darwin.ftruncate(descriptor, logicalSize) == 0 else {
        throw KeepItCleanError.io("Unable to size sparse fixture: \(String(cString: strerror(errno)))")
    }

    let reader = LocalFileSystemReader()
    let identity = try reader.identity(at: sparseFile.path)
    let usage = try reader.usage(at: root.path)

    #expect(identity.logicalBytes == UInt64(logicalSize))
    #expect(identity.allocatedBytes < identity.logicalBytes)
    #expect(usage.logicalBytes >= UInt64(logicalSize))
    #expect(usage.allocatedBytes < usage.logicalBytes)
}

@Test func validatorRejectsDeviceBoundaryWithoutCreatingAMount() throws {
    let root = try temporaryRoot()
    defer { removeTemporaryRoot(root) }
    let reader = LocalFileSystemReader()
    let filesystemRoot = try reader.identity(at: "/")
    let devRoot = try reader.identity(at: "/dev")

    // `/dev` is the existing devfs mount on macOS. This exercises the device
    // boundary without mounting, unmounting, or changing any system state.
    try #require(filesystemRoot.device != devRoot.device)
    let validator = PathValidator(policy: PathValidationPolicy(
        homePath: root.path,
        allowedRoots: ["/"],
        protectedSubtrees: [],
        currentUserID: devRoot.ownerID
    ))

    #expect(throws: KeepItCleanError.mountRoot("/dev")) {
        try validator.validateExistingTarget("/dev")
    }
}

@Test func validatorRejectsOwnerMismatchUsingInjectedPolicyUID() throws {
    let root = try temporaryRoot()
    defer { removeTemporaryRoot(root) }
    let target = root.appendingPathComponent("owned-cache", isDirectory: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let identity = try LocalFileSystemReader().identity(at: target.path)
    let differentUserID = identity.ownerID == UInt32.max ? identity.ownerID - 1 : identity.ownerID + 1
    let validator = PathValidator(policy: PathValidationPolicy(
        homePath: root.path,
        allowedRoots: [root.path],
        protectedSubtrees: [],
        currentUserID: differentUserID
    ))

    #expect(throws: KeepItCleanError.self) {
        try validator.validateExistingTarget(target.path)
    }
}

@Test func trashRejectsCandidateWhoseIdentityDriftedAfterReview() throws {
    let root = try temporaryRoot()
    defer { removeTemporaryRoot(root) }
    let source = root.appendingPathComponent("stale-cache", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("reviewed".utf8).write(to: source.appendingPathComponent("payload"))

    let reader = LocalFileSystemReader()
    let candidate = try fixtureCandidate(at: source, reader: reader)
    try FileManager.default.setAttributes(
        [.modificationDate: candidate.identity!.modifiedAt.addingTimeInterval(120)],
        ofItemAtPath: source.path
    )
    let trash = root.appendingPathComponent(".TrashFixture", isDirectory: true)
    let gateway = fixtureGateway(root: root, trash: trash, reader: reader)
    let plan = CleanupPlan(
        hostID: "fixture-host",
        items: [CleanupPlanItem(candidate: candidate)]
    )

    #expect(throws: KeepItCleanError.self) {
        try gateway.applyTrash(plan: plan, hostID: "fixture-host")
    }
    #expect(reader.fileExists(at: source.path))
}

@Test func duplicateSelectedPathsFailBeforeJournalOrMutation() throws {
    let root = try temporaryRoot()
    defer { removeTemporaryRoot(root) }
    let source = root.appendingPathComponent("shared-cache", isDirectory: true)
    let payload = source.appendingPathComponent("payload")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("preserve".utf8).write(to: payload)

    let reader = LocalFileSystemReader()
    let first = try fixtureCandidate(at: source, reader: reader)
    var second = first
    second.id = "second-rule:\(source.path)"
    second.ruleID = "second-rule"
    let plan = CleanupPlan(
        hostID: "fixture-host",
        items: [
            CleanupPlanItem(candidate: first, selected: true),
            CleanupPlanItem(candidate: second, selected: true),
        ]
    )
    let trash = root.appendingPathComponent(".TrashFixture", isDirectory: true)
    let operationStore = JSONLOperationStore(logURL: root.appendingPathComponent("operations.jsonl"))
    let gateway = FileMutationGateway(
        validator: PathValidator(policy: PathValidationPolicy(
            homePath: root.path,
            allowedRoots: [root.path],
            protectedSubtrees: []
        )),
        reader: reader,
        mover: DirectoryTrashMover(trashDirectory: trash),
        operationStore: operationStore
    )

    #expect(throws: KeepItCleanError.self) {
        _ = try gateway.applyTrash(plan: plan, hostID: "fixture-host")
    }
    #expect(reader.fileExists(at: source.path))
    #expect(try String(contentsOf: payload, encoding: .utf8) == "preserve")
    #expect(!reader.fileExists(at: trash.path))
    #expect(try operationStore.operations(limit: 10).isEmpty)
}

@Test func directoryTrashMoverAvoidsSameNameCollisions() throws {
    let root = try temporaryRoot()
    defer { removeTemporaryRoot(root) }
    let first = root.appendingPathComponent("first/cache", isDirectory: true)
    let second = root.appendingPathComponent("second/cache", isDirectory: true)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try Data("first".utf8).write(to: first.appendingPathComponent("payload"))
    try Data("second".utf8).write(to: second.appendingPathComponent("payload"))

    let reader = LocalFileSystemReader()
    let plan = CleanupPlan(
        hostID: "fixture-host",
        items: [
            CleanupPlanItem(candidate: try fixtureCandidate(at: first, reader: reader)),
            CleanupPlanItem(candidate: try fixtureCandidate(at: second, reader: reader)),
        ]
    )
    let trash = root.appendingPathComponent(".TrashFixture", isDirectory: true)
    let gateway = fixtureGateway(root: root, trash: trash, reader: reader)

    let operation = try gateway.applyTrash(plan: plan, hostID: "fixture-host")
    let destinations = operation.items.compactMap(\.resultingTrashPath)

    #expect(operation.state == .completed)
    #expect(destinations.count == 2)
    #expect(Set(destinations).count == 2)
    #expect(destinations.allSatisfy { $0.hasPrefix(trash.path + "/") })
    #expect(destinations.contains { URL(fileURLWithPath: $0).lastPathComponent == "cache" })
    #expect(destinations.contains { URL(fileURLWithPath: $0).lastPathComponent.hasSuffix("-cache") })
    #expect(operation.items.allSatisfy { $0.status == .movedToTrash })
}

@Test func undoFailsClosedWhenOriginalPathIsOccupied() throws {
    let root = try temporaryRoot()
    defer { removeTemporaryRoot(root) }
    let source = root.appendingPathComponent("conflicting-cache", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("trashed".utf8).write(to: source.appendingPathComponent("payload"))

    let reader = LocalFileSystemReader()
    let candidate = try fixtureCandidate(at: source, reader: reader)
    let trash = root.appendingPathComponent(".TrashFixture", isDirectory: true)
    let gateway = fixtureGateway(root: root, trash: trash, reader: reader)
    let trashed = try gateway.applyTrash(
        plan: CleanupPlan(
            hostID: "fixture-host",
            items: [CleanupPlanItem(candidate: candidate)]
        ),
        hostID: "fixture-host"
    )
    let trashPath = try #require(trashed.items.first?.resultingTrashPath)

    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("replacement".utf8).write(to: source.appendingPathComponent("payload"))
    let undo = try gateway.undo(operation: trashed)

    #expect(undo.state == .failed)
    #expect(undo.items.first?.status == .failed)
    #expect(undo.items.first?.message?.localizedCaseInsensitiveContains("occupied") == true)
    #expect(reader.fileExists(at: source.path))
    #expect(reader.fileExists(at: trashPath))
    #expect(try String(contentsOf: source.appendingPathComponent("payload"), encoding: .utf8) == "replacement")
}

@Test func undoAndFinalizeFailClosedWhenTrashItemIsMissing() throws {
    let root = try temporaryRoot()
    defer { removeTemporaryRoot(root) }
    let source = root.appendingPathComponent("missing-cache", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("payload".utf8).write(to: source.appendingPathComponent("payload"))

    let reader = LocalFileSystemReader()
    let candidate = try fixtureCandidate(at: source, reader: reader)
    let trash = root.appendingPathComponent(".TrashFixture", isDirectory: true)
    let gateway = fixtureGateway(root: root, trash: trash, reader: reader)
    let trashed = try gateway.applyTrash(
        plan: CleanupPlan(
            hostID: "fixture-host",
            items: [CleanupPlanItem(candidate: candidate)]
        ),
        hostID: "fixture-host"
    )
    let trashPath = try #require(trashed.items.first?.resultingTrashPath)
    try FileManager.default.removeItem(atPath: trashPath)

    let undo = try gateway.undo(operation: trashed)
    let finalized = try gateway.finalize(
        operation: trashed,
        confirmationToken: FileMutationGateway.finalizeToken(for: trashed.id)
    )

    #expect(undo.state == .failed)
    #expect(undo.items.first?.status == .failed)
    #expect(finalized.state == .failed)
    #expect(finalized.items.first?.status == .failed)
    #expect(!reader.fileExists(at: source.path))
    #expect(!reader.fileExists(at: trashPath))
}

@Test func forgedTrashTraversalCannotUndoOrFinalizeOutsideTrash() throws {
    let root = try temporaryRoot()
    defer { removeTemporaryRoot(root) }
    let trash = root.appendingPathComponent(".TrashFixture", isDirectory: true)
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    let reader = LocalFileSystemReader()
    let gateway = fixtureGateway(root: root, trash: trash, reader: reader)

    let undoVictim = root.appendingPathComponent("undo-victim")
    try Data("must remain".utf8).write(to: undoVictim)
    let undoRecord = OperationRecord(
        kind: .trash,
        state: .completed,
        items: [OperationItem(
            candidateID: "forged-undo",
            originalPath: root.appendingPathComponent("forged-restore").path,
            resultingTrashPath: trash.path + "/../undo-victim",
            identity: try reader.identity(at: undoVictim.path),
            status: .movedToTrash
        )]
    )

    let undo = try gateway.undo(operation: undoRecord)
    #expect(undo.state == .failed)
    #expect(undo.items.first?.status == .failed)
    #expect(reader.fileExists(at: undoVictim.path))
    #expect(!reader.fileExists(at: root.appendingPathComponent("forged-restore").path))

    let finalizeVictim = root.appendingPathComponent("finalize-victim")
    try Data("must also remain".utf8).write(to: finalizeVictim)
    let finalizeRecord = OperationRecord(
        kind: .trash,
        state: .completed,
        items: [OperationItem(
            candidateID: "forged-finalize",
            originalPath: root.appendingPathComponent("irrelevant-original").path,
            resultingTrashPath: trash.path + "/../finalize-victim",
            identity: try reader.identity(at: finalizeVictim.path),
            status: .movedToTrash
        )]
    )

    let finalized = try gateway.finalize(
        operation: finalizeRecord,
        confirmationToken: FileMutationGateway.finalizeToken(for: finalizeRecord.id)
    )
    #expect(finalized.state == .failed)
    #expect(finalized.items.first?.status == .failed)
    #expect(reader.fileExists(at: finalizeVictim.path))
}

@Test func forgedTrashSymlinkEscapeIsRejected() throws {
    let root = try temporaryRoot()
    defer { removeTemporaryRoot(root) }
    let trash = root.appendingPathComponent(".TrashFixture", isDirectory: true)
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    let victim = root.appendingPathComponent("symlink-victim")
    try Data("preserve".utf8).write(to: victim)
    let link = trash.appendingPathComponent("forged-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)

    let reader = LocalFileSystemReader()
    let gateway = fixtureGateway(root: root, trash: trash, reader: reader)
    let record = OperationRecord(
        kind: .trash,
        state: .completed,
        items: [OperationItem(
            candidateID: "forged-symlink",
            originalPath: root.appendingPathComponent("restored-link").path,
            resultingTrashPath: link.path,
            identity: try reader.identity(at: link.path),
            status: .movedToTrash
        )]
    )

    let undo = try gateway.undo(operation: record)
    let finalized = try gateway.finalize(
        operation: record,
        confirmationToken: FileMutationGateway.finalizeToken(for: record.id)
    )

    #expect(undo.state == .failed)
    #expect(finalized.state == .failed)
    #expect(reader.fileExists(at: link.path))
    #expect(reader.fileExists(at: victim.path))
    #expect(!reader.fileExists(at: root.appendingPathComponent("restored-link").path))
}

@Test func trashRollsBackWhenDestinationCannotBeJournaled() throws {
    let root = try temporaryRoot()
    defer { removeTemporaryRoot(root) }
    let source = root.appendingPathComponent("journal-cache", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("payload".utf8).write(to: source.appendingPathComponent("payload"))

    let reader = LocalFileSystemReader()
    let candidate = try fixtureCandidate(at: source, reader: reader)
    let trash = root.appendingPathComponent(".TrashFixture", isDirectory: true)
    let gateway = FileMutationGateway(
        validator: PathValidator(policy: PathValidationPolicy(
            homePath: root.path,
            allowedRoots: [root.path],
            protectedSubtrees: []
        )),
        reader: reader,
        mover: DirectoryTrashMover(trashDirectory: trash),
        operationStore: FailingAfterFirstAppendStore()
    )

    #expect(throws: KeepItCleanError.self) {
        try gateway.applyTrash(
            plan: CleanupPlan(hostID: "fixture-host", items: [CleanupPlanItem(candidate: candidate)]),
            hostID: "fixture-host"
        )
    }
    #expect(reader.fileExists(at: source.path))
    let trashChildren = (try? reader.immediateChildren(at: trash.path)) ?? []
    #expect(trashChildren.isEmpty)
}

private final class FailingAfterFirstAppendStore: OperationStoring, @unchecked Sendable {
    private var appendCount = 0
    private var first: OperationRecord?

    func append(operation: OperationRecord) throws {
        defer { appendCount += 1 }
        guard appendCount == 0 else {
            throw KeepItCleanError.io("injected journal interruption")
        }
        first = operation
    }

    func operation(id: UUID) throws -> OperationRecord {
        guard let first, first.id == id else {
            throw KeepItCleanError.operationNotFound(id.uuidString)
        }
        return first
    }

    func operations(limit: Int) throws -> [OperationRecord] {
        first.map { [$0] } ?? []
    }
}

private func fixtureCandidate(
    at source: URL,
    reader: LocalFileSystemReader
) throws -> Candidate {
    Candidate(
        ruleID: "fixture",
        category: "Fixture",
        path: source.path,
        displayName: source.lastPathComponent,
        evidence: "marker-guarded test fixture",
        identity: try reader.identity(at: source.path),
        actionKind: .trash,
        risk: .low,
        rebuildCost: .low,
        activeState: .inactive,
        defaultSelected: true
    )
}

private func fixtureGateway(
    root: URL,
    trash: URL,
    reader: LocalFileSystemReader
) -> FileMutationGateway {
    FileMutationGateway(
        validator: PathValidator(policy: PathValidationPolicy(
            homePath: root.path,
            allowedRoots: [root.path],
            protectedSubtrees: []
        )),
        reader: reader,
        mover: DirectoryTrashMover(trashDirectory: trash),
        operationStore: JSONLOperationStore(logURL: root.appendingPathComponent("operations.jsonl"))
    )
}
