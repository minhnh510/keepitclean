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

@Test func signedDeviceIdentifierPreservesOpaqueBitsWithoutTrapping() {
    let signedDevice = dev_t(-1)

    #expect(LocalFileSystemReader.normalizedDeviceID(signedDevice) == UInt64(UInt32.max))
}

@Test func fdRelativeIdentityIfPresentDistinguishesAbsenceFromLookupFailures() throws {
    let root = try temporaryRoot()
    defer { removeTemporaryRoot(root) }
    let reader = LocalFileSystemReader()
    let existing = root.appendingPathComponent("identity-present")
    let missing = root.appendingPathComponent("identity-missing")
    let link = root.appendingPathComponent("identity-link")
    let regularParent = root.appendingPathComponent("not-a-directory")
    try Data("present".utf8).write(to: existing)
    try Data("regular parent".utf8).write(to: regularParent)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: existing)

    let optionalPresent = try reader.identityIfPresent(at: existing.path)
    let present = try #require(optionalPresent)
    let direct = try reader.identity(at: existing.path)
    #expect(present == direct)
    #expect(try reader.identityIfPresent(at: missing.path) == nil)
    #expect(try reader.identityIfPresent(at: link.path)?.fileKind == .symbolicLink)
    #expect(throws: KeepItCleanError.self) {
        _ = try reader.identityIfPresent(
            at: regularParent.appendingPathComponent("child").path
        )
    }

    let linkedParent = root.appendingPathComponent("linked-parent")
    try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: root)
    #expect(throws: KeepItCleanError.self) {
        _ = try reader.identityIfPresent(
            at: linkedParent.appendingPathComponent("identity-missing").path
        )
    }

    if getuid() != 0 {
        let denied = root.appendingPathComponent("denied", isDirectory: true)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: denied.path
            )
        }
        #expect(throws: KeepItCleanError.self) {
            _ = try reader.identityIfPresent(
                at: denied.appendingPathComponent("must-not-look-missing").path
            )
        }
    }
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

@Test func validatorAllowsOnlyExactCodexSessionDayBucketsInsideProtectedStore() throws {
    let root = try temporaryRoot()
    defer { removeTemporaryRoot(root) }
    let sessions = root.appendingPathComponent(".codex/sessions", isDirectory: true)
    let day = sessions.appendingPathComponent("2026/07/01", isDirectory: true)
    let invalidDay = sessions.appendingPathComponent("2026/13/40", isDirectory: true)
    let item = day.appendingPathComponent("rollout.jsonl")
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: invalidDay, withIntermediateDirectories: true)
    try Data("history".utf8).write(to: item)

    let validator = PathValidator(policy: PathValidationPolicy(
        homePath: root.path,
        allowedRoots: [root.path]
    ))

    #expect(try validator.validateExistingTarget(day.path).fileKind == .directory)
    #expect(throws: KeepItCleanError.self) {
        _ = try validator.validateExistingTarget(sessions.path)
    }
    #expect(throws: KeepItCleanError.self) {
        _ = try validator.validateExistingTarget(sessions.appendingPathComponent("2026/07").path)
    }
    #expect(throws: KeepItCleanError.self) {
        _ = try validator.validateExistingTarget(item.path)
    }
    #expect(throws: KeepItCleanError.self) {
        _ = try validator.validateExistingTarget(invalidDay.path)
    }
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

@Test func directoryTrashMoverUsesPrejournaledDeterministicNames() throws {
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
    let canonicalTrash = PathValidationPolicy.canonicalSystemAlias(trash.path)
    let operationPrefix = ".keepitclean-\(operation.id.uuidString.lowercased())-"
    #expect(destinations.allSatisfy { $0.hasPrefix(canonicalTrash + "/" + operationPrefix) })
    #expect(Set(destinations.map { URL(fileURLWithPath: $0).lastPathComponent }) == [
        operationPrefix + "0",
        operationPrefix + "1",
    ])
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
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: trash.path
    )
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
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: trash.path
    )
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

