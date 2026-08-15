import Foundation
import KeepItCleanCore

public let keepItCleanPrivilegedHelperPath =
    "/Library/PrivilegedHelperTools/com.minhnh510.keepitclean.helper"

public struct SystemCleanupCandidate: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let ruleID: String
    public let path: String
    public let displayName: String
    public let reason: String
    public let identity: FileIdentity

    public init(
        ruleID: String,
        path: String,
        displayName: String,
        reason: String,
        identity: FileIdentity
    ) {
        id = "\(ruleID):\(path)"
        self.ruleID = ruleID
        self.path = path
        self.displayName = displayName
        self.reason = reason
        self.identity = identity
    }

    public var reclaimableBytes: UInt64 { identity.reclaimableBytes }
}

public struct SystemCleanupPlan: Codable, Hashable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let createdAt: Date
    public let expiresAt: Date
    public let candidates: [SystemCleanupCandidate]

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        candidates: [SystemCleanupCandidate]
    ) {
        schemaVersion = keepItCleanSchemaVersion
        self.id = id
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(15 * 60)
        self.candidates = candidates
    }

    public var reclaimableBytes: UInt64 {
        candidates.reduce(0) { partial, candidate in
            let (sum, overflow) = partial.addingReportingOverflow(candidate.reclaimableBytes)
            return overflow ? .max : sum
        }
    }
}

public enum SystemCleanupItemStatus: String, Codable, Hashable, Sendable {
    case pending
    case quarantined
    case restored
    case finalized
    case failed
}

public struct SystemCleanupOperationItem: Codable, Hashable, Sendable {
    public let candidateID: String
    public let originalPath: String
    public let quarantinePath: String
    public let identity: FileIdentity
    public var status: SystemCleanupItemStatus
    public var message: String?

    public init(
        candidateID: String,
        originalPath: String,
        quarantinePath: String,
        identity: FileIdentity,
        status: SystemCleanupItemStatus = .pending,
        message: String? = nil
    ) {
        self.candidateID = candidateID
        self.originalPath = originalPath
        self.quarantinePath = quarantinePath
        self.identity = identity
        self.status = status
        self.message = message
    }
}

public enum SystemCleanupOperationState: String, Codable, Hashable, Sendable {
    case running
    case quarantined
    case restored
    case finalized
    case partial
    case failed
}

public enum SystemCleanupAction: String, Codable, Hashable, Sendable {
    case apply
    case undo
    case finalize
}

public struct SystemCleanupOperation: Codable, Hashable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let planID: UUID
    public let createdAt: Date
    public var action: SystemCleanupAction
    public var completedAt: Date?
    public var state: SystemCleanupOperationState
    public var items: [SystemCleanupOperationItem]

    public init(
        id: UUID = UUID(),
        planID: UUID,
        createdAt: Date = Date(),
        action: SystemCleanupAction = .apply,
        state: SystemCleanupOperationState = .running,
        items: [SystemCleanupOperationItem]
    ) {
        schemaVersion = keepItCleanSchemaVersion
        self.id = id
        self.planID = planID
        self.createdAt = createdAt
        self.action = action
        completedAt = nil
        self.state = state
        self.items = items
    }
}

public struct SystemCleanupScanResult: Codable, Hashable, Sendable {
    public let plan: SystemCleanupPlan
    public let warnings: [String]

    public init(plan: SystemCleanupPlan, warnings: [String] = []) {
        self.plan = plan
        self.warnings = warnings
    }
}
