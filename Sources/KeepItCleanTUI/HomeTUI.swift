import Foundation
import KeepItCleanCore

public enum TUIHomeChoice: Int, CaseIterable, Equatable, Sendable {
    case clean
    case analyze
    case doctor
    case history

    public var number: Int { rawValue + 1 }

    var title: String {
        switch self {
        case .clean: "Clean"
        case .analyze: "Analyze"
        case .doctor: "Doctor"
        case .history: "History"
        }
    }

    var detail: String {
        switch self {
        case .clean: "Developer + hardcore + system cleanup in one review"
        case .analyze: "Explore home storage without changing files"
        case .doctor: "Check processes, permissions, and safety gates"
        case .history: "Review operations and find undo IDs"
        }
    }

    var badge: String? {
        switch self {
        case .clean: "ALL-IN-ONE"
        case .analyze: "READ-ONLY"
        case .doctor: "READ-ONLY"
        case .history: nil
        }
    }
}

public struct TUIHomeState: Equatable, Sendable {
    public var cursor: Int
    public var width: Int
    public var height: Int
    public var showsSafetyHelp: Bool

    public init(
        cursor: Int = 0,
        width: Int = 100,
        height: Int = 30,
        showsSafetyHelp: Bool = false
    ) {
        self.cursor = min(max(0, cursor), TUIHomeChoice.allCases.count - 1)
        self.width = max(60, width)
        self.height = max(20, height)
        self.showsSafetyHelp = showsSafetyHelp
    }
}

public enum TUIHomeEffect: Equatable, Sendable {
    case none
    case choose(TUIHomeChoice)
    case quit
}

public struct TUIHomeTransition: Equatable, Sendable {
    public let state: TUIHomeState
    public let effect: TUIHomeEffect
}

public enum TUIHomeReducer {
    public static func reduce(_ state: TUIHomeState, action: TUIAction) -> TUIHomeTransition {
        var next = state
        if next.showsSafetyHelp {
            switch action {
            case .toggleHelp, .back, .open:
                next.showsSafetyHelp = false
            case .quit:
                return TUIHomeTransition(state: next, effect: .quit)
            case let .resize(width, height):
                next.width = max(60, width)
                next.height = max(20, height)
            case .moveUp, .moveDown, .showDetail, .toggleSelection,
                    .confirmSelection, .requestApply, .selectIndex:
                break
            }
            return TUIHomeTransition(state: next, effect: .none)
        }
        switch action {
        case .moveUp:
            next.cursor = wrapped(next.cursor - 1)
        case .moveDown:
            next.cursor = wrapped(next.cursor + 1)
        case .open:
            return TUIHomeTransition(
                state: next,
                effect: .choose(TUIHomeChoice.allCases[next.cursor])
            )
        case let .selectIndex(index):
            guard TUIHomeChoice.allCases.indices.contains(index) else {
                return TUIHomeTransition(state: next, effect: .none)
            }
            next.cursor = index
            return TUIHomeTransition(
                state: next,
                effect: .choose(TUIHomeChoice.allCases[index])
            )
        case .quit, .back:
            return TUIHomeTransition(state: next, effect: .quit)
        case let .resize(width, height):
            next.width = max(60, width)
            next.height = max(20, height)
        case .toggleHelp:
            next.showsSafetyHelp = true
        case .showDetail, .toggleSelection, .confirmSelection, .requestApply:
            break
        }
        return TUIHomeTransition(state: next, effect: .none)
    }

    private static func wrapped(_ value: Int) -> Int {
        let count = TUIHomeChoice.allCases.count
        return (value % count + count) % count
    }
}

public struct TUIHomeRenderer: Sendable {
    public let usesANSI: Bool

    public init(usesANSI: Bool = true) {
        self.usesANSI = usesANSI
    }

    public func render(_ state: TUIHomeState) -> String {
        var lines: [String] = []
        lines.append("")
        lines.append(cyan("   _  __ _____ _____ ____  ") + green("  IT CLEAN"))
        lines.append(cyan("  | |/ /| ____| ____|  _ \\ "))
        lines.append(cyan("  | ' / |  _| |  _| | |_) |"))
        lines.append(cyan("  | . \\ | |___| |___|  __/ "))
        lines.append(cyan("  |_|\\_\\|_____|_____|_|    "))
        lines.append("")
        lines.append("  " + green("Developer storage, under control.") + muted("  v\(keepItCleanVersion)"))
        lines.append("  " + cyan("SAFETY") + "  " + green("Trash-first")
            + muted(" · No data collection · Undo available"))
        lines.append("  " + muted("Clean requests admin access only when the optional system helper is ready."))
        lines.append("")

        if state.showsSafetyHelp {
            renderSafetyHelp(into: &lines)
            return lines.map { clipPlain($0, width: state.width) }.joined(separator: "\n") + "\n"
        }

        for choice in TUIHomeChoice.allCases {
            let focused = choice.rawValue == state.cursor
            let pointer = focused ? cyan("›") : " "
            let number = focused ? cyan("\(choice.number).") : "\(choice.number)."
            let title = padded(choice.title, width: 12)
            let main = "  \(pointer) \(number) \(focused ? cyan(title) : title)  \(choice.detail)"
            let badge = choice.badge.map { "  " + (focused ? green("[\($0)]") : muted("[\($0)]")) } ?? ""
            lines.append(main + badge)
        }

        lines.append("")
        lines.append(muted("  ─────────────────────────────────────────────────────────────────"))
        lines.append("  " + muted("↑↓ navigate") + "   " + cyan("Enter open")
            + muted("   1–4 quick select   ? safety details   q quit"))
        return lines.map { clipPlain($0, width: state.width) }.joined(separator: "\n") + "\n"
    }

    private func renderSafetyHelp(into lines: inout [String]) {
        lines.append("  " + cyan("SAFETY DETAILS"))
        lines.append("")
        lines.append("  " + green("Trash-first"))
        lines.append("    Normal cleanup moves verified items to macOS Trash.")
        lines.append("    System cleanup uses a root-owned quarantine before permanent finalize.")
        lines.append("")
        lines.append("  " + green("No data collection"))
        lines.append("    No telemetry, analytics, cloud upload, account, or background daemon.")
        lines.append("    Scans, plans, and operation journals stay on this Mac.")
        lines.append("")
        lines.append("  " + green("Undo available"))
        lines.append("    Use keep undo <ID> or keep system undo <ID> while the item still exists.")
        lines.append("    Emptying Trash or running finalize is permanent and cannot be undone.")
        lines.append("")
        lines.append(muted("  ? / Esc / Enter  close details") + muted("    q quit"))
    }

    private func padded(_ value: String, width: Int) -> String {
        value + String(repeating: " ", count: max(0, width - value.count))
    }

    private func clipPlain(_ value: String, width: Int) -> String {
        guard !usesANSI, value.count > width else { return value }
        return String(value.prefix(max(1, width - 1))) + "…"
    }

    private func cyan(_ value: String) -> String { style(value, "1;38;5;45") }
    private func green(_ value: String) -> String { style(value, "1;38;5;82") }
    private func muted(_ value: String) -> String { style(value, "2") }

    private func style(_ value: String, _ code: String) -> String {
        usesANSI ? "\u{001B}[\(code)m\(value)\u{001B}[0m" : value
    }
}
