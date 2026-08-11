import Foundation

public let keepItCleanSchemaVersion = 1
public let keepItCleanVersion = "0.1.0"

public enum FileKind: String, Codable, CaseIterable, Sendable {
    case regularFile
    case directory
    case symbolicLink
    case other
}

public struct DiskUsage: Codable, Hashable, Sendable {
    public var logicalBytes: UInt64
    public var allocatedBytes: UInt64
    public var reclaimableBytes: UInt64
    public var fileCount: UInt64
    public var uniqueFileCount: UInt64

    public init(
        logicalBytes: UInt64 = 0,
        allocatedBytes: UInt64 = 0,
        reclaimableBytes: UInt64? = nil,
        fileCount: UInt64 = 0,
        uniqueFileCount: UInt64? = nil
    ) {
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.reclaimableBytes = min(reclaimableBytes ?? allocatedBytes, allocatedBytes)
        self.fileCount = fileCount
        self.uniqueFileCount = uniqueFileCount ?? fileCount
    }

    private enum CodingKeys: String, CodingKey {
        case logicalBytes
        case allocatedBytes
        case reclaimableBytes
        case fileCount
        case uniqueFileCount
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let logicalBytes = try container.decode(UInt64.self, forKey: .logicalBytes)
        let allocatedBytes = try container.decode(UInt64.self, forKey: .allocatedBytes)
        let fileCount = try container.decode(UInt64.self, forKey: .fileCount)
        self.init(
            logicalBytes: logicalBytes,
            allocatedBytes: allocatedBytes,
            reclaimableBytes: try container.decodeIfPresent(UInt64.self, forKey: .reclaimableBytes),
            fileCount: fileCount,
            uniqueFileCount: try container.decodeIfPresent(UInt64.self, forKey: .uniqueFileCount)
        )
    }

    public static let zero = DiskUsage()

    public static func + (lhs: DiskUsage, rhs: DiskUsage) -> DiskUsage {
        DiskUsage(
            logicalBytes: lhs.logicalBytes &+ rhs.logicalBytes,
            allocatedBytes: lhs.allocatedBytes &+ rhs.allocatedBytes,
            reclaimableBytes: lhs.reclaimableBytes &+ rhs.reclaimableBytes,
            fileCount: lhs.fileCount &+ rhs.fileCount,
            uniqueFileCount: lhs.uniqueFileCount &+ rhs.uniqueFileCount
        )
    }
}

public struct FileIdentity: Codable, Hashable, Sendable {
    public var device: UInt64
    public var inode: UInt64
    public var ownerID: UInt32
    public var fileKind: FileKind
    public var logicalBytes: UInt64
    public var allocatedBytes: UInt64
    public var modifiedAt: Date
    public var linkCount: UInt64
    public var reclaimableBytes: UInt64

    public init(
        device: UInt64,
        inode: UInt64,
        ownerID: UInt32,
        fileKind: FileKind,
        logicalBytes: UInt64,
        allocatedBytes: UInt64,
        modifiedAt: Date,
        linkCount: UInt64 = 1,
        reclaimableBytes: UInt64? = nil
    ) {
        self.device = device
        self.inode = inode
        self.ownerID = ownerID
        self.fileKind = fileKind
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.modifiedAt = modifiedAt
        self.linkCount = linkCount
        self.reclaimableBytes = min(reclaimableBytes ?? allocatedBytes, allocatedBytes)
    }

    private enum CodingKeys: String, CodingKey {
        case device
        case inode
        case ownerID
        case fileKind
        case logicalBytes
        case allocatedBytes
        case modifiedAt
        case linkCount
        case reclaimableBytes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let allocatedBytes = try container.decode(UInt64.self, forKey: .allocatedBytes)
        self.init(
            device: try container.decode(UInt64.self, forKey: .device),
            inode: try container.decode(UInt64.self, forKey: .inode),
            ownerID: try container.decode(UInt32.self, forKey: .ownerID),
            fileKind: try container.decode(FileKind.self, forKey: .fileKind),
            logicalBytes: try container.decode(UInt64.self, forKey: .logicalBytes),
            allocatedBytes: allocatedBytes,
            modifiedAt: try container.decode(Date.self, forKey: .modifiedAt),
            linkCount: try container.decodeIfPresent(UInt64.self, forKey: .linkCount) ?? 1,
            reclaimableBytes: try container.decodeIfPresent(UInt64.self, forKey: .reclaimableBytes)
        )
    }

