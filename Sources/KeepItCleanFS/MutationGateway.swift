import Darwin
import Foundation
import KeepItCleanCore

public protocol TrashMoving: Sendable {
    var eligibleTrashRoots: [String] { get }
    func acquireOperationLock() throws -> FDRelativeDirectoryLock
    func plannedTrashURL(for source: URL, operationID: UUID, itemIndex: Int) throws -> URL
    func moveToTrash(
        _ source: URL,
        to destination: URL,
        expectedIdentity: FileIdentity
    ) throws -> URL
    func restoreFromTrash(
        _ source: URL,
        expectedIdentity: FileIdentity,
        to destination: URL
    ) throws
    func plannedFinalizeCaptureURL(
        for source: URL,
        operationID: UUID,
        itemIndex: Int
    ) throws -> URL
    func captureForFinalization(
        _ source: URL,
        to quarantine: URL,
        expectedIdentity: FileIdentity
    ) throws
    func permanentlyRemoveCapturedItem(
        _ quarantine: URL,
        expectedIdentity: FileIdentity
    ) throws
}

public struct SystemTrashMover: TrashMoving, Sendable {
    private let backend: FDRelativeTrashBackend
    public var eligibleTrashRoots: [String] { [backend.trashRoot.path] }

    public init(homePath: String) {
        backend = FDRelativeTrashBackend(
            trashRoot: URL(fileURLWithPath: homePath).appendingPathComponent(".Trash"),
            ownerID: getuid(),
            fileSystem: FDRelativeFileSystem()
        )
    }

    public func acquireOperationLock() throws -> FDRelativeDirectoryLock {
        try backend.acquireOperationLock()
    }

    public func plannedTrashURL(for source: URL, operationID: UUID, itemIndex: Int) throws -> URL {
        try backend.plannedTrashURL(for: source, operationID: operationID, itemIndex: itemIndex)
    }

    public func moveToTrash(
        _ source: URL,
        to destination: URL,
        expectedIdentity: FileIdentity
    ) throws -> URL {
        try backend.moveToTrash(source, to: destination, expectedIdentity: expectedIdentity)
    }

    public func restoreFromTrash(
        _ source: URL,
        expectedIdentity: FileIdentity,
        to destination: URL
    ) throws {
        try backend.restoreFromTrash(
            source,
            expectedIdentity: expectedIdentity,
            to: destination
        )
    }

    public func plannedFinalizeCaptureURL(
        for source: URL,
        operationID: UUID,
        itemIndex: Int
    ) throws -> URL {
        try backend.plannedFinalizeCaptureURL(
            for: source,
            operationID: operationID,
            itemIndex: itemIndex
        )
    }

    public func captureForFinalization(
        _ source: URL,
        to quarantine: URL,
        expectedIdentity: FileIdentity
    ) throws {
        try backend.captureForFinalization(
            source,
            to: quarantine,
            expectedIdentity: expectedIdentity
        )
    }

    public func permanentlyRemoveCapturedItem(
        _ quarantine: URL,
        expectedIdentity: FileIdentity
    ) throws {
        try backend.permanentlyRemoveCapturedItem(
            quarantine,
            expectedIdentity: expectedIdentity
        )
    }
}

public struct DirectoryTrashMover: TrashMoving, Sendable {
    public let trashDirectory: URL
    private let backend: FDRelativeTrashBackend
    public var eligibleTrashRoots: [String] { [backend.trashRoot.path] }

    public init(trashDirectory: URL) {
        self.init(trashDirectory: trashDirectory, fileSystem: FDRelativeFileSystem())
    }

    init(trashDirectory: URL, fileSystem: FDRelativeFileSystem) {
        let canonical = PathValidationPolicy.canonicalSystemAlias(
            trashDirectory.standardizedFileURL.path
        )
        self.trashDirectory = URL(fileURLWithPath: canonical, isDirectory: true)
        backend = FDRelativeTrashBackend(
            trashRoot: self.trashDirectory,
            ownerID: getuid(),
            fileSystem: fileSystem
        )
    }

    public func acquireOperationLock() throws -> FDRelativeDirectoryLock {
        try backend.acquireOperationLock()
    }

    public func plannedTrashURL(for source: URL, operationID: UUID, itemIndex: Int) throws -> URL {
        try backend.plannedTrashURL(for: source, operationID: operationID, itemIndex: itemIndex)
    }

