import Darwin
import Foundation

public enum TUIScanProgress {
    public static func run<Value: Sendable>(
        title: String,
        detail: String,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await TUIProgressRunner.run(
            display: ProgressDisplay(
                phase: "SCANNING",
                title: title,
                detail: detail,
                boundary: "Read-only • nothing is selected or removed",
                activity: "Inspecting metadata and allocated bytes",
                success: "Scan ready",
                failure: "Scan failed"
            ),
            operation: operation
        )
    }
}

public enum TUITrashProgress {
    public static func run<Value: Sendable>(
        itemCount: Int,
        reclaimableBytes: UInt64,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await TUIProgressRunner.run(
            display: ProgressDisplay(
                phase: "MOVING TO TRASH",
                title: "Moving \(itemCount) verified \(itemCount == 1 ? "item" : "items")",
                detail: "\(ByteFormat.string(reclaimableBytes)) estimated • identity is rechecked before every move",
                boundary: "Trash-first • No data collection • Undo available",
                activity: "Verifying and moving reviewed items",
                success: "Trash operation complete",
                failure: "Trash operation failed"
            ),
            operation: operation
        )
    }
}

private enum TUIProgressRunner {
    static func run<Value: Sendable>(
        display: ProgressDisplay,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard isatty(STDOUT_FILENO) == 1 else {
            return try await operation()
        }

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

private final class ProgressDisplay {
    private static let frames = ["◐", "◓", "◑", "◒"]
    private let phase: String
    private let title: String
    private let detail: String
    private let boundary: String
    private let activity: String
    private let success: String
    private let failure: String
    private lazy var renderer = TUIConsoleRenderer.terminal()

    init(
        phase: String,
        title: String,
        detail: String,
        boundary: String,
        activity: String,
        success: String,
        failure: String
    ) {
        self.phase = phase
        self.title = title
        self.detail = detail
        self.boundary = boundary
        self.activity = activity
        self.success = success
        self.failure = failure
    }

    func begin() {
        write(renderer.card(
            title: "Progress",
            badge: phase,
            lines: [
                TUIConsoleLine(title, tone: .normal),
                TUIConsoleLine(detail, tone: .muted),
            ],
            footer: TUIConsoleLine(boundary, tone: .muted)
        ))
    }

    func update(frame: Int, elapsed: TimeInterval) {
        let glyph = Self.frames[frame % Self.frames.count]
        write(
            "\r\u{001B}[2K  \(renderer.style(glyph, .accent)) "
                + "\(activity)  "
                + renderer.style(elapsedLabel(elapsed), .muted)
        )
    }

    func finish(elapsed: TimeInterval) {
        write("\r\u{001B}[2K")
        write(renderer.notice(
            title: success,
            message: elapsedLabel(elapsed),
            tone: .success
        ))
    }

    func fail(_ message: String) {
        write("\r\u{001B}[2K")
        write(renderer.notice(title: failure, message: message, tone: .danger))
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
