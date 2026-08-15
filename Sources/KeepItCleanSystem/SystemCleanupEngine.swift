import Foundation
import KeepItCleanCore
import KeepItCleanFS

public struct SystemCleanupEngine: Sendable {
    private let scanner: SystemCacheScanner
    private let store: SystemStateStore
    private let fileSystem: FDRelativeFileSystem
    private let reader: LocalFileSystemReader

    public init(
        scanner: SystemCacheScanner,
        store: SystemStateStore,
        fileSystem: FDRelativeFileSystem = FDRelativeFileSystem(),
        reader: LocalFileSystemReader = LocalFileSystemReader()
    ) {
        self.scanner = scanner
        self.store = store
        self.fileSystem = fileSystem
        self.reader = reader
    }

    public func scan(now: Date = Date()) throws -> SystemCleanupScanResult {
        let result = try scanner.scan(now: now)
        try store.save(plan: result.plan)
        return result
    }

    public func apply(
        planID: UUID,
        confirmationToken: String,
        now: Date = Date()
    ) throws -> SystemCleanupOperation {
        guard confirmationToken == Self.applyToken(for: planID) else {
            throw KeepItCleanError.confirmationMismatch
        }
        let plan = try store.loadPlan(id: planID)
        guard plan.schemaVersion == keepItCleanSchemaVersion,
              now <= plan.expiresAt,
              !plan.candidates.isEmpty
        else {
            throw KeepItCleanError.planExpired
        }

        let fresh = try scanner.scan(now: now).plan
        let freshByID = Dictionary(uniqueKeysWithValues: fresh.candidates.map { ($0.id, $0) })
        for reviewed in plan.candidates {
            guard let current = freshByID[reviewed.id],
                  current.path == reviewed.path,
                  reviewed.identity.matchesForMutation(current.identity)
            else {
                throw KeepItCleanError.identityChanged(reviewed.path)
            }
        }

        let operationID = UUID()
        let quarantine = try store.prepareQuarantine(operationID: operationID)
        var operation = SystemCleanupOperation(
            id: operationID,
            planID: plan.id,
            items: plan.candidates.enumerated().map { index, candidate in
                SystemCleanupOperationItem(
                    candidateID: candidate.id,
                    originalPath: candidate.path,
                    quarantinePath: quarantine.appendingPathComponent(
                        String(format: "%06d-%@", index, safeBasename(candidate.path))
                    ).path,
                    identity: candidate.identity
                )
            }
        )
        try store.save(operation: operation)

        for index in operation.items.indices {
            do {
                let item = operation.items[index]
                _ = try fileSystem.renameExclusively(
                    fromAbsolutePath: item.originalPath,
                    expectedIdentity: item.identity,
                    toAbsolutePath: item.quarantinePath
                )
                operation.items[index].status = .quarantined
            } catch {
                operation.items[index].status = .failed
                operation.items[index].message = error.localizedDescription
            }
            try store.save(operation: operation)
        }
        operation.completedAt = now
        operation.state = finalState(operation.items, success: .quarantined)
        try store.save(operation: operation)
        return operation
    }

    public func undo(operationID: UUID, now: Date = Date()) throws -> SystemCleanupOperation {
        var operation = try recoverIfNeeded(try store.loadOperation(id: operationID))
        guard operation.items.contains(where: { $0.status == .quarantined }) else {
            return operation
        }
        operation.action = .undo
        operation.state = .running
        operation.completedAt = nil
        for index in operation.items.indices where operation.items[index].status == .quarantined {
            operation.items[index].status = .pending
        }
        try store.save(operation: operation)
        for index in operation.items.indices where operation.items[index].status == .pending {
            do {
                let item = operation.items[index]
                _ = try fileSystem.renameExclusively(
                    fromAbsolutePath: item.quarantinePath,
                    expectedIdentity: item.identity,
                    toAbsolutePath: item.originalPath
                )
                operation.items[index].status = .restored
                operation.items[index].message = nil
            } catch {
                operation.items[index].status = .failed
                operation.items[index].message = error.localizedDescription
            }
            try store.save(operation: operation)
        }
        operation.completedAt = now
        operation.state = finalState(operation.items, success: .restored)
        try store.save(operation: operation)
        return operation
    }

