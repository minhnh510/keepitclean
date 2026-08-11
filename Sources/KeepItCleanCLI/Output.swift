import Foundation
import KeepItCleanCore

struct JSONEnvelope<Payload: Encodable>: Encodable {
    let schemaVersion = keepItCleanSchemaVersion
    let command: String
    let generatedAt: Date
    let status: String
    let data: Payload
    let warnings: [String]

    init(command: String, data: Payload, warnings: [String] = []) {
        self.command = command
        self.generatedAt = Date()
        self.status = "ok"
        self.data = data
        self.warnings = warnings
    }
}

enum CLIOutput {
    static func json<Payload: Encodable>(
        command: String,
        data: Payload,
        warnings: [String] = []
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(JSONEnvelope(command: command, data: data, warnings: warnings))
        FileHandle.standardOutput.write(bytes)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    static func text(_ value: String) {
        FileHandle.standardOutput.write(Data((value + "\n").utf8))
    }

    static func warning(_ value: String) {
        FileHandle.standardError.write(Data(("WARNING: " + value + "\n").utf8))
    }
}

struct PlanOutput: Encodable {
    let report: ScanReport?
    let plan: CleanupPlan
    let planPath: String
    let mode: String
}

struct PathOutput: Encodable {
    let path: String
}

struct MessageOutput: Encodable {
    let message: String
}

enum HumanOutput {
    static func scan(_ planned: PlannedScan, label: String) {
        CLIOutput.text("\(label): \(planned.report.candidates.count) candidates")
        CLIOutput.text("Measured allocated: \(KeepFormatting.bytes(planned.report.totalAllocatedBytes))")
        CLIOutput.text("Eligible reclaim estimate: \(KeepFormatting.bytes(planned.report.totalReclaimableBytes))")
        CLIOutput.text("Plan: \(planned.planURL.path)")
        if planned.report.partial {
            CLIOutput.warning("The scan was partial. Review every issue; blocked or unknown state stays unselected.")
        }
        for issue in planned.report.issues {
            CLIOutput.warning([issue.path, issue.message].compactMap { $0 }.joined(separator: ": "))
        }
    }

    static func plan(_ plan: CleanupPlan, path: String) {
        let selected = plan.selectedItems
        let bytes = selected.reduce(UInt64(0)) { $0 &+ $1.candidate.reclaimableBytes }
        CLIOutput.text("Plan \(plan.id.uuidString): \(selected.count)/\(plan.items.count) selected")
        CLIOutput.text("Estimated selected reclaimable: \(KeepFormatting.bytes(bytes))")
        CLIOutput.text("Plan: \(path)")
    }

    static func operation(_ operation: OperationRecord) {
        CLIOutput.text("Operation \(operation.id.uuidString): \(operation.kind.rawValue) / \(operation.state.rawValue)")
        for item in operation.items {
            CLIOutput.text("- \(item.status.rawValue): \(item.originalPath)\(item.message.map { " — \($0)" } ?? "")")
        }
    }
}
