import Foundation

public struct TUIRenderer: Sendable {
    public let usesANSI: Bool

    public init(usesANSI: Bool = true) {
        self.usesANSI = usesANSI
    }

    public func render(_ state: TUIState) -> String {
        var lines: [String] = []
        lines.append(header(state))
        lines.append(rule(width: state.width))

        switch state.screen {
        case .categories:
            renderCategories(state, into: &lines)
        case let .items(categoryID):
            renderItems(state, categoryID: categoryID, into: &lines)
        case let .detail(categoryID, itemID):
            renderDetail(state, categoryID: categoryID, itemID: itemID, into: &lines)
        case .help:
            renderHelp(state, into: &lines)
        }

        if let notice = state.notice {
            lines.append("")
            lines.append(style("! \(notice)", .warning))
        }

        lines.append("")
        lines.append(footer(for: state.screen))
        return lines.map { clipped($0, width: state.width) }.joined(separator: "\n") + "\n"
    }

    private func header(_ state: TUIState) -> String {
        let selected = ByteFormat.string(state.selectedReclaimableBytes)
        return style("KeepItClean", .title)
            + "  REVIEW PLAN  | selected reclaim estimate: \(selected)"
    }

    private func renderCategories(_ state: TUIState, into lines: inout [String]) {
        lines.append("Categories — Enter drills down; Space changes only the review selection.")
        lines.append("")

        guard !state.categories.isEmpty else {
            lines.append(style("No cleanup candidates were provided.", .muted))
            return
        }

        let maximumRows = max(1, (state.height - 8) / 2)
        let range = visibleRange(count: state.categories.count, cursor: state.categoryCursor, limit: maximumRows)

        for index in range {
            let category = state.categories[index]
            let focused = index == state.categoryCursor
            let marker = focused ? ">" : " "
            let check = state.checkmark(for: category).glyph
            let first = "\(marker) [\(check)] \(category.title)"
                + "  reclaim \(ByteFormat.string(category.reclaimableBytes))"
                + "  allocated \(ByteFormat.string(category.allocatedBytes))"
                + "  logical \(ByteFormat.string(category.logicalBytes))"
            lines.append(focused ? style(first, .focused) : first)
            lines.append("      \(category.items.count) items"
                + " | risk \(category.highestRisk.label)"
                + " | rebuild \(category.rebuildLabel)"
                + " | active \(category.activityLabel)"
                + " | \(category.summary)")
        }
    }

    private func renderItems(_ state: TUIState, categoryID: String, into lines: inout [String]) {
        guard let category = state.category(withID: categoryID) else {
            lines.append(style("The selected category is no longer available.", .warning))
            return
        }

        lines.append("Categories / \(category.title) — Enter opens details; Space checks an eligible item.")
        lines.append("")

        guard !category.items.isEmpty else {
            lines.append(style("No candidates in this category.", .muted))
            return
        }

        let cursor = min(max(0, state.itemCursors[categoryID, default: 0]), category.items.count - 1)
        let maximumRows = max(1, (state.height - 8) / 2)
        let range = visibleRange(count: category.items.count, cursor: cursor, limit: maximumRows)

        for index in range {
            let item = category.items[index]
            let focused = index == cursor
            let marker = focused ? ">" : " "
            let check = item.isSelectable
                ? (state.selectedItemIDs.contains(item.id) ? "x" : " ")
                : "-"
            let first = "\(marker) [\(check)] \(item.title)"
                + "  reclaim \(ByteFormat.string(item.reclaimableBytes))"
                + "  allocated \(ByteFormat.string(item.allocatedBytes))"
                + "  logical \(ByteFormat.string(item.logicalBytes))"
            lines.append(focused ? style(first, .focused) : first)
            lines.append("      risk \(item.risk.label)"
                + " | rebuild \(item.rebuild.label)"
                + " | confidence \(item.confidence)"
                + " | active \(item.activity.label)"
                + " | \(item.path)")
        }
    }

