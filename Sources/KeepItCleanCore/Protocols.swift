import Foundation

public protocol RuleAdapter: Sendable {
    var descriptor: RuleDescriptor { get }
    func scan(request: ScanRequest) async throws -> [Candidate]
}

public protocol CandidateScanning: Sendable {
    func scan(request: ScanRequest) async -> ScanReport
}

public protocol FileSystemReading: Sendable {
    func fileExists(at path: String) -> Bool
    func identity(at path: String) throws -> FileIdentity
    func usage(at path: String) throws -> DiskUsage
    func immediateChildren(at path: String) throws -> [String]
    func readPrefix(at path: String, maxBytes: Int) throws -> Data
}

public protocol ProcessProbing: Sendable {
    func state(matching processNames: [String]) -> ActiveState
}

public protocol PlanStoring: Sendable {
    func save(plan: CleanupPlan) throws -> URL
    func loadPlan(id: UUID) throws -> CleanupPlan
    func loadPlan(at url: URL) throws -> CleanupPlan
    func save(nativePlan: NativeActionPlan) throws -> URL
    func loadNativePlan(id: UUID) throws -> NativeActionPlan
    func loadNativePlan(at url: URL) throws -> NativeActionPlan
}

public protocol OperationStoring: Sendable {
    func append(operation: OperationRecord) throws
    func operation(id: UUID) throws -> OperationRecord
    func operations(limit: Int) throws -> [OperationRecord]
}

public protocol MutationGateway: Sendable {
    func applyTrash(plan: CleanupPlan, hostID: String) throws -> OperationRecord
    func recoverInterruptedTrashApply(operation: OperationRecord) throws -> OperationRecord
    func undo(operation: OperationRecord) throws -> OperationRecord
    func finalize(operation: OperationRecord, confirmationToken: String) throws -> OperationRecord
}

public protocol NativeActionRunning: Sendable {
    func run(plan: NativeActionPlan, confirmationToken: String) throws -> OperationRecord
}

public protocol HostIdentifying: Sendable {
    func currentHostID() -> String
}

public enum KeepItCleanError: Error, LocalizedError, Equatable, Sendable {
    case invalidPath(String)
    case protectedPath(String)
    case symbolicLink(String)
    case mountRoot(String)
    case ownerMismatch(String)
    case identityChanged(String)
    case planExpired
    case hostMismatch
    case blockedCandidate(String)
    case missingIdentity(String)
    case operationNotFound(String)
    case confirmationMismatch
    case unsupported(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPath(path): "Invalid path: \(path)"
        case let .protectedPath(path): "Protected path: \(path)"
        case let .symbolicLink(path): "Symbolic links are not eligible: \(path)"
        case let .mountRoot(path): "Mount roots are not eligible: \(path)"
        case let .ownerMismatch(path): "Path is not owned by the current user: \(path)"
        case let .identityChanged(path): "Path identity changed after review: \(path)"
        case .planExpired: "Cleanup plan expired; scan again."
        case .hostMismatch: "Cleanup plan belongs to a different host."
        case let .blockedCandidate(reason): "Candidate is blocked: \(reason)"
        case let .missingIdentity(path): "Candidate has no file identity: \(path)"
        case let .operationNotFound(id): "Operation not found: \(id)"
        case .confirmationMismatch: "Confirmation token does not match."
        case let .unsupported(message): message
        case let .io(message): message
        }
    }
}