@Test func largeTrashSweepUsesBoundedJournalCheckpoints() throws {
    let root = try temporaryRoot()
    defer { removeTemporaryRoot(root) }
    let reader = LocalFileSystemReader()
    let candidates = try (0..<257).map { index in
        let source = root.appendingPathComponent(String(format: "transform-%04d", index))
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        return try fixtureCandidate(at: source, reader: reader)
    }
    let store = CountingOperationStore()
    let trash = root.appendingPathComponent(".TrashFixture", isDirectory: true)
    let gateway = FileMutationGateway(
        validator: PathValidator(policy: PathValidationPolicy(
            homePath: root.path,
            allowedRoots: [root.path],
            protectedSubtrees: []
        )),
        reader: reader,
        mover: DirectoryTrashMover(trashDirectory: trash),
        operationStore: store
    )

    let operation = try gateway.applyTrash(
        plan: CleanupPlan(
            hostID: "fixture-host",
            items: candidates.map { CleanupPlanItem(candidate: $0) }
        ),
        hostID: "fixture-host"
    )

    #expect(operation.state == .completed)
    #expect(operation.items.allSatisfy { $0.status == .movedToTrash })
    #expect(store.appendCount == 2)
    #expect(try reader.immediateChildren(at: trash.path).count == candidates.count)
}

@Test func gatewayApplyLeafSwapFailsClosedWithoutMovingReplacement() throws {
    let root = try temporaryRoot()
    defer { removeTemporaryRoot(root) }
    let source = root.appendingPathComponent("reviewed-cache")
    let capturedReviewed = root.appendingPathComponent("attacker-captured-reviewed-cache")
    try Data("reviewed".utf8).write(to: source)

    let reader = LocalFileSystemReader()
    let candidate = try fixtureCandidate(at: source, reader: reader)
    let canonicalSource = PathValidationPolicy.canonicalSystemAlias(source.path)
    let observer = GatewayCheckpointAction(
        target: .sourceVerifiedBeforeRename,
        predicate: { $0.sourcePath == canonicalSource }
    ) { _ in
        try FileManager.default.moveItem(at: source, to: capturedReviewed)
        try Data("replacement".utf8).write(to: source)
    }
    let trash = root.appendingPathComponent(".TrashFixture", isDirectory: true)
    let operationStore = JSONLOperationStore(logURL: root.appendingPathComponent("operations.jsonl"))
    let gateway = FileMutationGateway(
        validator: PathValidator(policy: PathValidationPolicy(
            homePath: root.path,
            allowedRoots: [root.path],
            protectedSubtrees: []
        )),
        reader: reader,
        mover: DirectoryTrashMover(
            trashDirectory: trash,
            fileSystem: FDRelativeFileSystem(observer: observer)
        ),
        operationStore: operationStore
    )

    let result = try gateway.applyTrash(
        plan: CleanupPlan(
            hostID: "fixture-host",
            items: [CleanupPlanItem(candidate: candidate)]
        ),
        hostID: "fixture-host"
    )
    let plannedTrashPath = try #require(result.items.first?.resultingTrashPath)

    #expect(result.state == .failed)
    #expect(result.items.first?.status == .failed)
    #expect(try String(contentsOf: source, encoding: .utf8) == "replacement")
    #expect(try String(contentsOf: capturedReviewed, encoding: .utf8) == "reviewed")
    #expect(!reader.fileExists(at: plannedTrashPath))
    #expect(candidate.identity!.matchesForMutation(try reader.identity(at: capturedReviewed.path)))
}