    public func matchesForMutation(_ other: FileIdentity) -> Bool {
        device == other.device
            && inode == other.inode
            && ownerID == other.ownerID
            && fileKind == other.fileKind
            && linkCount == other.linkCount
            && modifiedAt == other.modifiedAt
    }
}

public enum CandidateActionKind: String, Codable, CaseIterable, Sendable {
    case trash
    case native
    case reportOnly
    case blocked
}

public enum RiskLevel: String, Codable, CaseIterable, Sendable {
    case low
    case review
    case high
}

public enum RebuildCost: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high
    case notApplicable
}

public enum ActiveState: String, Codable, CaseIterable, Sendable {
    case inactive
    case active
    case unknown
}

public enum ConfidenceLevel: String, Codable, CaseIterable, Sendable {
    case high
    case medium
    case low
}

public struct RuleDescriptor: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var category: String
    public var summary: String
    public var explicitNonTargets: [String]

    public init(
        id: String,
        name: String,
        category: String,
        summary: String,
        explicitNonTargets: [String] = []
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.summary = summary
        self.explicitNonTargets = explicitNonTargets
    }
}

public struct Candidate: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var ruleID: String
    public var ruleVersion: String
    public var category: String
    public var path: String
    public var displayName: String
    public var evidence: String
    public var identity: FileIdentity?
    public var actionKind: CandidateActionKind
    public var risk: RiskLevel
    public var rebuildCost: RebuildCost
    public var confidence: ConfidenceLevel
    public var activeState: ActiveState
    public var defaultSelected: Bool
    public var blockReason: String?

    public init(
        id: String? = nil,
        ruleID: String,
        ruleVersion: String = "1",
        category: String,
        path: String,
        displayName: String,
        evidence: String,
        identity: FileIdentity?,
        actionKind: CandidateActionKind,
        risk: RiskLevel,
        rebuildCost: RebuildCost,
        confidence: ConfidenceLevel = .high,
        activeState: ActiveState,
        defaultSelected: Bool,
        blockReason: String? = nil
    ) {
        self.id = id ?? "\(ruleID):\(path)"
        self.ruleID = ruleID
        self.ruleVersion = ruleVersion
        self.category = category
        self.path = path
        self.displayName = displayName
        self.evidence = evidence
        self.identity = identity
        self.actionKind = actionKind
        self.risk = risk
        self.rebuildCost = rebuildCost
        self.confidence = confidence
        self.activeState = activeState
        self.defaultSelected = defaultSelected
        self.blockReason = blockReason
    }

    public var isBlocked: Bool {
        actionKind == .blocked || blockReason != nil || activeState != .inactive
    }

    public var reclaimableBytes: UInt64 {
        guard actionKind == .trash, !isBlocked else { return 0 }
        return identity?.reclaimableBytes ?? 0
    }
}

public struct ScanRequest: Codable, Hashable, Sendable {
    public var roots: [String]
    public var homePath: String
    public var deep: Bool
    public var now: Date

    public init(roots: [String], homePath: String, deep: Bool = false, now: Date = Date()) {
        self.roots = roots
        self.homePath = homePath
        self.deep = deep
        self.now = now
    }
}

public struct ScanIssue: Codable, Hashable, Sendable {
    public var path: String?
    public var message: String

    public init(path: String? = nil, message: String) {
        self.path = path
        self.message = message
    }
}

public struct ScanReport: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var id: UUID
    public var scannedAt: Date
    public var durationSeconds: Double
    public var candidates: [Candidate]
    public var issues: [ScanIssue]
    public var partial: Bool

    public init(
        schemaVersion: Int = keepItCleanSchemaVersion,
        id: UUID = UUID(),
        scannedAt: Date = Date(),
        durationSeconds: Double,
        candidates: [Candidate],
        issues: [ScanIssue] = [],
        partial: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.scannedAt = scannedAt
        self.durationSeconds = durationSeconds
        self.candidates = candidates
        self.issues = issues
        self.partial = partial
    }

    public var totalReclaimableBytes: UInt64 {
        candidates.reduce(0) { $0 &+ $1.reclaimableBytes }
    }

    public var totalAllocatedBytes: UInt64 {
        candidates.reduce(0) { $0 &+ ($1.identity?.allocatedBytes ?? 0) }
    }

    public var totalLogicalBytes: UInt64 {
        candidates.reduce(0) { $0 &+ ($1.identity?.logicalBytes ?? 0) }
    }
}

