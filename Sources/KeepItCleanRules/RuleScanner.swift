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
                var adapterRequest = request
                if request.isHardcore, !adapter.descriptor.id.hasPrefix("hardcore.") {
                    // Keep the normal catalog as a fast inventory. Deep accounting is
                    // reserved for the explicitly requested retention adapters so a
                    // huge unrelated cache cannot stall the hardcore review.
                    adapterRequest.deep = false
                }
                candidates.append(contentsOf: try await adapter.scan(request: adapterRequest))
            } catch {
                issues.append(
                    ScanIssue(
                        message: "Rule \(adapter.descriptor.id) was incomplete: \(error.localizedDescription)"
                    )
                )
            }
        }

        if request.isHardcore {
            let hardcore = candidates.filter { $0.ruleID.hasPrefix("hardcore.") }
            candidates.removeAll { candidate in
                guard !candidate.ruleID.hasPrefix("hardcore.") else { return false }
                return hardcore.contains { aggressive in
                    candidate.path == aggressive.path
                        || isDescendant(candidate.path, of: aggressive.path)
                        || isDescendant(aggressive.path, of: candidate.path)
                }
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
