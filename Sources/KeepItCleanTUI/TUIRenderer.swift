import Foundation

public struct TUIRenderer: Sendable {
    public let usesANSI: Bool

    public init(usesANSI: Bool = true) {
        self.usesANSI = usesANSI
    }

    public func render(_ state: TUIState) -> String {
        var lines: [String] = []
        renderHeader(state, into: &lines)

        switch state.screen {
        case .categories:
            renderCategories(state, into: &lines)
        case let .items(categoryID):
            renderItems(state, categoryID: categoryID, into: &lines)
        case let .detail(categoryID, itemID):
            renderDetail(state, categoryID: categoryID, itemID: itemID, into: &lines)
        case .confirmApply:
            renderApplyConfirmation(state, into: &lines)
        case .help:
            renderHelp(state, into: &lines)
        }

        if let notice = state.notice {
            lines.append("")
            lines.append(style("  !  \(notice)", .warning))
        }

        lines.append("")
        lines.append(footer(for: state))
        return lines.map { clipped($0, width: state.width) }.joined(separator: "\n") + "\n"
    }

    private func renderHeader(_ state: TUIState, into lines: inout [String]) {
        let items = state.categories.flatMap(\.items)
        let eligible = items.filter(\.isSelectable).count
        let selected = state.selectedItemIDs.count
        let selectedBytes = ByteFormat.string(state.selectedReclaimableBytes)
        let totalBytes = ByteFormat.string(items.reduce(0) {
            let (sum, overflow) = $0.addingReportingOverflow($1.reclaimableBytes)
            return overflow ? .max : sum
        })

        let phase: String
        switch state.screen {
        case .confirmApply: phase = "CLEAN NOW"
        default: phase = state.allowsApply ? "READY" : "SCAN + REVIEW"
        }
        lines.append(style("  KEEP IT CLEAN", .title) + style("  /  macOS developer cleaner", .muted))
        lines.append(style("  SAFETY", .title) + "  " + style("Trash-first", .success)
            + style(" · No data collection · Undo available", .muted)
            + "  " + style(phase, .badge))
        lines.append("")
        lines.append(
            "  " + style("\(selected)", .accent) + " selected"
                + "  •  " + style(selectedBytes, .success) + " reclaim"
                + "  •  \(eligible) eligible / \(items.count) found"
                + "  •  \(totalBytes) potential"
        )
        lines.append(style("  " + selectionBar(selected: selected, eligible: eligible, width: min(32, state.width / 3)), .muted))
        lines.append(rule(width: state.width))
    }

    private func renderCategories(_ state: TUIState, into lines: inout [String]) {
        lines.append(style("  CLEANUP CATEGORIES", .section))
        lines.append(style("  Inspect what will move to Trash or protected quarantine.", .muted))
        lines.append("")

        guard !state.categories.isEmpty else {
            lines.append(style("No cleanup candidates were provided.", .muted))
            return
        }

        let maximumRows = max(1, (state.height - 12) / 2)
        let range = visibleRange(count: state.categories.count, cursor: state.categoryCursor, limit: maximumRows)

        for index in range {
            let category = state.categories[index]
            let focused = index == state.categoryCursor
            let marker = focused ? style("›", .accent) : " "
            let check = checkGlyph(state.checkmark(for: category))
            let first = "  \(marker) \(check)  \(index + 1). \(category.title)"
                + "  " + style(ByteFormat.string(category.reclaimableBytes), .success)
                + style("  \(itemCount(category.items.count))", .muted)
            lines.append(focused ? style(first, .focused) : first)
            lines.append("       \(categoryIcon(category.title))  " + riskLabel(category.highestRisk)
                + "  •  " + activityLabel(category.activityLabel))
        }
    }