    public func finalize(
        operationID: UUID,
        confirmationToken: String,
        now: Date = Date()
    ) throws -> SystemCleanupOperation {
        guard confirmationToken == Self.finalizeToken(for: operationID) else {
            throw KeepItCleanError.confirmationMismatch
        }
        var operation = try recoverIfNeeded(try store.loadOperation(id: operationID))
        guard operation.items.contains(where: { $0.status == .quarantined }) else {
            return operation
        }
        operation.action = .finalize
        operation.state = .running
        operation.completedAt = nil
        for index in operation.items.indices where operation.items[index].status == .quarantined {
            operation.items[index].status = .pending
        }
        try store.save(operation: operation)
        let privateParent = store.quarantineDirectory.appendingPathComponent(
            operation.id.uuidString,
            isDirectory: true
        )
        for index in operation.items.indices where operation.items[index].status == .pending {
            do {
                let item = operation.items[index]
                try fileSystem.removeCapturedItemRecursively(
                    atAbsolutePath: item.quarantinePath,
                    expectedIdentity: item.identity,
                    privateParentAbsolutePath: privateParent.path,
                    ownerID: store.ownerID,
                    maximumEntries: 1
                )
                operation.items[index].status = .finalized
                operation.items[index].message = nil
            } catch {
                operation.items[index].status = .failed
                operation.items[index].message = error.localizedDescription
            }
            try store.save(operation: operation)
        }
        operation.completedAt = now
        operation.state = finalState(operation.items, success: .finalized)
        try store.save(operation: operation)
        return operation
    }

    public static func finalizeToken(for operationID: UUID) -> String {
        "FINALIZE-SYSTEM-\(operationID.uuidString.prefix(8).uppercased())"
    }

    public static func applyToken(for planID: UUID) -> String {
        "SYSTEM-CLEAN-\(planID.uuidString.prefix(8).uppercased())"
    }

    private func recoverIfNeeded(
        _ input: SystemCleanupOperation
    ) throws -> SystemCleanupOperation {
        guard input.state == .running else { return input }
        var operation = input
        for index in operation.items.indices where operation.items[index].status == .pending {
            let item = operation.items[index]
            let original = try identityIfPresent(item.originalPath)
            let quarantine = try identityIfPresent(item.quarantinePath)
            switch operation.action {
            case .apply:
                switch (original, quarantine) {
                case (nil, let found?):
                    guard item.identity.matchesForMutation(found) else {
                        throw KeepItCleanError.identityChanged(item.quarantinePath)
                    }
                    operation.items[index].status = .quarantined
                case (let found?, nil):
                    guard item.identity.matchesForMutation(found) else {
                        throw KeepItCleanError.identityChanged(item.originalPath)
                    }
                    operation.items[index].status = .failed
                    operation.items[index].message = "Recovered: source remained in place."
                default:
                    throw ambiguous(item)
                }
            case .undo:
                switch (original, quarantine) {
                case (let found?, nil):
                    guard item.identity.matchesForMutation(found) else {
                        throw KeepItCleanError.identityChanged(item.originalPath)
                    }
                    operation.items[index].status = .restored
                case (nil, let found?):
                    guard item.identity.matchesForMutation(found) else {
                        throw KeepItCleanError.identityChanged(item.quarantinePath)
                    }
                    operation.items[index].status = .quarantined
                default:
                    throw ambiguous(item)
                }
            case .finalize:
                switch (original, quarantine) {
                case (nil, nil):
                    operation.items[index].status = .finalized
                case (nil, let found?):
                    guard item.identity.matchesForMutation(found) else {
                        throw KeepItCleanError.identityChanged(item.quarantinePath)
                    }
                    operation.items[index].status = .quarantined
                default:
                    throw ambiguous(item)
                }
            }
        }
        let expected: SystemCleanupItemStatus = switch operation.action {
        case .apply: .quarantined
        case .undo: .restored
        case .finalize: .finalized
        }
        operation.state = finalState(operation.items, success: expected)
        operation.completedAt = Date()
        try store.save(operation: operation)
        return operation
    }

    private func ambiguous(_ item: SystemCleanupOperationItem) -> KeepItCleanError {
        .io("Ambiguous privileged operation state for \(item.originalPath)")
    }

    private func identityIfPresent(_ path: String) throws -> FileIdentity? {
        try reader.identityIfPresent(at: path)
    }

    private func finalState(
        _ items: [SystemCleanupOperationItem],
        success: SystemCleanupItemStatus
    ) -> SystemCleanupOperationState {
        let successes = items.filter { $0.status == success }.count
        if successes == items.count {
            switch success {
            case .quarantined: return .quarantined
            case .restored: return .restored
            case .finalized: return .finalized
            default: return .failed
            }
        }
        return successes > 0 ? .partial : .failed
    }

    private func safeBasename(_ path: String) -> String {
        let raw = URL(fileURLWithPath: path).lastPathComponent
        let safe = raw.map { character -> Character in
            character.isLetter || character.isNumber || character == "." || character == "-"
                ? character : "_"
        }
        return String(safe.prefix(80))
    }
}
