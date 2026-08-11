import Darwin
import Dispatch
import Foundation

public enum TUIRuntimeError: Error, Equatable, LocalizedError {
    case requiresInteractiveTerminal
    case terminalConfigurationFailed(Int32)
    case terminalReadFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .requiresInteractiveTerminal:
            "The interactive review requires a terminal. Use a command with --json when piping output."
        case let .terminalConfigurationFailed(code):
            "Unable to configure the terminal (errno \(code))."
        case let .terminalReadFailed(code):
            "Unable to read terminal input (errno \(code))."
        }
    }
}

public enum TUIResult: Equatable, Sendable {
    case cancelled
    case accepted(itemIDs: [String])
}

public struct TUIInputDecoder: Sendable {
    private var pending: [UInt8] = []

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [TUIAction] {
        pending.append(contentsOf: bytes)
        return drain(flushEscape: false)
    }

    public mutating func flush() -> [TUIAction] {
        drain(flushEscape: true)
    }

    private mutating func drain(flushEscape: Bool) -> [TUIAction] {
        var actions: [TUIAction] = []
        while !pending.isEmpty {
            if pending[0] == 0x1B {
                if pending.count >= 3, pending[1] == 0x5B {
                    switch pending[2] {
                    case 0x41: actions.append(.moveUp)
                    case 0x42: actions.append(.moveDown)
                    case 0x43: actions.append(.open)
                    case 0x44: actions.append(.back)
                    default: actions.append(.back)
                    }
                    pending.removeFirst(3)
                    continue
                }
                if !flushEscape,
                   pending.count < 3,
                   (pending.count == 1 || pending[1] == 0x5B)
                {
                    break
                }
                actions.append(.back)
                pending.removeFirst()
                continue
            }

            let byte = pending.removeFirst()
            switch byte {
            case 0x03, 0x71: actions.append(.quit) // Ctrl-C, q
            case 0x0A, 0x0D, 0x6C: actions.append(.open) // Enter, l
            case 0x20: actions.append(.toggleSelection)
            case 0x3F: actions.append(.toggleHelp)
            case 0x63: actions.append(.confirmSelection)
            case 0x64: actions.append(.showDetail)
            case 0x68, 0x7F: actions.append(.back) // h, Backspace
            case 0x6A: actions.append(.moveDown)
            case 0x6B: actions.append(.moveUp)
            default: break
            }
        }
        return actions
    }
}

public final class KeepItCleanTUIRunner {
    private let inputFD: Int32
    private let outputFD: Int32
    private let renderer: TUIRenderer

    public init(
        inputFD: Int32 = STDIN_FILENO,
        outputFD: Int32 = STDOUT_FILENO,
        usesANSI: Bool = true
    ) {
        self.inputFD = inputFD
        self.outputFD = outputFD
        self.renderer = TUIRenderer(usesANSI: usesANSI)
    }

    public func run(initialState: TUIState) throws -> TUIResult {
        let terminal = RawTerminalSession(inputFD: inputFD, outputFD: outputFD)
        return try terminal.withRestoration {
            var state = initialState
            let dimensions = terminal.dimensions()
            state.width = dimensions.width
            state.height = dimensions.height
            var decoder = TUIInputDecoder()

            while true {
                terminal.draw(renderer.render(state))
                let bytes = try terminal.readInput()
                let actions = bytes.isEmpty ? decoder.flush() : decoder.feed(bytes)

                for action in actions {
                    if action == .moveUp || action == .moveDown {
                        let latestDimensions = terminal.dimensions()
                        state.width = latestDimensions.width
                        state.height = latestDimensions.height
                    }
                    let transition = TUIReducer.reduce(state, action: action)
                    state = transition.state
                    switch transition.effect {
                    case .none:
                        continue
                    case .quit:
                        return .cancelled
                    case let .acceptSelection(itemIDs):
                        return .accepted(itemIDs: itemIDs)
                    }
                }
            }
        }
    }
}

private final class RawTerminalSession: @unchecked Sendable {
    private let inputFD: Int32
    private let outputFD: Int32
    private var original = termios()
    private var configured = false
    private let restorationLock = NSLock()
    private let interruptionLock = NSLock()
    private var interruptionRequested = false
    private var signalSources: [DispatchSourceSignal] = []

    init(inputFD: Int32, outputFD: Int32) {
        self.inputFD = inputFD
        self.outputFD = outputFD
    }

    func withRestoration<T>(_ operation: () throws -> T) throws -> T {
        try configure()
        defer { restore() }
        return try operation()
    }

    func dimensions() -> (width: Int, height: Int) {
        var value = winsize()
        guard ioctl(outputFD, TIOCGWINSZ, &value) == 0 else { return (100, 30) }
        return (
            max(60, Int(value.ws_col == 0 ? 100 : value.ws_col)),
            max(16, Int(value.ws_row == 0 ? 30 : value.ws_row))
        )
    }

    func draw(_ content: String) {
        writeAll("\u{001B}[H\u{001B}[2J" + content)
    }

    func readInput() throws -> [UInt8] {
        if takeInterruptionRequest() { return [0x03] }
        var buffer = [UInt8](repeating: 0, count: 16)
        let count = buffer.withUnsafeMutableBytes { rawBuffer in
            Darwin.read(inputFD, rawBuffer.baseAddress, rawBuffer.count)
        }
        if count > 0 { return Array(buffer.prefix(count)) }
        if count == 0 { return takeInterruptionRequest() ? [0x03] : [] }
        if errno == EINTR { return [] }
        throw TUIRuntimeError.terminalReadFailed(errno)
    }

    private func configure() throws {
        guard isatty(inputFD) == 1, isatty(outputFD) == 1 else {
            throw TUIRuntimeError.requiresInteractiveTerminal
        }
        guard tcgetattr(inputFD, &original) == 0 else {
            throw TUIRuntimeError.terminalConfigurationFailed(errno)
        }

        var raw = original
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
        withUnsafeMutableBytes(of: &raw.c_cc) { bytes in
            bytes[Int(VMIN)] = 0
            bytes[Int(VTIME)] = 1
        }
        guard tcsetattr(inputFD, TCSAFLUSH, &raw) == 0 else {
            throw TUIRuntimeError.terminalConfigurationFailed(errno)
        }

        configured = true
        installSignalSources()
        writeAll("\u{001B}[?1049h\u{001B}[?25l")
    }

    private func restore() {
        restorationLock.lock()
        defer { restorationLock.unlock() }
        guard configured else { return }
        for source in signalSources { source.cancel() }
        signalSources.removeAll()
        for signalNumber in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
            _ = Darwin.signal(signalNumber, SIG_DFL)
        }
        _ = tcsetattr(inputFD, TCSAFLUSH, &original)
        writeAll("\u{001B}[?25h\u{001B}[?1049l")
        configured = false
    }

    private func installSignalSources() {
        for signalNumber in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
            _ = Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: DispatchQueue.global(qos: .userInitiated)
            )
            source.setEventHandler { [weak self] in
                self?.requestInterruption()
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func requestInterruption() {
        interruptionLock.lock()
        interruptionRequested = true
        interruptionLock.unlock()
    }

    private func takeInterruptionRequest() -> Bool {
        interruptionLock.lock()
        defer { interruptionLock.unlock() }
        let value = interruptionRequested
        interruptionRequested = false
        return value
    }

    private func writeAll(_ value: String) {
        let bytes = Array(value.utf8)
        bytes.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let pointer = rawBuffer.baseAddress!.advanced(by: offset)
                let written = Darwin.write(outputFD, pointer, rawBuffer.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }
}