    private func renderItems(_ state: TUIState, categoryID: String, into lines: inout [String]) {
        guard let category = state.category(withID: categoryID) else {
            lines.append(style("The selected category is no longer available.", .warning))
            return
        }

        lines.append(style("  REVIEW / \(category.title.uppercased())", .section))
        lines.append(style("  Enter details  •  Space select  •  Esc categories", .muted))
        lines.append("")

        guard !category.items.isEmpty else {
            lines.append(style("No candidates in this category.", .muted))
            return
        }

        let cursor = min(max(0, state.itemCursors[categoryID, default: 0]), category.items.count - 1)
        let maximumRows = max(1, (state.height - 12) / 2)
        let range = visibleRange(count: category.items.count, cursor: cursor, limit: maximumRows)

        for index in range {
            let item = category.items[index]
            let focused = index == cursor
            let marker = focused ? style("›", .accent) : " "
            let check = item.isSelectable
                ? (state.selectedItemIDs.contains(item.id) ? style("●", .success) : style("○", .muted))
                : style("–", .danger)
            let first = "  \(marker) \(check)  \(item.title)"
                + "    " + style(ByteFormat.string(item.reclaimableBytes), .success)
            lines.append(focused ? style(first, .focused) : first)
            lines.append(style("        \(abbreviatedPath(item.path, width: max(20, state.width - 10)))", .muted)
                + "  •  " + riskLabel(item.risk)
                + "  •  rebuild \(item.rebuild.label)"
                + "  •  " + activityLabel(item.activity.label))
        }
    }

    private func renderApplyConfirmation(_ state: TUIState, into lines: inout [String]) {
        lines.append("")
        lines.append(style("  CLEAN ALL VERIFIED ITEMS?", .warning))
        lines.append("")
        lines.append("  " + style("\(state.selectedItems.count)", .accent) + " items selected")
        lines.append("  " + style(ByteFormat.string(state.selectedReclaimableBytes), .success) + " estimated reclaim")
        if state.usesAutomaticSelection {
            lines.append(style("  All eligible items were selected automatically; blocked items remain protected.", .success))
        }
        lines.append("")
        lines.append("  Developer items move through the verified macOS Trash gateway.")
        if state.categories.contains(where: { $0.id == "keepitclean-system-caches" }) {
            lines.append("  Root-owned system items move into KeepItClean's protected quarantine.")
        }
        if state.categories.contains(where: { $0.id == "keepitclean-system-caches" }) {
            lines.append("  Each engine prints its own operation ID: " + style("keep undo <ID>", .accent)
                + " or " + style("keep system undo <ID>", .accent) + ".")
        } else {
            lines.append("  KeepItClean prints an operation ID for " + style("keep undo <ID>", .accent) + ".")
        }
        lines.append(style("  Space is reclaimed only after Trash is emptied or quarantine is finalized.", .muted))
        lines.append("")
        lines.append(style("  Enter  CLEAN NOW", .danger) + style("     Esc  go back", .muted))
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

        lines.append(style("  REVIEW / \(category.title.uppercased()) / DETAILS", .section))
        lines.append("")
        lines.append("  " + style(item.title, .focused))
        lines.append(style("  \(item.path)", .muted))
        lines.append("")
        lines.append("  Allocated   " + style(ByteFormat.string(item.allocatedBytes), .accent))
        lines.append("  Logical     \(ByteFormat.string(item.logicalBytes))")
        lines.append("  Reclaim     " + style(ByteFormat.string(item.reclaimableBytes), .success) + " estimate")
        lines.append("  Risk        " + riskLabel(item.risk))
        lines.append("  Rebuild     \(item.rebuild.label)")
        lines.append("  Confidence  \(item.confidence.isEmpty ? "unknown" : item.confidence)")
        lines.append("  Activity    " + activityLabel(item.activity.label))
        lines.append("  Age         \(item.age)")
        lines.append("  Selectable  " + (item.isSelectable ? style("yes", .success) : style("no", .danger)))
        lines.append("")
        lines.append(style("  WHY KEEPITCLEAN FOUND THIS", .section))
        lines.append("  \(item.reason)")
    }

    private func renderHelp(_ state: TUIState, into lines: inout [String]) {
        lines.append(style("  SAFETY DETAILS", .section))
        lines.append("")
        lines.append(style("  Trash-first", .success))
        lines.append("    Verified user files move to Trash; system cleanup uses root-owned quarantine.")
        lines.append(style("  No data collection", .success))
        lines.append("    No telemetry or uploads. Scan plans and journals stay on this Mac.")
        lines.append(style("  Undo available", .success))
        lines.append("    Use keep undo <ID> before Trash is emptied; finalize cannot be undone.")
        lines.append("")
        lines.append(style("  KEYBOARD", .section))
        lines.append("")
        lines.append("Up/Down or k/j    Move through rows")
        lines.append("Right/Enter/l     Drill down or show details")
        lines.append("Left/Escape/h     Go back")
        lines.append("Space             Toggle eligible selection")
        lines.append("d                 Show candidate details")
        lines.append(state.allowsApply
            ? "c                 Save reviewed plan"
            : "c                 Continue to deep verification")
        lines.append(state.allowsApply
            ? "a                 Review and move selection to Trash"
            : "a                 Unavailable until deep verification")
        lines.append("?                 Show or close this help")
        lines.append("q or Ctrl-C       Quit without accepting")
        lines.append("")
        lines.append(style("  Apply uses fresh reviewed plans and the matching Trash/quarantine engine.", .warning))
    }