    public func moveToTrash(
        _ source: URL,
        to destination: URL,
        expectedIdentity: FileIdentity
    ) throws -> URL {
        try backend.moveToTrash(source, to: destination, expectedIdentity: expectedIdentity)
    }

    public func restoreFromTrash(
        _ source: URL,
        expectedIdentity: FileIdentity,
        to destination: URL
    ) throws {
        try backend.restoreFromTrash(
            source,
            expectedIdentity: expectedIdentity,
            to: destination
        )
    }

    public func plannedFinalizeCaptureURL(
        for source: URL,
        operationID: UUID,
        itemIndex: Int
    ) throws -> URL {
        try backend.plannedFinalizeCaptureURL(
            for: source,
            operationID: operationID,
            itemIndex: itemIndex
        )
    }

    public func captureForFinalization(
        _ source: URL,
        to quarantine: URL,
        expectedIdentity: FileIdentity
    ) throws {
        try backend.captureForFinalization(
            source,
            to: quarantine,
            expectedIdentity: expectedIdentity
        )
    }

    public func permanentlyRemoveCapturedItem(
        _ quarantine: URL,
        expectedIdentity: FileIdentity
    ) throws {
        try backend.permanentlyRemoveCapturedItem(
            quarantine,
            expectedIdentity: expectedIdentity
        )
    }
}

private struct FDRelativeTrashBackend: Sendable {
    let trashRoot: URL
    let ownerID: UInt32
    let fileSystem: FDRelativeFileSystem

    init(trashRoot: URL, ownerID: UInt32, fileSystem: FDRelativeFileSystem) {
        let canonical = PathValidationPolicy.canonicalSystemAlias(
            trashRoot.standardizedFileURL.path
        )
        self.trashRoot = URL(fileURLWithPath: canonical, isDirectory: true)
        self.ownerID = ownerID
        self.fileSystem = fileSystem
    }

    func acquireOperationLock() throws -> FDRelativeDirectoryLock {
        _ = try fileSystem.ensurePrivateDirectory(
            atAbsolutePath: trashRoot.path,
            ownerID: ownerID
        )
        return try fileSystem.acquireExclusiveLock(
            atDirectoryAbsolutePath: trashRoot.path,
            ownerID: ownerID
        )
    }

    func plannedTrashURL(for _: URL, operationID: UUID, itemIndex: Int) throws -> URL {
        guard itemIndex >= 0 else {
            throw KeepItCleanError.invalidPath("Negative operation item index")
        }
        return trashRoot.appendingPathComponent(
            ".keepitclean-\(operationID.uuidString.lowercased())-\(itemIndex)"
        )
    }

    func moveToTrash(
        _ source: URL,
        to destination: URL,
        expectedIdentity: FileIdentity
    ) throws -> URL {
        try requireCurrentOwner(expectedIdentity, path: source.path)
        try requireImmediateChild(destination, of: trashRoot)
        try requireKeepItCleanTrashName(destination)
        _ = try fileSystem.ensurePrivateDirectory(
            atAbsolutePath: trashRoot.path,
            ownerID: ownerID,
            expectedDevice: expectedIdentity.device
        )
        let result = try fileSystem.renameExclusively(
            fromAbsolutePath: source.path,
            expectedIdentity: expectedIdentity,
            toAbsolutePath: destination.path
        )
        return URL(fileURLWithPath: result.destinationPath)
    }

    func restoreFromTrash(
        _ source: URL,
        expectedIdentity: FileIdentity,
        to destination: URL
    ) throws {
        try requireCurrentOwner(expectedIdentity, path: source.path)
        try requireImmediateChild(source, of: trashRoot)
        try requireKeepItCleanTrashName(source)
        _ = try fileSystem.renameExclusively(
            fromAbsolutePath: source.path,
            expectedIdentity: expectedIdentity,
            toAbsolutePath: destination.path
        )
    }

    func plannedFinalizeCaptureURL(
        for _: URL,
        operationID: UUID,
        itemIndex: Int
    ) throws -> URL {
        guard itemIndex >= 0 else {
            throw KeepItCleanError.invalidPath("Negative operation item index")
        }
        return trashRoot
            .appendingPathComponent(".keepitclean-finalize", isDirectory: true)
            .appendingPathComponent(
                "\(operationID.uuidString.lowercased())-\(itemIndex)"
            )
    }