@Test func gatewayFinalizeLeafSwapNeverDeletesReplacement() throws {
    let root = try temporaryRoot()
    defer { removeTemporaryRoot(root) }
    let source = root.appendingPathComponent("finalize-race-cache")
    try Data("reviewed".utf8).write(to: source)

    let reader = LocalFileSystemReader()
    let trash = root.appendingPathComponent(".TrashFixture", isDirectory: true)
    let initialGateway = fixtureGateway(root: root, trash: trash, reader: reader)
    let trashed = try initialGateway.applyTrash(
        plan: CleanupPlan(
            hostID: "fixture-host",
            items: [CleanupPlanItem(candidate: try fixtureCandidate(at: source, reader: reader))]
        ),
        hostID: "fixture-host"
    )
    let trashPath = try #require(trashed.items.first?.resultingTrashPath)
    let capturedReviewed = root.appendingPathComponent("attacker-captured-trash-item")
    let canonicalTrashPath = PathValidationPolicy.canonicalSystemAlias(trashPath)
    let observer = GatewayCheckpointAction(
        target: .sourceVerifiedBeforeRename,
        predicate: { $0.sourcePath == canonicalTrashPath }
    ) { _ in
        try FileManager.default.moveItem(
            at: URL(fileURLWithPath: trashPath),
            to: capturedReviewed
        )
        try Data("replacement-must-survive".utf8).write(
            to: URL(fileURLWithPath: trashPath)
        )
    }
    let finalizeGateway = FileMutationGateway(
        validator: PathValidator(policy: PathValidationPolicy(
            homePath: root.path,
            allowedRoots: [root.path],
            protectedSubtrees: []
        )),
        reader: reader,
        mover: DirectoryTrashMover(
            trashDirectory: trash,
            fileSystem: FDRelativeFileSystem(observer: observer)
        ),
        operationStore: JSONLOperationStore(logURL: root.appendingPathComponent("finalize.jsonl"))
    )

    let finalized = try finalizeGateway.finalize(
        operation: trashed,
        confirmationToken: FileMutationGateway.finalizeToken(for: trashed.id)
    )
    let quarantinePath = try #require(finalized.items.first?.resultingTrashPath)

    #expect(finalized.state == .failed)
    #expect(finalized.items.first?.status == .failed)
    #expect(try String(contentsOf: URL(fileURLWithPath: trashPath), encoding: .utf8) == "replacement-must-survive")
    #expect(try String(contentsOf: capturedReviewed, encoding: .utf8) == "reviewed")
    #expect(!reader.fileExists(at: quarantinePath))
    #expect(trashed.items[0].identity.matchesForMutation(try reader.identity(at: capturedReviewed.path)))
}

@Test func finalizeCaptureIntentRemainsJournaledWhenLaterAppendFails() throws {
    let root = try temporaryRoot()
    defer { removeTemporaryRoot(root) }
    let source = root.appendingPathComponent("finalize-journal-cache")
    try Data("reviewed".utf8).write(to: source)

    let reader = LocalFileSystemReader()
    let trash = root.appendingPathComponent(".TrashFixture", isDirectory: true)
    let trashed = try fixtureGateway(root: root, trash: trash, reader: reader).applyTrash(
        plan: CleanupPlan(
            hostID: "fixture-host",
            items: [CleanupPlanItem(candidate: try fixtureCandidate(at: source, reader: reader))]
        ),
        hostID: "fixture-host"
    )
    let visibleTrashPath = try #require(trashed.items.first?.resultingTrashPath)
    let failingStore = FailingAfterFirstAppendStore()
    let finalizeGateway = FileMutationGateway(
        validator: PathValidator(policy: PathValidationPolicy(
            homePath: root.path,
            allowedRoots: [root.path],
            protectedSubtrees: []
        )),
        reader: reader,
        mover: DirectoryTrashMover(trashDirectory: trash),
        operationStore: failingStore
    )

    #expect(throws: KeepItCleanError.self) {
        _ = try finalizeGateway.finalize(
            operation: trashed,
            confirmationToken: FileMutationGateway.finalizeToken(for: trashed.id)
        )
    }

    let intent = try #require(try failingStore.operations(limit: 1).first)
    let quarantinePath = try #require(intent.items.first?.resultingTrashPath)
    #expect(intent.kind == .finalize)
    #expect(intent.state == .running)
    #expect(intent.items.first?.status == .pending)
    #expect(!reader.fileExists(at: visibleTrashPath))
    #expect(reader.fileExists(at: quarantinePath))
    #expect(trashed.items[0].identity.matchesForMutation(try reader.identity(at: quarantinePath)))
}

