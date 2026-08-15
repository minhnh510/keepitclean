import Foundation
import KeepItCleanCore
import KeepItCleanSystem
import KeepItCleanTUI

enum TUIAdapter {
    private static let systemItemPrefix = "keepitclean-system:"
    private static let parentScopedRules: Set<String> = [
        "project.artifacts",
        "cachedir-tag.valid",
    ]

    static func state(report: ScanReport, allowsApply: Bool = false) -> TUIState {
        state(candidates: report.candidates, allowsApply: allowsApply)
    }

    static func state(plan: CleanupPlan) -> TUIState {
        let candidates = plan.items.map { item -> Candidate in
            var candidate = item.candidate
            candidate.defaultSelected = item.selected
                && candidate.actionKind == .trash
                && !candidate.isBlocked
            return candidate
        }
        return state(candidates: candidates, allowsApply: true)
    }

    static func automaticReviewState(report: ScanReport) -> TUIState {
        automaticReviewState(candidates: report.candidates)
    }

    static func automaticReviewState(plan: CleanupPlan) -> TUIState {
        automaticReviewState(candidates: plan.items.map(\.candidate))
    }

    static func unifiedAutomaticReviewState(
        plan: CleanupPlan,
        system: SystemCleanupScanResult?
    ) -> TUIState {
        var categories = automaticReviewState(plan: plan).categories
        if let system, !system.plan.candidates.isEmpty {
            categories.append(TUICategory(
                id: "keepitclean-system-caches",
                title: "System caches",
                summary: "Root-owned cache leaves held in undoable quarantine",
                items: system.plan.candidates.map(systemItem).sorted {
                    if $0.reclaimableBytes == $1.reclaimableBytes {
                        return $0.path < $1.path
                    }
                    return $0.reclaimableBytes > $1.reclaimableBytes
                }
            ))
        }
        return TUIState(
            categories: categories,
            screen: .confirmApply(returnTo: .categories),
            allowsApply: true,
            usesAutomaticSelection: true
        )
    }

    static func userItemIDs(from unifiedItemIDs: [String]) -> [String] {
        unifiedItemIDs.filter { !$0.hasPrefix(systemItemPrefix) }
    }

    static func selectsEverySystemCandidate(
        _ unifiedItemIDs: [String],
        result: SystemCleanupScanResult
    ) -> Bool {
        let selected = Set(unifiedItemIDs.filter { $0.hasPrefix(systemItemPrefix) })
        let expected = Set(result.plan.candidates.map { systemItemPrefix + $0.id })
        return !expected.isEmpty && selected == expected
    }

    static func eligibleItemIDs(report: ScanReport) -> [String] {
        report.candidates
            .filter { $0.actionKind == .trash && !$0.isBlocked }
            .map(\.id)
            .sorted()
    }

    private static func automaticReviewState(candidates: [Candidate]) -> TUIState {
        var prepared = candidates
        for index in prepared.indices {
            prepared[index].defaultSelected = prepared[index].actionKind == .trash
                && !prepared[index].isBlocked
        }
        return state(
            candidates: prepared,
            allowsApply: true,
            screen: .confirmApply(returnTo: .categories),
            usesAutomaticSelection: true
        )
    }

    private static func state(
        candidates: [Candidate],
        allowsApply: Bool,
        screen: TUIScreen = .categories,
        usesAutomaticSelection: Bool = false
    ) -> TUIState {
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
        return TUIState(
            categories: categories,
            screen: screen,
            allowsApply: allowsApply,
            usesAutomaticSelection: usesAutomaticSelection
        )
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

    private static func systemItem(_ candidate: SystemCleanupCandidate) -> TUIItem {
        TUIItem(
            id: systemItemPrefix + candidate.id,
            title: candidate.displayName,
            path: candidate.path,
            allocatedBytes: candidate.identity.allocatedBytes,
            logicalBytes: candidate.identity.logicalBytes,
            reclaimableBytes: candidate.reclaimableBytes,
            risk: .safe,
            rebuild: .automatic,
            confidence: "high",
            activity: .inactive,
            reason: candidate.reason + "; destination: root-owned KeepItClean quarantine",
            isSelectable: true,
            isInitiallySelected: true,
            age: KeepFormatting.age(since: candidate.identity.modifiedAt)
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