    func captureForFinalization(
        _ source: URL,
        to quarantine: URL,
        expectedIdentity: FileIdentity
    ) throws {
        try requireCurrentOwner(expectedIdentity, path: source.path)
        try requireImmediateChild(source, of: trashRoot)
        try requireKeepItCleanTrashName(source)
        let quarantineParent = quarantine.deletingLastPathComponent()
        guard quarantineParent.deletingLastPathComponent().path == trashRoot.path,
              quarantineParent.lastPathComponent == ".keepitclean-finalize"
        else {
            throw KeepItCleanError.protectedPath(quarantine.path)
        }
        _ = try fileSystem.ensurePrivateDirectory(
            atAbsolutePath: quarantineParent.path,
            ownerID: ownerID,
            expectedDevice: expectedIdentity.device
        )
        _ = try fileSystem.renameExclusively(
            fromAbsolutePath: source.path,
            expectedIdentity: expectedIdentity,
            toAbsolutePath: quarantine.path
        )
    }

    func permanentlyRemoveCapturedItem(
        _ quarantine: URL,
        expectedIdentity: FileIdentity
    ) throws {
        try requireCurrentOwner(expectedIdentity, path: quarantine.path)
        let quarantineParent = quarantine.deletingLastPathComponent()
        guard quarantineParent.deletingLastPathComponent().path == trashRoot.path,
              quarantineParent.lastPathComponent == ".keepitclean-finalize"
        else {
            throw KeepItCleanError.protectedPath(quarantine.path)
        }
        try fileSystem.removeCapturedItemRecursively(
            atAbsolutePath: quarantine.path,
            expectedIdentity: expectedIdentity,
            privateParentAbsolutePath: quarantineParent.path,
            ownerID: ownerID
        )
    }

    private func requireCurrentOwner(_ identity: FileIdentity, path: String) throws {
        guard identity.ownerID == ownerID else {
            throw KeepItCleanError.ownerMismatch(path)
        }
    }

    private func requireImmediateChild(_ child: URL, of parent: URL) throws {
        let childPath = PathValidationPolicy.canonicalSystemAlias(
            child.standardizedFileURL.path
        )
        let parentPath = PathValidationPolicy.canonicalSystemAlias(
            parent.standardizedFileURL.path
        )
        guard URL(fileURLWithPath: childPath).deletingLastPathComponent().path == parentPath,
              childPath != parentPath
        else {
            throw KeepItCleanError.protectedPath(child.path)
        }
    }

    private func requireKeepItCleanTrashName(_ item: URL) throws {
        let prefix = ".keepitclean-"
        let name = item.lastPathComponent
        guard name.hasPrefix(prefix) else {
            throw KeepItCleanError.protectedPath(item.path)
        }
        let remainder = name.dropFirst(prefix.count)
        guard remainder.count > 37,
              UUID(uuidString: String(remainder.prefix(36))) != nil,
              remainder.dropFirst(36).first == "-",
              let index = Int(remainder.dropFirst(37)),
              index >= 0
        else {
            throw KeepItCleanError.invalidPath("Malformed KeepItClean Trash name: \(item.path)")
        }
    }
}

public final class FileMutationGateway: MutationGateway, @unchecked Sendable {
    private let validator: PathValidator
    private let reader: any FileSystemReading
    private let mover: any TrashMoving
    private let operationStore: any OperationStoring
    private let lock = NSLock()

    public init(
        validator: PathValidator,
        reader: any FileSystemReading,
        mover: any TrashMoving,
        operationStore: any OperationStoring
    ) {
        self.validator = validator
        self.reader = reader
        self.mover = mover
        self.operationStore = operationStore
    }

    public static func finalizeToken(for operationID: UUID) -> String {
        "FINALIZE-\(operationID.uuidString.prefix(8).uppercased())"
    }