@Test func interruptedTrashApplyRecoveryReconcilesExactMovedInodeAndPersistsTerminalRecord() throws {
    let root = try temporaryRoot()
    defer { removeTemporaryRoot(root) }
    let source = root.appendingPathComponent("recovery-reviewed-item")
    try Data("reviewed-recovery-inode".utf8).write(to: source)

    let reader = LocalFileSystemReader()
    let candidate = try fixtureCandidate(at: source, reader: reader)
    let plan = CleanupPlan(
        hostID: "fixture-host",
        items: [CleanupPlanItem(candidate: candidate)]
    )
    let trash = root.appendingPathComponent(".TrashFixture", isDirectory: true)
    let mover = DirectoryTrashMover(trashDirectory: trash)
    let operationStore = JSONLOperationStore(
        logURL: root.appendingPathComponent("recovery-operations.jsonl")
    )
    let gateway = FileMutationGateway(
        validator: PathValidator(policy: PathValidationPolicy(
            homePath: root.path,
            allowedRoots: [root.path],
            protectedSubtrees: []
        )),
        reader: reader,
        mover: mover,
        operationStore: operationStore
    )
    let operationID = UUID()
    let plannedTrash = try mover.plannedTrashURL(
        for: source,
        operationID: operationID,
        itemIndex: 0
    )
    let interrupted = OperationRecord(
        id: operationID,
        planID: plan.id,
        kind: .trash,
        state: .running,
        items: [OperationItem(
            candidateID: candidate.id,
            originalPath: candidate.path,
            resultingTrashPath: plannedTrash.path,
            identity: try #require(candidate.identity),
            status: .pending
        )]
    )
    try operationStore.append(operation: interrupted)
    do {
        let operationLock = try mover.acquireOperationLock()
        defer { withExtendedLifetime(operationLock) {} }
        _ = try mover.moveToTrash(
            source,
            to: plannedTrash,
            expectedIdentity: try #require(candidate.identity)
        )
    }

    let recovered = try gateway.recoverInterruptedTrashApply(operation: interrupted)
    let persisted = try operationStore.operation(id: operationID)

    #expect(recovered.state == .completed)
    #expect(recovered.completedAt != nil)
    #expect(recovered.items.first?.status == .movedToTrash)
    #expect(persisted == recovered)
    #expect(!reader.fileExists(at: source.path))
    #expect(try #require(candidate.identity).matchesForMutation(
        try reader.identity(at: plannedTrash.path)
    ))
}

