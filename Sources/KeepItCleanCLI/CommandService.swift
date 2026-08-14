import Foundation
import KeepItCleanCore

struct PlannedScan: Sendable {
    let report: ScanReport
    let plan: CleanupPlan
    let planURL: URL
}

struct NativeActionListing: Sendable, Encodable {
    let descriptor: NativeActionDescriptor
    let isReadOnly: Bool
    let confirmationHint: String
}

struct DoctorCheck: Sendable, Encodable {
    let id: String
    let status: String
    let message: String
}

protocol KeepCommandServing: Sendable {
    func scan(roots: [String], deep: Bool, hardcore: Bool) async throws -> PlannedScan
    func analyze(path: String, deep: Bool) async throws -> PlannedScan
    func loadPlan(reference: String) throws -> CleanupPlan
    func save(plan: CleanupPlan) throws -> URL
    func applyTrash(plan: CleanupPlan) async throws -> OperationRecord
    func undo(operationID: UUID) throws -> OperationRecord
    func finalize(operationID: UUID, confirmationToken: String) throws -> OperationRecord
    func history(limit: Int) throws -> [OperationRecord]
    func ruleDescriptors() -> [RuleDescriptor]
    func doctor() async -> [DoctorCheck]
    func nativeActions() -> [NativeActionListing]
    func nativeActionIsReadOnly(actionID: String) -> Bool?
    func makeNativeActionPlan(actionID: String) throws -> (NativeActionPlan, URL)
    func loadNativeActionPlan(reference: String) throws -> NativeActionPlan
    func runNativeAction(plan: NativeActionPlan, confirmationToken: String) throws -> OperationRecord
}

extension KeepCommandServing {
    func scan(roots: [String], deep: Bool) async throws -> PlannedScan {
        try await scan(roots: roots, deep: deep, hardcore: false)
    }
}

enum KeepRuntimeFactory {
    static func make() -> any KeepCommandServing {
        ProductionCommandService()
    }
}