    private func footer(for state: TUIState) -> String {
        switch state.screen {
        case .categories, .items:
            state.usesAutomaticSelection
                ? "  ↑↓ move   enter inspect   a final confirmation   ? help   q quit"
                : state.allowsApply
                ? "  ↑↓ move   enter open   space select   c save plan   a clean   ? help   q quit"
                : "  ↑↓ move   enter open   space select   c deep review   ? help   q quit"
        case .detail:
            state.usesAutomaticSelection
                ? "  a final confirmation   ←/esc back   ? help   q quit"
                : state.allowsApply
                ? "  space select   a clean   ←/esc back   ? help   q quit"
                : "  space select   c deep review   ←/esc back   ? help   q quit"
        case .confirmApply:
            "  enter CLEAN NOW   esc cancel"
        case .help:
            "  ?/esc close help   q quit"
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

    private func selectionBar(selected: Int, eligible: Int, width: Int) -> String {
        let safeWidth = max(8, width)
        let filled = eligible == 0 ? 0 : min(safeWidth, Int(Double(selected) / Double(eligible) * Double(safeWidth)))
        return style(String(repeating: "━", count: filled), .success)
            + style(String(repeating: "─", count: safeWidth - filled), .muted)
    }

    private func checkGlyph(_ checkmark: TUICheckmark) -> String {
        switch checkmark {
        case .off: style("○", .muted)
        case .on: style("●", .success)
        case .mixed: style("◐", .warning)
        case .unavailable: style("–", .danger)
        }
    }

    private func categoryIcon(_ title: String) -> String {
        let value = title.lowercased()
        if value.contains("gradle") { return "◆" }
        if value.contains("kotlin") || value.contains("konan") { return "K" }
        if value.contains("android") || value.contains("ndk") { return "◉" }
        if value.contains("build") || value.contains("project") { return "▣" }
        if value.contains("xcode") || value.contains("lldb") { return "⌘" }
        if value.contains("codex") { return "◇" }
        if value.contains("container") || value.contains("docker") { return "▤" }
        if value.contains("download") { return "⇩" }
        return "•"
    }

    private func itemCount(_ count: Int) -> String {
        "\(count) " + (count == 1 ? "item" : "items")
    }

    private func abbreviatedPath(_ path: String, width: Int) -> String {
        guard path.count > width, width > 4 else { return path }
        return "…" + path.suffix(width - 1)
    }

    private func riskLabel(_ risk: TUIRisk) -> String {
        switch risk {
        case .safe: style("safe", .success)
        case .review: style("review", .warning)
        case .stateful: style("high risk", .danger)
        case .blocked: style("blocked", .danger)
        }
    }

    private func activityLabel(_ activity: String) -> String {
        switch activity {
        case TUIActivity.inactive.label: style("idle", .success)
        case TUIActivity.active.label: style("ACTIVE", .danger)
        default: style("unknown activity", .warning)
        }
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
        case section
        case accent
        case success
        case danger
        case badge
        case focused
        case muted
        case warning
    }

    private func style(_ text: String, _ style: Style) -> String {
        guard usesANSI else { return text }
        let prefix: String
        switch style {
        case .title: prefix = "\u{001B}[1;38;5;45m"
        case .section: prefix = "\u{001B}[1;38;5;213m"
        case .accent: prefix = "\u{001B}[1;38;5;45m"
        case .success: prefix = "\u{001B}[1;38;5;82m"
        case .danger: prefix = "\u{001B}[1;38;5;203m"
        case .badge: prefix = "\u{001B}[1;30;48;5;45m"
        case .focused: prefix = "\u{001B}[1;38;5;231m"
        case .muted: prefix = "\u{001B}[2m"
        case .warning: prefix = "\u{001B}[1;38;5;220m"
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
