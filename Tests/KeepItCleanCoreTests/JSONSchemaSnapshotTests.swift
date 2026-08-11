import Foundation
import Testing
@testable import KeepItCleanCore

private let snapshotDate = Date(timeIntervalSince1970: 1_704_067_200)

private var snapshotIdentity: FileIdentity {
    FileIdentity(
        device: 42,
        inode: 99,
        ownerID: 501,
        fileKind: .directory,
        logicalBytes: 8_192,
        allocatedBytes: 4_096,
        modifiedAt: snapshotDate
    )
}

private var snapshotCandidate: Candidate {
    Candidate(
        id: "rule.fixture:/tmp/cache",
        ruleID: "rule.fixture",
        ruleVersion: "1",
        category: "Fixture",
        path: "/tmp/cache",
        displayName: "cache",
        evidence: "Deterministic schema fixture.",
        identity: snapshotIdentity,
        actionKind: .trash,
        risk: .low,
        rebuildCost: .low,
        confidence: .high,
        activeState: .inactive,
        defaultSelected: true,
        blockReason: "snapshot"
    )
}

private func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func keys(_ object: [String: Any]) -> [String] {
    object.keys.sorted()
}

@Test func candidateJSONSchemaV1Snapshot() throws {
    let object = try encodedObject(snapshotCandidate)

    #expect(keys(object) == [
        "actionKind", "activeState", "blockReason", "category", "confidence",
        "defaultSelected", "displayName", "evidence", "id", "identity", "path",
        "rebuildCost", "risk", "ruleID", "ruleVersion",
    ])
    let identity = try #require(object["identity"] as? [String: Any])
    #expect(keys(identity) == [
        "allocatedBytes", "device", "fileKind", "inode", "linkCount",
        "logicalBytes", "modifiedAt", "ownerID", "reclaimableBytes",
    ])
}

@Test func cleanupPlanJSONSchemaV1Snapshot() throws {
    let plan = CleanupPlan(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        createdAt: snapshotDate,
        expiresAt: snapshotDate.addingTimeInterval(1_800),
        hostID: "fixture-host",
        items: [CleanupPlanItem(candidate: snapshotCandidate, selected: true)]
    )
    let object = try encodedObject(plan)

    #expect(keys(object) == ["createdAt", "expiresAt", "hostID", "id", "items", "schemaVersion"])
    #expect(object["schemaVersion"] as? Int == keepItCleanSchemaVersion)
    let items = try #require(object["items"] as? [[String: Any]])
    #expect(keys(try #require(items.first)) == ["candidate", "selected"])
}

@Test func operationRecordJSONSchemaV1Snapshot() throws {
    let operation = OperationRecord(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        planID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
        kind: .trash,
        state: .completed,
        startedAt: snapshotDate,
        completedAt: snapshotDate.addingTimeInterval(1),
        items: [OperationItem(
            candidateID: snapshotCandidate.id,
            originalPath: snapshotCandidate.path,
            resultingTrashPath: "/tmp/.Trash/cache",
            identity: snapshotIdentity,
            status: .movedToTrash,
            message: "fixture"
        )]
    )
    let object = try encodedObject(operation)

    #expect(keys(object) == [
        "completedAt", "id", "items", "kind", "planID", "schemaVersion", "startedAt", "state",
    ])
    #expect(object["schemaVersion"] as? Int == keepItCleanSchemaVersion)
    let items = try #require(object["items"] as? [[String: Any]])
    #expect(keys(try #require(items.first)) == [
        "candidateID", "identity", "message", "originalPath", "resultingTrashPath", "status",
    ])
}
