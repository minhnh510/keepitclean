import Foundation
import KeepItCleanCore
import KeepItCleanTUI

enum TUIAdapter {
    private static let parentScopedRules: Set<String> = [
        "project.artifacts",
        "cachedir-tag.valid",
    ]

    static func state(report: ScanReport) -> TUIState {
        state(candidates: report.candidates)
    }

    static func state(plan: CleanupPlan) -> TUIState {
        let candidates = plan.items.map { item -> Candidate in
            var candidate = item.candidate
            candidate.defaultSelected = item.selected
                && candidate.actionKind == .trash
                && !candidate.isBlocked
            return candidate
        }
        return state(candidates: candidates)
    }

    private static func state(candidates: [Candidate]) -> TUIState {
        let grouped = Dictionary(grouping: candidates, by: \.category)
        let categories = grouped.keys.sorted().map { categoryName in
            let candidates = grouped[categoryName, default: []]
                .sorted { lhs, rhs in
                    if lhs.reclaimableBytes == rhs.reclaimableBytes {
                        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                    }
                    return lhs.reclaimableBytes > rhs.reclaimableBytes
                }
            return TUICategory(
                id: categoryName,
                title: categoryName,
                summary: "Rule-backed developer storage candidates",
                items: candidates.map(item)
            )
        }
        return TUIState(categories: categories)
    }

    static func plan(_ original: CleanupPlan, selecting itemIDs: [String]) -> CleanupPlan {
        let selected = Set(itemIDs)
        return CleanupPlan(
            schemaVersion: original.schemaVersion,
            hostID: original.hostID,
            items: original.items.map { item in
                CleanupPlanItem(
                    candidate: item.candidate,
                    selected: selected.contains(item.candidate.id)
                )
            }
        )
    }

    static func deepScanRoots(report: ScanReport, selecting itemIDs: [String]) throws -> [String] {
        let selected = Set(itemIDs)
        let candidates = report.candidates.filter { selected.contains($0.id) }
        guard candidates.count == selected.count else {
            throw KeepItCleanError.blockedCandidate(
                "The initial selection no longer maps to exact scan candidates."
            )
        }
        return Array(Set(candidates.map { candidate in
            if parentScopedRules.contains(candidate.ruleID) {
                return URL(fileURLWithPath: candidate.path).deletingLastPathComponent().path
            }
            return candidate.path
        })).sorted()
    }

    static func deepReviewReport(
        _ report: ScanReport,
        retaining itemIDs: [String]
    ) throws -> ScanReport {
        let requested = Set(itemIDs)
        var candidates = report.candidates.filter { requested.contains($0.id) }
        guard candidates.count == requested.count else {
            let found = Set(candidates.map(\.id))
            let missing = requested.subtracting(found).sorted().joined(separator: ", ")
            throw KeepItCleanError.blockedCandidate(
                "Deep scan could not reproduce every selected candidate: \(missing)"
            )
        }
        candidates = candidates.map { original in
            var candidate = original
            candidate.defaultSelected = candidate.actionKind == .trash && !candidate.isBlocked
            return candidate
        }
        var filtered = report
        filtered.candidates = candidates
        return filtered
    }

    private static func item(_ candidate: Candidate) -> TUIItem {
        TUIItem(
            id: candidate.id,
            title: candidate.displayName,
            path: candidate.path,
            allocatedBytes: candidate.identity?.allocatedBytes ?? 0,
            logicalBytes: candidate.identity?.logicalBytes ?? 0,
            reclaimableBytes: candidate.reclaimableBytes,
            risk: risk(candidate),
            rebuild: rebuild(candidate.rebuildCost),
            confidence: candidate.confidence.rawValue,
            activity: activity(candidate.activeState),
            reason: candidate.blockReason ?? candidate.evidence,
            isSelectable: candidate.actionKind == .trash && !candidate.isBlocked,
            isInitiallySelected: candidate.defaultSelected,
            age: candidate.identity.map { KeepFormatting.age(since: $0.modifiedAt) } ?? "unknown"
        )
    }

    private static func risk(_ candidate: Candidate) -> TUIRisk {
        if candidate.isBlocked { return .blocked }
        switch candidate.risk {
        case .low: return .safe
        case .review: return .review
        case .high: return .stateful
        }
    }

    private static func rebuild(_ value: RebuildCost) -> TUIRebuild {
        switch value {
        case .low: return .automatic
        case .medium: return .redownload
        case .high: return .manual
        case .notApplicable: return .none
        }
    }

    private static func activity(_ value: ActiveState) -> TUIActivity {
        switch value {
        case .inactive: return .inactive
        case .active: return .active
        case .unknown: return .unknown
        }
    }
}