    public func applyTrash(plan: CleanupPlan, hostID: String) throws -> OperationRecord {
        try withLock {
            guard plan.isValid(hostID: hostID) else {
                if Date() > plan.expiresAt { throw KeepItCleanError.planExpired }
                if plan.hostID != hostID { throw KeepItCleanError.hostMismatch }
                throw KeepItCleanError.unsupported("Cleanup plan has an invalid schema or review window.")
            }

            let selected = plan.selectedItems
            guard !selected.isEmpty else {
                throw KeepItCleanError.unsupported("Cleanup plan has no reviewed selections.")
            }

            // Preflight the complete reviewed set before moving the first item.
            // The fd-relative mover repeats identity checks while holding the
            // exact source/destination parent descriptors used by renameatx_np.
            let selectedPaths = selected.map { $0.candidate.path }.sorted()
            for (index, path) in selectedPaths.enumerated() {
                if selectedPaths[(index + 1)...].contains(where: {
                    $0 == path || $0.hasPrefix(path + "/")
                }) {
                    throw KeepItCleanError.invalidPath("Overlapping cleanup selections: \(path)")
                }
            }
            for planItem in selected {
                let candidate = planItem.candidate
                guard candidate.actionKind == .trash, !candidate.isBlocked else {
                    throw KeepItCleanError.blockedCandidate(candidate.path)
                }
                guard let identity = candidate.identity else {
                    throw KeepItCleanError.missingIdentity(candidate.path)
                }
                _ = try validator.validateExistingTarget(candidate.path, expectedIdentity: identity)
            }

            let operationLock = try mover.acquireOperationLock()
            defer { withExtendedLifetime(operationLock) {} }
            let operationID = UUID()
            var record = OperationRecord(
                id: operationID,
                planID: plan.id,
                kind: .trash,
                state: .running,
                items: try selected.enumerated().map { index, planItem in
                    let candidate = planItem.candidate
                    return OperationItem(
                        candidateID: candidate.id,
                        originalPath: candidate.path,
                        resultingTrashPath: try mover.plannedTrashURL(
                            for: URL(fileURLWithPath: candidate.path),
                            operationID: operationID,
                            itemIndex: index
                        ).path,
                        identity: candidate.identity!,
                        status: .pending
                    )
                }
            )
            try operationStore.append(operation: record)

            for index in selected.indices {
                let candidate = selected[index].candidate
                let identity = candidate.identity!
                var destination: URL?
                do {
                    _ = try validator.validateExistingTarget(candidate.path, expectedIdentity: identity)
                    guard let plannedPath = record.items[index].resultingTrashPath else {
                        throw KeepItCleanError.io("Missing pre-journaled Trash destination.")
                    }
                    let moved = try mover.moveToTrash(
                        URL(fileURLWithPath: candidate.path),
                        to: URL(fileURLWithPath: plannedPath),
                        expectedIdentity: identity
                    )
                    destination = moved
                    guard moved.path == plannedPath else {
                        throw KeepItCleanError.io(
                            "Trash mover returned a destination that differs from the journaled intent."
                        )
                    }
                    record.items[index].status = .movedToTrash

                    do {
                        // Persist the resulting Trash URL before any later
                        // verification can fail or the process can stop.
                        try operationStore.append(operation: record)
                    } catch {
                        do {
                            try mover.restoreFromTrash(
                                moved,
                                expectedIdentity: identity,
                                to: URL(fileURLWithPath: candidate.path)
                            )
                            destination = nil
                            record.items[index].status = .failed
                        } catch let rollbackError {
                            throw KeepItCleanError.io(
                                "History write and rollback both failed. Recover from \(moved.path): \(rollbackError.localizedDescription)"
                            )
                        }
                        throw error
                    }
                } catch {
                    if destination == nil {
                        record.items[index].status = .failed
                    }
                    record.items[index].message = error.localizedDescription
                }
                try operationStore.append(operation: record)
            }

            finish(&record)
            try operationStore.append(operation: record)
            return record
        }
    }

