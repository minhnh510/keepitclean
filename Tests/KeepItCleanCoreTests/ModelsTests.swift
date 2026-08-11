import Foundation
import Testing
@testable import KeepItCleanCore

@Test func cleanupPlanExpiresAndIsHostBound() {
    let createdAt = Date(timeIntervalSince1970: 1_000)
    let plan = CleanupPlan(createdAt: createdAt, hostID: "host-a", items: [])

    #expect(plan.isValid(at: createdAt.addingTimeInterval(1_799), hostID: "host-a"))
    #expect(!plan.isValid(at: createdAt.addingTimeInterval(1_801), hostID: "host-a"))
    #expect(!plan.isValid(at: createdAt, hostID: "host-b"))
    #expect(!plan.isValid(at: createdAt.addingTimeInterval(-1), hostID: "host-a"))

    var extended = plan
    extended.expiresAt = createdAt.addingTimeInterval(1_801)
    #expect(!extended.hasValidReviewWindow)
    #expect(!extended.isValid(at: createdAt, hostID: "host-a"))
}

@Test func nativeActionPlanCannotExtendItsTenMinuteWindow() {
    let createdAt = Date(timeIntervalSince1970: 1_000)
    let descriptor = NativeActionDescriptor(
        id: "fixture.inspect",
        title: "Inspect fixture",
        summary: "Read-only fixture.",
        executable: "fixture",
        arguments: ["status"],
        risk: .low,
        affectedState: "fixture"
    )
    let plan = NativeActionPlan(
        descriptor: descriptor,
        createdAt: createdAt,
        hostID: "host-a"
    )
    #expect(plan.isValid(at: createdAt.addingTimeInterval(599), hostID: "host-a"))

    var extended = plan
    extended.expiresAt = createdAt.addingTimeInterval(601)
    #expect(!extended.hasValidReviewWindow)
    #expect(!extended.isValid(at: createdAt, hostID: "host-a"))
}

@Test func candidateIsBlockedForUnknownOrActiveState() {
    let identity = FileIdentity(
        device: 1,
        inode: 2,
        ownerID: 501,
        fileKind: .directory,
        logicalBytes: 10,
        allocatedBytes: 8,
        modifiedAt: .distantPast
    )
    let unknown = Candidate(
        ruleID: "test",
        category: "Test",
        path: "/tmp/test",
        displayName: "test",
        evidence: "fixture",
        identity: identity,
        actionKind: .trash,
        risk: .low,
        rebuildCost: .low,
        activeState: .unknown,
        defaultSelected: true
    )

    #expect(unknown.isBlocked)
    #expect(unknown.reclaimableBytes == 0)
    #expect(unknown.identity?.allocatedBytes == 8)
}

@Test func fileIdentityRequiresStableMutationFields() {
    let date = Date(timeIntervalSince1970: 100)
    let lhs = FileIdentity(
        device: 1,
        inode: 2,
        ownerID: 501,
        fileKind: .regularFile,
        logicalBytes: 100,
        allocatedBytes: 4_096,
        modifiedAt: date
    )
    var rhs = lhs
    #expect(lhs.matchesForMutation(rhs))
    rhs.inode = 3
    #expect(!lhs.matchesForMutation(rhs))
    rhs = lhs
    rhs.linkCount = 2
    #expect(!lhs.matchesForMutation(rhs))
}

@Test func modelsRoundTripThroughJSON() throws {
    let plan = CleanupPlan(hostID: "host", items: [])
    let data = try JSONEncoder().encode(plan)
    let decoded = try JSONDecoder().decode(CleanupPlan.self, from: data)
    #expect(decoded == plan)
    #expect(decoded.schemaVersion == 1)
}

@Test func legacyUsageAndIdentityJSONUseConservativeDefaults() throws {
    let identity = FileIdentity(
        device: 1,
        inode: 2,
        ownerID: 501,
        fileKind: .regularFile,
        logicalBytes: 8_192,
        allocatedBytes: 4_096,
        modifiedAt: Date(timeIntervalSince1970: 100)
    )
    var identityObject = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)) as? [String: Any]
    )
    identityObject.removeValue(forKey: "linkCount")
    identityObject.removeValue(forKey: "reclaimableBytes")
    let legacyIdentity = try JSONDecoder().decode(
        FileIdentity.self,
        from: JSONSerialization.data(withJSONObject: identityObject)
    )
    #expect(legacyIdentity.linkCount == 1)
    #expect(legacyIdentity.reclaimableBytes == legacyIdentity.allocatedBytes)

    let usage = DiskUsage(
        logicalBytes: 8_192,
        allocatedBytes: 4_096,
        fileCount: 2,
        uniqueFileCount: 1
    )
    var usageObject = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(usage)) as? [String: Any]
    )
    usageObject.removeValue(forKey: "reclaimableBytes")
    let legacyUsage = try JSONDecoder().decode(
        DiskUsage.self,
        from: JSONSerialization.data(withJSONObject: usageObject)
    )
    #expect(legacyUsage.reclaimableBytes == legacyUsage.allocatedBytes)
    #expect(legacyUsage.uniqueFileCount == 1)
}

@Test func reclaimEstimateCannotExceedAllocatedBytes() throws {
    let identity = FileIdentity(
        device: 1,
        inode: 2,
        ownerID: 501,
        fileKind: .regularFile,
        logicalBytes: 8_192,
        allocatedBytes: 4_096,
        modifiedAt: .distantPast,
        reclaimableBytes: 8_192
    )
    #expect(identity.reclaimableBytes == 4_096)

    var object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)) as? [String: Any]
    )
    object["reclaimableBytes"] = 16_384
    let decoded = try JSONDecoder().decode(
        FileIdentity.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
    #expect(decoded.reclaimableBytes == decoded.allocatedBytes)

    let usage = DiskUsage(
        logicalBytes: 8_192,
        allocatedBytes: 4_096,
        reclaimableBytes: 8_192,
        fileCount: 1
    )
    #expect(usage.reclaimableBytes == 4_096)
}
