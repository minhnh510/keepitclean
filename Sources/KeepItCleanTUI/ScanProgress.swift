import Darwin
import Foundation

public enum TUIScanProgress {
    public static func run<Value: Sendable>(
        title: String,
        detail: String,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard isatty(STDOUT_FILENO) == 1 else {
            return try await operation()
        }

        let display = ScanProgressDisplay(title: title, detail: detail)
        let result = ProgressResult<Value>()
        let worker = Task {
            do {
                await result.store(.success(try await operation()))
            } catch {
                await result.store(.failure(error))
            }
        }
        defer { worker.cancel() }

        display.begin()
        let startedAt = Date()
        var frame = 0
        while true {
            if let outcome = await result.value() {
                switch outcome {
                case let .success(value):
                    display.finish(elapsed: Date().timeIntervalSince(startedAt))
                    return value
                case let .failure(error):
                    display.fail(error.localizedDescription)
                    throw error
                }
            }
            display.update(frame: frame, elapsed: Date().timeIntervalSince(startedAt))
            frame += 1
            try await Task.sleep(for: .milliseconds(110))
        }
    }
}

private enum ProgressOutcome<Value: Sendable>: @unchecked Sendable {
    case success(Value)
    case failure(any Error)
}

private actor ProgressResult<Value: Sendable> {
    private var outcome: ProgressOutcome<Value>?

    func store(_ value: ProgressOutcome<Value>) {
        outcome = value
    }

    func value() -> ProgressOutcome<Value>? {
        outcome
    }
}

private final class ScanProgressDisplay {
    private static let frames = ["◐", "◓", "◑", "◒"]
    private let title: String
    private let detail: String

    init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    func begin() {
        write("\u{001B}[1;36m╭─ KeepItClean ─ SCANNING\u{001B}[0m\n")
        write("│ \u{001B}[1m\(title)\u{001B}[0m\n")
        write("│ \u{001B}[2m\(detail)\u{001B}[0m\n")
        write("╰─ Read-only • nothing is selected or removed\n")
    }

    func update(frame: Int, elapsed: TimeInterval) {
        let glyph = Self.frames[frame % Self.frames.count]
        write(
            "\r\u{001B}[2K  \u{001B}[1;36m\(glyph)\u{001B}[0m "
                + "Inspecting metadata and allocated bytes  "
                + "\u{001B}[2m\(elapsedLabel(elapsed))\u{001B}[0m"
        )
    }

    func finish(elapsed: TimeInterval) {
        write(
            "\r\u{001B}[2K  \u{001B}[1;32m✓\u{001B}[0m Scan ready  "
                + "\u{001B}[2m\(elapsedLabel(elapsed))\u{001B}[0m\n"
        )
    }

    func fail(_ message: String) {
        write("\r\u{001B}[2K  \u{001B}[1;31m×\u{001B}[0m Scan failed: \(message)\n")
    }

    private func elapsedLabel(_ elapsed: TimeInterval) -> String {
        let seconds = max(0, Int(elapsed))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func write(_ value: String) {
        let bytes = Array(value.utf8)
        bytes.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                guard let base = rawBuffer.baseAddress else { return }
                let count = Darwin.write(
                    STDOUT_FILENO,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if count <= 0 { return }
                offset += count
            }
        }
    }
}