    /// Reconciles only an interrupted Trash APPLY whose intent was durably
    /// journaled before any rename. Recovery never moves or deletes an item:
    /// while holding the Trash operation lock it proves whether each reviewed
    /// inode is still at its original path or already at its deterministic
    /// Trash destination, then persists one terminal record. Any missing,
    /// duplicated, or identity-mismatched state remains running and fails
    /// closed for manual inspection.
    public func recoverInterruptedTrashApply(
        operation: OperationRecord
    ) throws -> OperationRecord {
        try withLock {
            guard operation.schemaVersion == keepItCleanSchemaVersion,
                  operation.kind == .trash,
                  operation.state == .running,
                  operation.completedAt == nil,
                  operation.planID != nil,
                  !operation.items.isEmpty
            else {
                throw KeepItCleanError.unsupported(
                    "Only an interrupted pre-journaled Trash APPLY can be recovered."
                )
            }
            let operationLock = try mover.acquireOperationLock()
            defer { withExtendedLifetime(operationLock) {} }

            var recovered = operation
            for index in recovered.items.indices {
                let item = recovered.items[index]
                guard let rawTrashPath = item.resultingTrashPath else {
                    throw KeepItCleanError.unsupported(
                        "Interrupted Trash APPLY is missing a pre-journaled destination."
                    )
                }
                let trashPath = try validateEligibleTrashItem(
                    rawTrashPath,
                    operationID: operation.id,
                    expectedItemIndex: index,
                    targetMayBeMissing: true
                )

                let first = try recoverySnapshot(
                    originalPath: item.originalPath,
                    trashPath: trashPath
                )
                let second = try recoverySnapshot(
                    originalPath: item.originalPath,
                    trashPath: trashPath
                )
                guard first.original == second.original,
                      first.trash == second.trash
                else {
                    throw KeepItCleanError.identityChanged(item.originalPath)
                }

                if let original = second.original,
                   !item.identity.matchesForMutation(original)
                {
                    throw KeepItCleanError.identityChanged(item.originalPath)
                }
                if let trash = second.trash,
                   !item.identity.matchesForMutation(trash)
                {
                    throw KeepItCleanError.identityChanged(trashPath)
                }

                switch item.status {
                case .pending:
                    switch (second.original, second.trash) {
                    case (nil, .some):
                        recovered.items[index].status = .movedToTrash
                        recovered.items[index].message = nil
                    case (.some, nil):
                        recovered.items[index].status = .failed
                        recovered.items[index].message =
                            "Recovered interrupted APPLY: reviewed item remained at its original path; no move occurred."
                    case (nil, nil):
                        throw KeepItCleanError.io(
                            "Interrupted APPLY is ambiguous because both paths are missing: \(item.originalPath)"
                        )
                    case (.some, .some):
                        throw KeepItCleanError.io(
                            "Interrupted APPLY is ambiguous because both paths exist: \(item.originalPath)"
                        )
                    }

                case .movedToTrash:
                    guard second.original == nil, second.trash != nil else {
                        throw KeepItCleanError.io(
                            "Journaled Trash move no longer has one exact Trash entry: \(item.originalPath)"
                        )
                    }
                    recovered.items[index].message = nil

                case .failed:
                    guard second.original != nil, second.trash == nil else {
                        throw KeepItCleanError.io(
                            "Failed Trash item has ambiguous filesystem state: \(item.originalPath)"
                        )
                    }

                case .skipped, .undone, .finalized, .executed:
                    throw KeepItCleanError.unsupported(
                        "Interrupted Trash APPLY contains an impossible item status."
                    )
                }
            }

            finish(&recovered)
            try operationStore.append(operation: recovered)
            return recovered
        }
    }

    public func undo(operation: OperationRecord) throws -> OperationRecord {
        try withLock {
            let sourceItems = operation.items.filter { $0.status == .movedToTrash }
            let operationLock = try mover.acquireOperationLock()
            defer { withExtendedLifetime(operationLock) {} }
            var record = OperationRecord(
                planID: operation.planID,
                kind: .undo,
                state: .running,
                items: sourceItems.map {
                    var pending = $0
                    pending.status = .pending
                    pending.message = nil
                    return pending
                }
            )
            try operationStore.append(operation: record)
            for index in sourceItems.indices {
                let item = sourceItems[index]
                guard let trashPath = item.resultingTrashPath else { continue }
                do {
                    let validatedTrashPath = try validateEligibleTrashItem(
                        trashPath,
                        operationID: operation.id
                    )
                    let current = try reader.identity(at: validatedTrashPath)
                    guard item.identity.matchesForMutation(current) else {
                        throw KeepItCleanError.identityChanged(validatedTrashPath)
                    }
                    _ = try validator.validateDestination(item.originalPath)
                    try mover.restoreFromTrash(
                        URL(fileURLWithPath: validatedTrashPath),
                        expectedIdentity: item.identity,
                        to: URL(fileURLWithPath: item.originalPath)
                    )
                    record.items[index].status = .undone
                } catch {
                    record.items[index].status = .failed
                    record.items[index].message = error.localizedDescription
                }
                try operationStore.append(operation: record)
            }
            finish(&record)
            try operationStore.append(operation: record)
            return record
        }
    }