    private func renderDetail(
        _ state: TUIState,
        categoryID: String,
        itemID: String,
        into lines: inout [String]
    ) {
        guard let category = state.category(withID: categoryID),
              let item = state.item(categoryID: categoryID, itemID: itemID)
        else {
            lines.append(style("The selected candidate is no longer available.", .warning))
            return
        }

        lines.append("Categories / \(category.title) / \(item.title)")
        lines.append("")
        lines.append(style(item.title, .focused))
        lines.append("Path:      \(item.path)")
        lines.append("Allocated: \(ByteFormat.string(item.allocatedBytes))")
        lines.append("Logical:   \(ByteFormat.string(item.logicalBytes))")
        lines.append("Reclaim:   \(ByteFormat.string(item.reclaimableBytes)) (estimate)")
        lines.append("Risk:      \(item.risk.label)")
        lines.append("Rebuild:   \(item.rebuild.label)")
        lines.append("Confidence:\(item.confidence.isEmpty ? " unknown" : " \(item.confidence)")")
        lines.append("Active:    \(item.activity.label)")
        lines.append("Age:       \(item.age)")
        lines.append("Selectable:\(item.isSelectable ? " yes" : " no")")
        lines.append("")
        lines.append("Why: \(item.reason)")
    }

    private func renderHelp(_ state: TUIState, into lines: inout [String]) {
        lines.append("Keyboard help")
        lines.append("")
        lines.append("Up/Down or k/j    Move through rows")
        lines.append("Right/Enter/l     Drill down or show details")
        lines.append("Left/Escape/h     Go back")
        lines.append("Space             Toggle eligible selection")
        lines.append("d                 Show candidate details")
        lines.append("c                 Accept reviewed selection")
        lines.append("?                 Show or close this help")
        lines.append("q or Ctrl-C       Quit without accepting")
        lines.append("")
        lines.append(style("The TUI never mutates files. It only returns reviewed item IDs.", .warning))
    }

    private func footer(for screen: TUIScreen) -> String {
        switch screen {
        case .categories, .items:
            "Up/Down navigate  Enter open  Space select  d detail  c continue  ? help  q quit"
        case .detail:
            "Space select  Left/Escape back  ? help  q quit"
        case .help:
            "? or Escape closes help  q quits"
        }
    }

    private func visibleRange(count: Int, cursor: Int, limit: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let boundedLimit = min(max(1, limit), count)
        let half = boundedLimit / 2
        var lower = max(0, cursor - half)
        if lower + boundedLimit > count { lower = count - boundedLimit }
        return lower..<(lower + boundedLimit)
    }

    private func rule(width: Int) -> String {
        String(repeating: "-", count: max(1, min(width, 120)))
    }

    private func clipped(_ line: String, width: Int) -> String {
        guard !usesANSI else { return line }
        guard line.count > width else { return line }
        guard width > 1 else { return String(line.prefix(width)) }
        return String(line.prefix(width - 1)) + "…"
    }

    private enum Style {
        case title
        case focused
        case muted
        case warning
    }

    private func style(_ text: String, _ style: Style) -> String {
        guard usesANSI else { return text }
        let prefix: String
        switch style {
        case .title: prefix = "\u{001B}[1;36m"
        case .focused: prefix = "\u{001B}[1;32m"
        case .muted: prefix = "\u{001B}[2m"
        case .warning: prefix = "\u{001B}[1;33m"
        }
        return prefix + text + "\u{001B}[0m"
    }
}

public enum ByteFormat {
    public static func string(_ bytes: UInt64) -> String {
        let units: [(UInt64, String)] = [
            (1 << 40, "TiB"),
            (1 << 30, "GiB"),
            (1 << 20, "MiB"),
            (1 << 10, "KiB"),
        ]
        for (divisor, suffix) in units where bytes >= divisor {
            return String(format: "%.1f %@", Double(bytes) / Double(divisor), suffix)
        }
        return "\(bytes) B"
    }
}
