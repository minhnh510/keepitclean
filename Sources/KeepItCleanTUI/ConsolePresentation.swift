import Darwin
import Foundation

public enum TUIConsoleTone: Sendable {
    case normal
    case accent
    case success
    case warning
    case danger
    case muted
}

public struct TUIConsoleLine: Sendable {
    public let text: String
    public let tone: TUIConsoleTone
    public let continuationIndent: Int

    public init(
        _ text: String,
        tone: TUIConsoleTone = .normal,
        continuationIndent: Int = 4
    ) {
        self.text = text
        self.tone = tone
        self.continuationIndent = max(0, continuationIndent)
    }
}

public struct TUIConsoleRenderer: Sendable {
    public let width: Int
    public let usesANSI: Bool
    public let homePath: String

    public init(width: Int, usesANSI: Bool, homePath: String) {
        self.width = min(120, max(48, width))
        self.usesANSI = usesANSI
        self.homePath = homePath
    }

    public static func terminal(
        fileDescriptor: Int32 = STDOUT_FILENO,
        homePath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> TUIConsoleRenderer {
        var terminalSize = winsize()
        let measuredWidth: Int
        if ioctl(fileDescriptor, TIOCGWINSZ, &terminalSize) == 0, terminalSize.ws_col > 0 {
            measuredWidth = Int(terminalSize.ws_col)
        } else if let columns = ProcessInfo.processInfo.environment["COLUMNS"].flatMap(Int.init) {
            measuredWidth = columns
        } else {
            measuredWidth = 100
        }
        let environment = ProcessInfo.processInfo.environment
        let ansi = isatty(fileDescriptor) == 1
            && environment["NO_COLOR"] == nil
            && environment["TERM"] != "dumb"
        return TUIConsoleRenderer(width: measuredWidth, usesANSI: ansi, homePath: homePath)
    }

    public func card(
        title: String,
        badge: String? = nil,
        lines: [TUIConsoleLine],
        footer: TUIConsoleLine? = nil
    ) -> String {
        let innerWidth = width - 4
        let badgeText = badge.map { "  [\($0)]" } ?? ""
        let heading = "╭─ KEEP IT CLEAN · \(title.uppercased())\(badgeText) "
        var output = [style(fill(heading, to: width, with: "─"), .accent)]

        for line in lines {
            let wrapped = wrap(
                line.text,
                width: innerWidth,
                continuationIndent: line.continuationIndent
            )
            for segment in wrapped {
                output.append("│ " + style(pad(segment, to: innerWidth), line.tone) + " │")
            }
        }

        if let footer {
            let plain = "╰─ " + truncate(footer.text, to: width - 3) + " "
            output.append(style(fill(plain, to: width, with: "─"), footer.tone))
        } else {
            output.append(style("╰" + String(repeating: "─", count: width - 1), .accent))
        }
        return output.joined(separator: "\n") + "\n"
    }

    public func notice(
        title: String,
        message: String,
        tone: TUIConsoleTone
    ) -> String {
        let icon: String
        switch tone {
        case .success: icon = "✓"
        case .warning: icon = "!"
        case .danger: icon = "×"
        case .accent: icon = "›"
        case .muted, .normal: icon = "•"
        }
        let prefix = "  \(icon) \(title.uppercased())  "
        let available = max(16, width - prefix.count)
        let wrapped = wrap(message, width: available, continuationIndent: 0)
        return wrapped.enumerated().map { index, line in
            let lead = index == 0 ? style(prefix, tone) : String(repeating: " ", count: prefix.count)
            return lead + line
        }.joined(separator: "\n") + "\n"
    }

    public func compactPath(_ path: String, maxWidth: Int? = nil) -> String {
        let limit = max(12, maxWidth ?? width - 12)
        var display = path
        if path == homePath {
            display = "~"
        } else if path.hasPrefix(homePath + "/") {
            display = "~" + path.dropFirst(homePath.count)
        }
        guard display.count > limit else { return display }

        let pieces = display.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if pieces.count >= 3 {
            let prefix = display.hasPrefix("~") ? "~/" : "/"
            let tail = pieces.suffix(2).joined(separator: "/")
            let candidate = prefix + "…/" + tail
            if candidate.count <= limit { return candidate }
            return middleTruncate(candidate, to: limit)
        }
        return middleTruncate(display, to: limit)
    }

    public func style(_ text: String, _ tone: TUIConsoleTone) -> String {
        guard usesANSI else { return text }
        let code: String
        switch tone {
        case .normal: code = "0"
        case .accent: code = "1;38;5;45"
        case .success: code = "1;38;5;82"
        case .warning: code = "1;38;5;220"
        case .danger: code = "1;38;5;203"
        case .muted: code = "2"
        }
        return "\u{001B}[\(code)m\(text)\u{001B}[0m"
    }

    private func wrap(
        _ text: String,
        width: Int,
        continuationIndent: Int
    ) -> [String] {
        guard !text.isEmpty else { return [""] }
        var output: [String] = []
        for sourceLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let words = sourceLine.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !words.isEmpty else {
                output.append("")
                continue
            }
            var current = ""
            for word in words {
                let candidate = current.isEmpty ? word : current + " " + word
                if candidate.count <= width {
                    current = candidate
                    continue
                }
                if !current.isEmpty { output.append(current) }
                let indent = output.isEmpty ? "" : String(repeating: " ", count: continuationIndent)
                let available = max(8, width - indent.count)
                current = indent + truncate(word, to: available)
            }
            if !current.isEmpty { output.append(current) }
        }
        return output
    }

    private func pad(_ value: String, to length: Int) -> String {
        value + String(repeating: " ", count: max(0, length - value.count))
    }

    private func fill(_ value: String, to length: Int, with character: Character) -> String {
        let clipped = truncate(value, to: length)
        return clipped + String(repeating: character, count: max(0, length - clipped.count))
    }

    private func truncate(_ value: String, to length: Int) -> String {
        guard value.count > length else { return value }
        guard length > 1 else { return String(value.prefix(length)) }
        return String(value.prefix(length - 1)) + "…"
    }

    private func middleTruncate(_ value: String, to length: Int) -> String {
        guard value.count > length else { return value }
        guard length > 5 else { return truncate(value, to: length) }
        let leftCount = (length - 1) / 2
        let rightCount = length - leftCount - 1
        return String(value.prefix(leftCount)) + "…" + String(value.suffix(rightCount))
    }
}