    public func finalize(operation: OperationRecord, confirmationToken: String) throws -> OperationRecord {
        try withLock {
            guard confirmationToken == Self.finalizeToken(for: operation.id) else {
                throw KeepItCleanError.confirmationMismatch
            }

            let sourceItems = operation.items.filter { $0.status == .movedToTrash }
            let operationLock = try mover.acquireOperationLock()
            defer { withExtendedLifetime(operationLock) {} }
            let finalizeOperationID = UUID()
            var record = OperationRecord(
                id: finalizeOperationID,
                planID: operation.planID,
                kind: .finalize,
                state: .running,
                items: try sourceItems.enumerated().map { index, sourceItem in
                    let sourceURL = URL(
                        fileURLWithPath: sourceItem.resultingTrashPath ?? sourceItem.originalPath
                    )
                    var pending = sourceItem
                    pending.status = .pending
                    pending.message = nil
                    pending.resultingTrashPath = try mover.plannedFinalizeCaptureURL(
                        for: sourceURL,
                        operationID: finalizeOperationID,
                        itemIndex: index
                    ).path
                    return pending
                }
            )
            try operationStore.append(operation: record)
            for index in sourceItems.indices {
                let item = sourceItems[index]
                guard let trashPath = item.resultingTrashPath else { continue }
                do {
                    let validatedTrashPath = try validateEligibleTrashItem(
                        trashPath,
                        operationID: operation.id
                    )
                    let current = try reader.identity(at: validatedTrashPath)
                    guard item.identity.matchesForMutation(current) else {
                        throw KeepItCleanError.identityChanged(validatedTrashPath)
                    }
                    guard let quarantinePath = record.items[index].resultingTrashPath else {
                        throw KeepItCleanError.io("Missing pre-journaled finalize quarantine path.")
                    }
                    try mover.captureForFinalization(
                        URL(fileURLWithPath: validatedTrashPath),
                        to: URL(fileURLWithPath: quarantinePath),
                        expectedIdentity: item.identity
                    )
                    record.items[index].message = "Captured in private finalize quarantine."
                    try operationStore.append(operation: record)
                    try mover.permanentlyRemoveCapturedItem(
                        URL(fileURLWithPath: quarantinePath),
                        expectedIdentity: item.identity
                    )
                    record.items[index].status = .finalized
                    record.items[index].message = nil
                } catch {
                    record.items[index].status = .failed
                    record.items[index].message = error.localizedDescription
                }
                try operationStore.append(operation: record)
            }
            finish(&record)
            try operationStore.append(operation: record)
            return record
        }
    }

    /// Validates an operation-record Trash path independently of the mutable
    /// JSON history that supplied it. A filesystem Trash operation records the
    /// top-level item created by KeepItClean, so undo/finalize never need to
    /// accept nested descendants. Keeping this boundary to an immediate child
    /// also prevents lexical escapes such as `.Trash/../Documents/file`.
    private func validateEligibleTrashItem(
        _ rawPath: String,
        operationID: UUID,
        expectedItemIndex: Int? = nil,
        targetMayBeMissing: Bool = false
    ) throws -> String {
        guard !rawPath.isEmpty, rawPath.hasPrefix("/") else {
            throw KeepItCleanError.invalidPath("Trash path must be absolute: \(rawPath)")
        }
        guard !rawPath.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw KeepItCleanError.invalidPath("Trash path contains control characters: \(rawPath)")
        }
        guard !rawPath.hasSuffix("/"), !rawPath.contains("//") else {
            throw KeepItCleanError.invalidPath("Trash path is not lexically canonical: \(rawPath)")
        }

        let rawComponents = rawPath.split(separator: "/", omittingEmptySubsequences: false)
        guard !rawComponents.contains("."), !rawComponents.contains("..") else {
            throw KeepItCleanError.invalidPath("Trash path contains dot traversal: \(rawPath)")
        }

        let canonicalPath = PathValidationPolicy.canonicalSystemAlias(rawPath)
        let standardizedPath = PathValidationPolicy.canonicalSystemAlias(
            URL(fileURLWithPath: canonicalPath).standardizedFileURL.path
        )
        guard canonicalPath == standardizedPath else {
            throw KeepItCleanError.invalidPath("Trash path is not canonical: \(rawPath)")
        }

        let eligibleRoot = try mover.eligibleTrashRoots.compactMap { rawRoot -> String? in
            let canonicalRoot = PathValidationPolicy.canonicalSystemAlias(rawRoot)
            let standardizedRoot = PathValidationPolicy.canonicalSystemAlias(
                URL(fileURLWithPath: canonicalRoot).standardizedFileURL.path
            )
            guard canonicalRoot == standardizedRoot else {
                throw KeepItCleanError.invalidPath(rawRoot)
            }
            let parent = URL(fileURLWithPath: canonicalPath).deletingLastPathComponent().path
            return parent == standardizedRoot ? standardizedRoot : nil
        }.first

