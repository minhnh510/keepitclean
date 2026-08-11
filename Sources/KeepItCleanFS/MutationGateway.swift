import Foundation
import KeepItCleanCore

public protocol TrashMoving: Sendable {
    var eligibleTrashRoots: [String] { get }
    func moveToTrash(_ source: URL) throws -> URL
    func restoreFromTrash(_ source: URL, to destination: URL) throws
}

public struct SystemTrashMover: TrashMoving, Sendable {
    public let eligibleTrashRoots: [String]

    public init(homePath: String) {
        eligibleTrashRoots = [URL(fileURLWithPath: homePath).appendingPathComponent(".Trash").path]
    }

    public func moveToTrash(_ source: URL) throws -> URL {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: source, resultingItemURL: &resultingURL)
        guard let url = resultingURL as URL? else {
            throw KeepItCleanError.io("macOS did not return the Trash destination for \(source.path)")
        }
        return url
    }

    public func restoreFromTrash(_ source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }
}

public struct DirectoryTrashMover: TrashMoving, Sendable {
    public let trashDirectory: URL
    public var eligibleTrashRoots: [String] { [trashDirectory.path] }

    public init(trashDirectory: URL) {
        self.trashDirectory = trashDirectory
    }

    public func moveToTrash(_ source: URL) throws -> URL {
        try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        var destination = trashDirectory.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = trashDirectory.appendingPathComponent("\(UUID().uuidString)-\(source.lastPathComponent)")
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    public func restoreFromTrash(_ source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
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
            // Each item is revalidated again immediately before its own move,
            // closing both partial-plan and per-item TOCTOU windows.
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

            var record = OperationRecord(
                planID: plan.id,
                kind: .trash,
                state: .running,
                items: selected.map { planItem in
                    let candidate = planItem.candidate
                    return OperationItem(
                        candidateID: candidate.id,
                        originalPath: candidate.path,
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
                    let moved = try mover.moveToTrash(URL(fileURLWithPath: candidate.path))
                    destination = moved
                    record.items[index].resultingTrashPath = moved.path
                    record.items[index].status = .movedToTrash

                    do {
                        // Persist the resulting Trash URL before any later
                        // verification can fail or the process can stop.
                        try operationStore.append(operation: record)
                    } catch {
                        do {
                            try mover.restoreFromTrash(moved, to: URL(fileURLWithPath: candidate.path))
                            destination = nil
                            record.items[index].resultingTrashPath = nil
                            record.items[index].status = .failed
                        } catch let rollbackError {
                            throw KeepItCleanError.io(
                                "History write and rollback both failed. Recover from \(moved.path): \(rollbackError.localizedDescription)"
                            )
                        }
                        throw error
                    }

                    let movedIdentity = try reader.identity(at: moved.path)
                    guard identity.matchesForMutation(movedIdentity) else {
                        throw KeepItCleanError.identityChanged(moved.path)
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

    public func undo(operation: OperationRecord) throws -> OperationRecord {
        try withLock {
            let sourceItems = operation.items.filter { $0.status == .movedToTrash }
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
                    let validatedTrashPath = try validateEligibleTrashItem(trashPath)
                    let current = try reader.identity(at: validatedTrashPath)
                    guard item.identity.matchesForMutation(current) else {
                        throw KeepItCleanError.identityChanged(validatedTrashPath)
                    }
                    guard !reader.fileExists(at: item.originalPath) else {
                        throw KeepItCleanError.io("Original path is occupied: \(item.originalPath)")
                    }
                    _ = try validator.validateDestination(item.originalPath)
                    try mover.restoreFromTrash(
                        URL(fileURLWithPath: validatedTrashPath),
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
            var record = OperationRecord(
                planID: operation.planID,
                kind: .finalize,
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
                    let validatedTrashPath = try validateEligibleTrashItem(trashPath)
                    let current = try reader.identity(at: validatedTrashPath)
                    guard item.identity.matchesForMutation(current) else {
                        throw KeepItCleanError.identityChanged(validatedTrashPath)
                    }
                    try FileManager.default.removeItem(at: URL(fileURLWithPath: validatedTrashPath))
                    record.items[index].status = .finalized
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
    /// top-level item returned by FileManager, so undo/finalize never need to
    /// accept nested descendants. Keeping this boundary to an immediate child
    /// also prevents lexical escapes such as `.Trash/../Documents/file`.
    private func validateEligibleTrashItem(_ rawPath: String) throws -> String {
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

        let rootIdentity = try validateNoSymlinkAncestry(eligibleRoot)
        guard rootIdentity.fileKind == .directory,
              rootIdentity.ownerID == validator.policy.currentUserID
        else {
            throw KeepItCleanError.ownerMismatch(eligibleRoot)
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