public struct CleanupPlanItem: Codable, Hashable, Sendable {
    public var candidate: Candidate
    public var selected: Bool

    public init(candidate: Candidate, selected: Bool? = nil) {
        self.candidate = candidate
        self.selected = selected ?? candidate.defaultSelected
    }
}

public struct CleanupPlan: Codable, Hashable, Identifiable, Sendable {
    public var schemaVersion: Int
    public var id: UUID
    public var createdAt: Date
    public var expiresAt: Date
    public var hostID: String
    public var items: [CleanupPlanItem]

    public init(
        schemaVersion: Int = keepItCleanSchemaVersion,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        hostID: String,
        items: [CleanupPlanItem]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(30 * 60)
        self.hostID = hostID
        self.items = items
    }

    public func isValid(at date: Date = Date(), hostID currentHostID: String) -> Bool {
        schemaVersion == keepItCleanSchemaVersion
            && hasValidReviewWindow
            && date >= createdAt
            && date <= expiresAt
            && hostID == currentHostID
    }

    public var hasValidReviewWindow: Bool {
        expiresAt >= createdAt
            && expiresAt <= createdAt.addingTimeInterval(30 * 60)
    }

    public var selectedItems: [CleanupPlanItem] {
        items.filter(\.selected)
    }
}

public enum OperationKind: String, Codable, Sendable {
    case trash
    case undo
    case finalize
    case native
}

public enum OperationState: String, Codable, Sendable {
    case planned
    case running
    case completed
    case partial
    case failed
}

public enum OperationItemStatus: String, Codable, Sendable {
    case pending
    case movedToTrash
    case undone
    case finalized
    case executed
    case skipped
    case failed
}

public struct OperationItem: Codable, Hashable, Sendable {
    public var candidateID: String
    public var originalPath: String
    public var resultingTrashPath: String?
    public var identity: FileIdentity
    public var status: OperationItemStatus
    public var message: String?

    public init(
        candidateID: String,
        originalPath: String,
        resultingTrashPath: String? = nil,
        identity: FileIdentity,
        status: OperationItemStatus,
        message: String? = nil
    ) {
        self.candidateID = candidateID
        self.originalPath = originalPath
        self.resultingTrashPath = resultingTrashPath
        self.identity = identity
        self.status = status
        self.message = message
    }
}

public struct OperationRecord: Codable, Hashable, Identifiable, Sendable {
    public var schemaVersion: Int
    public var id: UUID
    public var planID: UUID?
    public var kind: OperationKind
    public var state: OperationState
    public var startedAt: Date
    public var completedAt: Date?
    public var items: [OperationItem]

    public init(
        schemaVersion: Int = keepItCleanSchemaVersion,
        id: UUID = UUID(),
        planID: UUID? = nil,
        kind: OperationKind,
        state: OperationState,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        items: [OperationItem] = []
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.planID = planID
        self.kind = kind
        self.state = state
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.items = items
    }
}

public struct NativeActionDescriptor: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var summary: String
    public var executable: String
    public var arguments: [String]
    public var risk: RiskLevel
    public var affectedState: String

    public init(
        id: String,
        title: String,
        summary: String,
        executable: String,
        arguments: [String],
        risk: RiskLevel = .high,
        affectedState: String
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.executable = executable
        self.arguments = arguments
        self.risk = risk
        self.affectedState = affectedState
    }
}

public struct NativeActionPlan: Codable, Hashable, Identifiable, Sendable {
    public var schemaVersion: Int
    public var id: UUID
    public var descriptor: NativeActionDescriptor
    public var createdAt: Date
    public var expiresAt: Date
    public var hostID: String
    public var confirmationToken: String

    public init(
        schemaVersion: Int = keepItCleanSchemaVersion,
        id: UUID = UUID(),
        descriptor: NativeActionDescriptor,
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        hostID: String,
        confirmationToken: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.descriptor = descriptor
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(10 * 60)
        self.hostID = hostID
        self.confirmationToken = confirmationToken ?? "RUN-\(id.uuidString.prefix(8).uppercased())"
    }

    public func isValid(at date: Date = Date(), hostID currentHostID: String) -> Bool {
        schemaVersion == keepItCleanSchemaVersion
            && hasValidReviewWindow
            && date >= createdAt
            && date <= expiresAt
            && hostID == currentHostID
    }

    public var hasValidReviewWindow: Bool {
        expiresAt >= createdAt
            && expiresAt <= createdAt.addingTimeInterval(10 * 60)
    }
}