        guard let eligibleRoot, canonicalPath != eligibleRoot else {
            throw KeepItCleanError.protectedPath(rawPath)
        }

        let basename = URL(fileURLWithPath: canonicalPath).lastPathComponent
        let operationPrefix = ".keepitclean-\(operationID.uuidString.lowercased())-"
        guard basename.hasPrefix(operationPrefix),
              let itemIndex = Int(basename.dropFirst(operationPrefix.count)),
              itemIndex >= 0,
              expectedItemIndex == nil || itemIndex == expectedItemIndex
        else {
            throw KeepItCleanError.protectedPath(
                "Trash item is not bound to operation \(operationID.uuidString): \(rawPath)"
            )
        }

        let rootIdentity = try validateNoSymlinkAncestry(eligibleRoot)
        guard rootIdentity.fileKind == .directory,
              rootIdentity.ownerID == validator.policy.currentUserID
        else {
            throw KeepItCleanError.ownerMismatch(eligibleRoot)
        }

        if targetMayBeMissing, !reader.fileExists(at: canonicalPath) {
            return canonicalPath
        }
        let targetIdentity = try validateNoSymlinkAncestry(canonicalPath)
        guard targetIdentity.fileKind != .symbolicLink else {
            throw KeepItCleanError.symbolicLink(canonicalPath)
        }
        guard targetIdentity.ownerID == validator.policy.currentUserID else {
            throw KeepItCleanError.ownerMismatch(canonicalPath)
        }
        guard targetIdentity.device == rootIdentity.device else {
            throw KeepItCleanError.mountRoot(canonicalPath)
        }
        return canonicalPath
    }

    private func recoverySnapshot(
        originalPath: String,
        trashPath: String
    ) throws -> (original: FileIdentity?, trash: FileIdentity?) {
        let original = try recoveryIdentityIfPresent(at: originalPath)
        if let original {
            _ = try validator.validateExistingTarget(
                originalPath,
                expectedIdentity: original
            )
        } else {
            _ = try validator.validateDestination(originalPath)
        }
        return (
            original: original,
            trash: try recoveryIdentityIfPresent(at: trashPath)
        )
    }

    /// `LocalFileSystemReader` performs both probes through no-follow,
    /// component-wise fd walks. Requiring absence twice at the snapshot level
    /// avoids interpreting a lookup error or a concurrent appearance as a
    /// recoverable move state.
    private func recoveryIdentityIfPresent(at path: String) throws -> FileIdentity? {
        guard reader.fileExists(at: path) else { return nil }
        do {
            return try reader.identity(at: path)
        } catch {
            if reader.fileExists(at: path) { throw error }
            throw KeepItCleanError.identityChanged(path)
        }
    }

    /// `URL.standardizedFileURL` is lexical only; walk each real path component
    /// with lstat-backed identity reads so an eligible Trash root cannot hide a
    /// user-created symlink in one of its ancestors.
    private func validateNoSymlinkAncestry(_ path: String) throws -> FileIdentity {
        var current = "/"
        var identity: FileIdentity?
        for component in NSString(string: path).pathComponents.dropFirst() {
            current = URL(fileURLWithPath: current, isDirectory: true)
                .appendingPathComponent(component)
                .path
            let inspected = try LocalFileSystemReader.readIdentity(at: current)
            guard inspected.fileKind != .symbolicLink else {
                throw KeepItCleanError.symbolicLink(current)
            }
            identity = inspected
        }
        guard let identity else {
            throw KeepItCleanError.protectedPath(path)
        }
        return identity
    }

    private func finish(_ record: inout OperationRecord) {
        let successes = record.items.filter {
            $0.status != .failed && $0.status != .skipped && $0.status != .pending
        }.count
        let hasProblems = record.items.contains {
            $0.status == .failed || $0.status == .skipped || $0.status == .pending || $0.message != nil
        }
        if record.items.isEmpty || successes == 0 {
            record.state = .failed
        } else if successes == record.items.count, !hasProblems {
            record.state = .completed
        } else {
            record.state = .partial
        }
        record.completedAt = Date()
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