@Test func interruptedTrashApplyRecoveryFailsClosedForMismatchAndMissingBothPaths() throws {
    do {
        let root = try temporaryRoot()
        defer { removeTemporaryRoot(root) }
        let source = root.appendingPathComponent("recovery-mismatch-item")
        let captured = root.appendingPathComponent("captured-reviewed-item")
        try Data("reviewed".utf8).write(to: source)
        let reader = LocalFileSystemReader()
        let candidate = try fixtureCandidate(at: source, reader: reader)
        let trash = root.appendingPathComponent(".TrashFixture", isDirectory: true)
        let mover = DirectoryTrashMover(trashDirectory: trash)
        let store = JSONLOperationStore(logURL: root.appendingPathComponent("recovery.jsonl"))
        let operationID = UUID()
        let plannedTrash = try mover.plannedTrashURL(
            for: source,
            operationID: operationID,
            itemIndex: 0
        )
        let interrupted = OperationRecord(
            id: operationID,
            planID: UUID(),
            kind: .trash,
            state: .running,
            items: [OperationItem(
                candidateID: candidate.id,
                originalPath: candidate.path,
                resultingTrashPath: plannedTrash.path,
                identity: try #require(candidate.identity),
                status: .pending
            )]
        )
        try store.append(operation: interrupted)
        do {
            let operationLock = try mover.acquireOperationLock()
            defer { withExtendedLifetime(operationLock) {} }
            _ = try mover.moveToTrash(
                source,
                to: plannedTrash,
                expectedIdentity: try #require(candidate.identity)
            )
        }
        try FileManager.default.moveItem(at: plannedTrash, to: captured)
        try Data("replacement-must-survive".utf8).write(to: plannedTrash)
        let gateway = FileMutationGateway(
            validator: PathValidator(policy: PathValidationPolicy(
                homePath: root.path,
                allowedRoots: [root.path],
                protectedSubtrees: []
            )),
            reader: reader,
            mover: mover,
            operationStore: store
        )

        #expect(throws: KeepItCleanError.self) {
            _ = try gateway.recoverInterruptedTrashApply(operation: interrupted)
        }
        #expect(try store.operation(id: operationID) == interrupted)
        #expect(try String(contentsOf: plannedTrash, encoding: .utf8) == "replacement-must-survive")
        #expect(try String(contentsOf: captured, encoding: .utf8) == "reviewed")
    }

    do {
        let root = try temporaryRoot()
        defer { removeTemporaryRoot(root) }
        let source = root.appendingPathComponent("recovery-missing-item")
        let captured = root.appendingPathComponent("captured-missing-item")
        try Data("reviewed".utf8).write(to: source)
        let reader = LocalFileSystemReader()
        let candidate = try fixtureCandidate(at: source, reader: reader)
        let trash = root.appendingPathComponent(".TrashFixture", isDirectory: true)
        let mover = DirectoryTrashMover(trashDirectory: trash)
        let store = JSONLOperationStore(logURL: root.appendingPathComponent("recovery.jsonl"))
        let operationID = UUID()
        let plannedTrash = try mover.plannedTrashURL(
            for: source,
            operationID: operationID,
            itemIndex: 0
        )
        let interrupted = OperationRecord(
            id: operationID,
            planID: UUID(),
            kind: .trash,
            state: .running,
            items: [OperationItem(
                candidateID: candidate.id,
                originalPath: candidate.path,
                resultingTrashPath: plannedTrash.path,
                identity: try #require(candidate.identity),
                status: .pending
            )]
        )
        try store.append(operation: interrupted)
        try FileManager.default.moveItem(at: source, to: captured)
        let gateway = FileMutationGateway(
            validator: PathValidator(policy: PathValidationPolicy(
                homePath: root.path,
                allowedRoots: [root.path],
                protectedSubtrees: []
            )),
            reader: reader,
            mover: mover,
            operationStore: store
        )

        #expect(throws: KeepItCleanError.self) {
            _ = try gateway.recoverInterruptedTrashApply(operation: interrupted)
        }
        #expect(try store.operation(id: operationID) == interrupted)
        #expect(try String(contentsOf: captured, encoding: .utf8) == "reviewed")
        #expect(!reader.fileExists(at: plannedTrash.path))
    }
}

