import Foundation
import KeepItCleanCore

public struct RuleScanner: CandidateScanning, Sendable {
    private let adapters: [any RuleAdapter]

    public init(adapters: [any RuleAdapter]) {
        self.adapters = adapters
    }

    public init(
        catalog: RuleCatalog,
        homePath: String,
        roots: [String]
    ) {
        self.adapters = catalog.defaultAdapters(homePath: homePath, roots: roots)
    }

    public func scan(request: ScanRequest) async -> ScanReport {
        let startedAt = Date()
        var candidates: [Candidate] = []
        var issues: [ScanIssue] = []

        for adapter in adapters {
            do {
                candidates.append(contentsOf: try await adapter.scan(request: request))
            } catch {
                issues.append(
                    ScanIssue(
                        message: "Rule \(adapter.descriptor.id) was incomplete: \(error.localizedDescription)"
                    )
                )
            }
        }

        candidates.sort { lhs, rhs in
            if lhs.category != rhs.category { return lhs.category < rhs.category }
            if lhs.path != rhs.path { return lhs.path < rhs.path }
            return lhs.ruleID < rhs.ruleID
        }
        issues.sort {
            ($0.path ?? "", $0.message) < ($1.path ?? "", $1.message)
        }

        return ScanReport(
            scannedAt: request.now,
            durationSeconds: max(0, Date().timeIntervalSince(startedAt)),
            candidates: candidates,
            issues: issues,
            partial: !issues.isEmpty
        )
    }
}

public typealias ScanCoordinator = RuleScanner