@Test func interruptedTrashApplyPropagatesPresenceProbeFailures() throws {
    let root = try temporaryRoot()
    defer { removeTemporaryRoot(root) }
    let source = root.appendingPathComponent("recovery-probe-item")
    try Data("reviewed".utf8).write(to: source)
    let reader = LocalFileSystemReader()
    let candidate = try fixtureCandidate(at: source, reader: reader)
    let trash = root.appendingPathComponent(".TrashFixture", isDirectory: true)
    let mover = DirectoryTrashMover(trashDirectory: trash)
    let store = JSONLOperationStore(logURL: root.appendingPathComponent("recovery-probe.jsonl"))
    let operationID = UUID()
    let plannedTrash = try mover.plannedTrashURL(
        for: source,
        operationID: operationID,
        itemIndex: 0
    )
    let interrupted = OperationRecord(
        id: operationID,
        planID: UUID(),
        kind: .trash,
        state: .running,
        items: [OperationItem(
            candidateID: candidate.id,
            originalPath: candidate.path,
            resultingTrashPath: plannedTrash.path,
            identity: try #require(candidate.identity),
            status: .pending
        )]
    )
    try store.append(operation: interrupted)

    for failingPath in [plannedTrash.path, source.path] {
        let failingReader = FailingPresenceProbeReader(
            base: reader,
            failingPath: failingPath
        )
        let gateway = FileMutationGateway(
            validator: PathValidator(policy: PathValidationPolicy(
                homePath: root.path,
                allowedRoots: [root.path],
                protectedSubtrees: []
            )),
            reader: failingReader,
            mover: mover,
            operationStore: store
        )

        #expect(throws: KeepItCleanError.self) {
            _ = try gateway.recoverInterruptedTrashApply(operation: interrupted)
        }
        #expect(try store.operation(id: operationID) == interrupted)
        #expect(reader.fileExists(at: source.path))
        #expect(!reader.fileExists(at: plannedTrash.path))
    }
}

private final class GatewayCheckpointAction: FDRelativeMutationObserving, @unchecked Sendable {
    private let target: FDRelativeMutationCheckpoint
    private let predicate: @Sendable (FDRelativeMutationContext) -> Bool
    private let action: @Sendable (FDRelativeMutationContext) throws -> Void
    private let lock = NSLock()
    private var fired = false

    init(
        target: FDRelativeMutationCheckpoint,
        predicate: @escaping @Sendable (FDRelativeMutationContext) -> Bool = { _ in true },
        action: @escaping @Sendable (FDRelativeMutationContext) throws -> Void
    ) {
        self.target = target
        self.predicate = predicate
        self.action = action
    }

    func reached(
        _ checkpoint: FDRelativeMutationCheckpoint,
        context: FDRelativeMutationContext
    ) throws {
        guard checkpoint == target, predicate(context) else { return }
        lock.lock()
        guard !fired else {
            lock.unlock()
            return
        }
        fired = true
        lock.unlock()
        try action(context)
    }
}

private struct FailingPresenceProbeReader: FileIdentityPresenceReading, Sendable {
    let base: LocalFileSystemReader
    let failingPath: String

    func fileExists(at path: String) -> Bool {
        path == failingPath ? false : base.fileExists(at: path)
    }

    func identity(at path: String) throws -> FileIdentity {
        try base.identity(at: path)
    }

    func identityIfPresent(at path: String) throws -> FileIdentity? {
        guard path != failingPath else {
            throw KeepItCleanError.io("injected fd-relative presence probe failure")
        }
        return try base.identityIfPresent(at: path)
    }

    func usage(at path: String) throws -> DiskUsage {
        try base.usage(at: path)
    }

    func immediateChildren(at path: String) throws -> [String] {
        try base.immediateChildren(at: path)
    }

    func readPrefix(at path: String, maxBytes: Int) throws -> Data {
        try base.readPrefix(at: path, maxBytes: maxBytes)
    }
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

private final class CountingOperationStore: OperationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var latest: OperationRecord?
    private(set) var appendCount = 0

    func append(operation: OperationRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        latest = operation
        appendCount += 1
    }

    func operation(id: UUID) throws -> OperationRecord {
        lock.lock()
        defer { lock.unlock() }
        guard let latest, latest.id == id else {
            throw KeepItCleanError.operationNotFound(id.uuidString)
        }
        return latest
    }

    func operations(limit: Int) throws -> [OperationRecord] {
        lock.lock()
        defer { lock.unlock() }
        return latest.map { [$0] } ?? []
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
