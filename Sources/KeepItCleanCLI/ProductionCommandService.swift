import Darwin
import Foundation
import KeepItCleanCore
import KeepItCleanFS
import KeepItCleanRules

struct ProductionCommandService: KeepCommandServing, Sendable {
    private let homePath: String
    private let reader: LocalFileSystemReader
    private let processes: ConservativeProcessStateProbe
    private let nativeActionProcessPolicy: NativeActionProcessPolicy
    private let plans: JSONPlanStore
    private let operations: JSONLOperationStore
    private let host: DefaultHostIdentifier
    private let gateway: FileMutationGateway
    private let catalog: RuleCatalog
    private let nativeRunner: any NativeActionRunning

    init(
        homePath overrideHomePath: String? = nil,
        planDirectory: URL? = nil,
        operationLogURL: URL? = nil,
        processSnapshotProvider: any ProcessSnapshotProviding = SystemProcessSnapshotProvider(),
        nativeRunner overrideNativeRunner: (any NativeActionRunning)? = nil
    ) {
        let home = overrideHomePath.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
        } ?? FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        let reader = LocalFileSystemReader()
        let processes = ConservativeProcessStateProbe(provider: processSnapshotProvider)
        let nativeActionProcessPolicy = NativeActionProcessPolicy(
            processes: processes,
            processSnapshotProvider: processSnapshotProvider
        )
        let plans = planDirectory.map(JSONPlanStore.init(baseDirectory:)) ?? JSONPlanStore()
        let operations = operationLogURL.map { JSONLOperationStore(logURL: $0) }
            ?? JSONLOperationStore()
        let host = DefaultHostIdentifier()
        let validator = PathValidator(policy: PathValidationPolicy(homePath: home))

        self.homePath = home
        self.reader = reader
        self.processes = processes
        self.nativeActionProcessPolicy = nativeActionProcessPolicy
        self.plans = plans
        self.operations = operations
        self.host = host
        self.gateway = FileMutationGateway(
            validator: validator,
            reader: reader,
            mover: SystemTrashMover(homePath: home),
            operationStore: operations
        )
        self.catalog = RuleCatalog(fileSystem: reader, processes: processes)
        if let overrideNativeRunner {
            self.nativeRunner = overrideNativeRunner
        } else {
            self.nativeRunner = SystemNativeActionRunner(
                operationStore: operations,
                host: host,
                preLaunchValidation: { descriptor in
                    guard let action = NativeActionProcessPolicy.cataloguedAction(
                        id: descriptor.id
                    ), action.descriptor == descriptor else {
                        throw KeepItCleanError.unsupported(
                            "Native action descriptor is not an exact current catalog entry."
                        )
                    }
                    try nativeActionProcessPolicy.validate(action)
                }
            )
        }
    }

    func scan(roots rawRoots: [String], deep: Bool) async throws -> PlannedScan {
        let roots = try normalizedRoots(rawRoots)
        let scanner = RuleScanner(catalog: catalog, homePath: homePath, roots: roots)
        let request = ScanRequest(roots: roots, homePath: homePath, deep: deep)
        let report = applyingProductProtections(await scanner.scan(request: request))
        return try persist(report: report)
    }

    func analyze(path rawPath: String, deep: Bool) async throws -> PlannedScan {
        let path = try normalizedRoot(rawPath)
        let startedAt = Date()
        let rootIdentity = try reader.identity(at: path)
        let entries: [String]
        if rootIdentity.fileKind == .directory {
            entries = try reader.immediateChildren(at: path)
        } else {
            entries = [path]
        }

        var candidates: [Candidate] = []
        var issues: [ScanIssue] = []
        for entry in entries {
            do {
                let identity = try reader.identity(at: entry)
                let usage: DiskUsage
                if deep, identity.fileKind == .directory || identity.fileKind == .regularFile {
                    usage = try reader.usage(at: entry)
                } else {
                    usage = DiskUsage(
                        logicalBytes: identity.logicalBytes,
                        allocatedBytes: identity.allocatedBytes,
                        reclaimableBytes: identity.reclaimableBytes,
                        fileCount: 1
                    )
                }
                let measured = FileIdentity(
                    device: identity.device,
                    inode: identity.inode,
                    ownerID: identity.ownerID,
                    fileKind: identity.fileKind,
                    logicalBytes: usage.logicalBytes,
                    allocatedBytes: usage.allocatedBytes,
                    modifiedAt: identity.modifiedAt,
                    linkCount: identity.linkCount,
                    reclaimableBytes: usage.reclaimableBytes
                )
                candidates.append(Candidate(
                    ruleID: "analyze.disk-usage",
                    category: "Disk usage",
                    path: entry,
                    displayName: URL(fileURLWithPath: entry).lastPathComponent,
                    evidence: deep
                        ? "Deep allocated-size measurement with hardlink and sparse-file accounting."
                        : "Fast top-level metadata pass; add --deep for recursive allocated size.",
                    identity: measured,
                    actionKind: .reportOnly,
                    risk: .review,
                    rebuildCost: .notApplicable,
                    activeState: .inactive,
                    defaultSelected: false,
                    blockReason: "Disk explorer entries are read-only and never enter a cleanup plan."
                ))
            } catch {
                issues.append(ScanIssue(path: entry, message: error.localizedDescription))
            }
        }

        candidates.sort {
            if $0.reclaimableBytes != $1.reclaimableBytes {
                return $0.reclaimableBytes > $1.reclaimableBytes
            }
            return $0.path < $1.path
        }
        let report = ScanReport(
            durationSeconds: Date().timeIntervalSince(startedAt),
            candidates: candidates,
            issues: issues,
            partial: !issues.isEmpty
        )
        return try persist(report: report)
    }

    func loadPlan(reference: String) throws -> CleanupPlan {
        if let id = UUID(uuidString: reference) {
            return try plans.loadPlan(id: id)
        }
        return try plans.loadPlan(at: fileURL(reference))
    }

    func save(plan: CleanupPlan) throws -> URL {
        try plans.save(plan: plan)
    }

    func applyTrash(plan: CleanupPlan) async throws -> OperationRecord {
        guard plan.isValid(hostID: host.currentHostID()) else {
            if Date() > plan.expiresAt { throw KeepItCleanError.planExpired }
            if plan.hostID != host.currentHostID() { throw KeepItCleanError.hostMismatch }
            throw KeepItCleanError.unsupported("Cleanup plan has an invalid schema or review window.")
        }
        for item in plan.selectedItems {
            let candidate = item.candidate
            guard candidate.actionKind == .trash, !candidate.isBlocked else {
                throw KeepItCleanError.blockedCandidate(candidate.path)
            }
            let state = currentProcessState(for: candidate)
            guard state == .inactive else {
                let reason = state == .active
                    ? "Related developer process became active: \(candidate.path)"
                    : "Related process state could not be revalidated: \(candidate.path)"
                throw KeepItCleanError.blockedCandidate(reason)
            }
            try await revalidateRuleMembership(candidate)
        }
        return try gateway.applyTrash(plan: plan, hostID: host.currentHostID())
    }

    func undo(operationID: UUID) throws -> OperationRecord {
        let operation = try validatedTrashOperation(id: operationID)
        return try gateway.undo(operation: operation)
    }

    func finalize(operationID: UUID, confirmationToken: String) throws -> OperationRecord {
        let operation = try validatedTrashOperation(id: operationID)
        return try gateway.finalize(operation: operation, confirmationToken: confirmationToken)
    }

    func history(limit: Int) throws -> [OperationRecord] {
        try operations.operations(limit: limit)
    }

    func ruleDescriptors() -> [RuleDescriptor] {
        catalog.defaultAdapters(homePath: homePath, roots: [homePath])
            .map(\.descriptor)
            .sorted { $0.id < $1.id }
    }

    func doctor() async -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        let os = ProcessInfo.processInfo.operatingSystemVersion
        checks.append(DoctorCheck(
            id: "macos",
            status: os.majorVersion >= 14 ? "ok" : "blocked",
            message: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion); KeepItClean requires macOS 14+."
        ))
        checks.append(DoctorCheck(
            id: "home",
            status: FileManager.default.isReadableFile(atPath: homePath) ? "ok" : "blocked",
            message: "User home is \(homePath)."
        ))
        do {
            let snapshot = try SystemProcessSnapshotProvider().snapshot()
            checks.append(DoctorCheck(
                id: "process-probe",
                status: snapshot.isEmpty ? "blocked" : "ok",
                message: snapshot.isEmpty
                    ? "Process state could not be proven. Cleanup candidates will stay blocked."
                    : "Read-only process snapshot is available."
            ))
        } catch {
            checks.append(DoctorCheck(id: "process-probe", status: "blocked", message: error.localizedDescription))
        }

        let trash = URL(fileURLWithPath: homePath).appendingPathComponent(".Trash").path
        let trashReady = FileManager.default.fileExists(atPath: trash)
            ? FileManager.default.isWritableFile(atPath: trash)
            : FileManager.default.isWritableFile(atPath: homePath)
        checks.append(DoctorCheck(
            id: "trash",
            status: trashReady ? "ok" : "blocked",
            message: trashReady
                ? "User Trash is available; moving there does not immediately reclaim disk space."
                : "User Trash is not writable."
        ))

        let available = NativeActionCatalog.allowedExecutables.sorted().filter {
            (try? NativeExecutableResolver.resolve($0)) != nil
        }
        checks.append(DoctorCheck(
            id: "native-tools",
            status: "ok",
            message: available.isEmpty
                ? "No optional native cleanup tools were found on PATH."
                : "Available optional tools: \(available.joined(separator: ", "))."
        ))
        checks.append(DoctorCheck(
            id: "privileges",
            status: "ok",
            message: "No daemon, privileged helper, or sudo integration is installed."
        ))
        return checks
    }

    func nativeActions() -> [NativeActionListing] {
        NativeActionCatalog.allStatic.map { action in
            NativeActionListing(
                descriptor: action.descriptor,
                isReadOnly: action.isReadOnly,
                confirmationHint: confirmationHint(action.confirmation)
            )
        }.sorted { $0.descriptor.id < $1.descriptor.id }
    }

    func nativeActionIsReadOnly(actionID: String) -> Bool? {
        cataloguedNativeAction(actionID)?.isReadOnly
    }

    func makeNativeActionPlan(actionID: String) throws -> (NativeActionPlan, URL) {
        guard let action = cataloguedNativeAction(actionID) else {
            throw KeepItCleanError.unsupported("Unknown or invalid native action: \(actionID)")
        }
        try nativeActionProcessPolicy.validate(action)
        let typedToken: String?
        if case let .typedPhrase(phrase) = action.confirmation {
            typedToken = phrase
        } else {
            typedToken = nil
        }
        let plan = NativeActionPlan(
            descriptor: action.descriptor,
            hostID: host.currentHostID(),
            confirmationToken: typedToken
        )
        return (plan, try plans.save(nativePlan: plan))
    }

    func loadNativeActionPlan(reference: String) throws -> NativeActionPlan {
        if let id = UUID(uuidString: reference) {
            return try plans.loadNativePlan(id: id)
        }
        return try plans.loadNativePlan(at: fileURL(reference))
    }

    func runNativeAction(plan: NativeActionPlan, confirmationToken: String) throws -> OperationRecord {
        guard let action = cataloguedNativeAction(plan.descriptor.id),
              action.descriptor == plan.descriptor
        else {
            throw KeepItCleanError.unsupported("Native action descriptor is not an exact current catalog entry.")
        }
        try nativeActionProcessPolicy.validate(action)
        return try nativeRunner.run(plan: plan, confirmationToken: confirmationToken)
    }

    private func persist(report: ScanReport) throws -> PlannedScan {
        let plan = CleanupPlan(
            hostID: host.currentHostID(),
            items: report.candidates.map { CleanupPlanItem(candidate: $0) }
        )
        let url = try plans.save(plan: plan)
        return PlannedScan(report: report, plan: plan, planURL: url)
    }

    /// Undo/finalize authority comes from the private reviewed plan plus the
    /// journal, never from a JSONL record alone. This rejects forged, stale,
    /// duplicated, or cross-plan operation items before the mutation gateway
    /// is allowed to inspect Trash.
    private func validatedTrashOperation(id operationID: UUID) throws -> OperationRecord {
        let operation = try operations.operation(id: operationID)
        guard operation.schemaVersion == keepItCleanSchemaVersion,
              operation.kind == .trash
        else {
            throw KeepItCleanError.unsupported("Only a recorded Trash operation can be restored or finalized.")
        }
        guard operation.state == .completed || operation.state == .partial else {
            throw KeepItCleanError.unsupported(
                "Trash operation must be completed or partial before restore/finalize."
            )
        }
        guard operation.completedAt != nil else {
            throw KeepItCleanError.unsupported("Trash operation is missing its completion timestamp.")
        }
        guard let planID = operation.planID else {
            throw KeepItCleanError.unsupported("Trash operation is missing its reviewed plan ID.")
        }

        let plan = try plans.loadPlan(id: planID)
        guard plan.schemaVersion == keepItCleanSchemaVersion,
              plan.hasValidReviewWindow,
              plan.hostID == host.currentHostID(),
              operation.startedAt >= plan.createdAt,
              operation.startedAt <= plan.expiresAt
        else {
            throw KeepItCleanError.unsupported(
                "Trash operation did not start within its reviewed plan window."
            )
        }

        var reviewedByID: [String: Candidate] = [:]
        var reviewedPaths = Set<String>()
        for item in plan.selectedItems {
            let candidate = item.candidate
            guard candidate.actionKind == .trash,
                  !candidate.isBlocked,
                  candidate.identity != nil,
                  reviewedByID.updateValue(candidate, forKey: candidate.id) == nil,
                  reviewedPaths.insert(candidate.path).inserted
            else {
                throw KeepItCleanError.unsupported(
                    "Reviewed cleanup plan contains duplicate or ineligible candidates."
                )
            }
        }
        guard operation.items.count == reviewedByID.count else {
            throw KeepItCleanError.unsupported(
                "Trash operation item count does not match the selected reviewed plan."
            )
        }

        var operationCandidateIDs = Set<String>()
        var operationPaths = Set<String>()
        var resultingTrashPaths = Set<String>()
        var movedCount = 0
        for item in operation.items {
            guard operationCandidateIDs.insert(item.candidateID).inserted,
                  operationPaths.insert(item.originalPath).inserted
            else {
                throw KeepItCleanError.unsupported(
                    "Trash operation contains duplicate candidate IDs or paths."
                )
            }
            guard let candidate = reviewedByID[item.candidateID],
                  candidate.path == item.originalPath,
                  candidate.identity == item.identity
            else {
                throw KeepItCleanError.unsupported(
                    "Trash operation item is not an exact selected reviewed candidate: \(item.originalPath)"
                )
            }
            if let trashPath = item.resultingTrashPath {
                guard resultingTrashPaths.insert(trashPath).inserted else {
                    throw KeepItCleanError.unsupported(
                        "Trash operation contains duplicate Trash destinations."
                    )
                }
            }
            if item.status == .movedToTrash {
                guard item.resultingTrashPath != nil else {
                    throw KeepItCleanError.unsupported(
                        "Moved Trash operation item is missing its Trash destination."
                    )
                }
                movedCount += 1
            }
        }
        guard movedCount > 0 else {
            throw KeepItCleanError.unsupported("Trash operation contains no moved items.")
        }
        return operation
    }

    private func applyingProductProtections(_ input: ScanReport) -> ScanReport {
        var report = input
        let minhBrain = URL(fileURLWithPath: homePath).appendingPathComponent("MinhBrain").path
        report.candidates = input.candidates.map { original in
            guard original.path == minhBrain || original.path.hasPrefix(minhBrain + "/") else {
                return original
            }
            var candidate = original
            candidate.actionKind = .blocked
            candidate.activeState = .unknown
            candidate.defaultSelected = false
            candidate.blockReason = "MinhBrain, including raw/, is product-protected by the locked v0.1 policy."
            return candidate
        }
        return report
    }

    private func normalizedRoots(_ values: [String]) throws -> [String] {
        guard !values.isEmpty else { throw KeepItCleanError.invalidPath("empty root list") }
        return try Array(Set(values.map(normalizedRoot))).sorted()
    }

    private func normalizedRoot(_ value: String) throws -> String {
        let expanded = NSString(string: value).expandingTildeInPath
        guard expanded.hasPrefix("/"), !expanded.contains("\0") else {
            throw KeepItCleanError.invalidPath(value)
        }
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard reader.fileExists(at: standardized) else {
            throw KeepItCleanError.io("Scan root does not exist: \(standardized)")
        }
        let identity = try reader.identity(at: standardized)
        guard identity.fileKind != .symbolicLink else {
            throw KeepItCleanError.symbolicLink(standardized)
        }
        return URL(fileURLWithPath: standardized).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func fileURL(_ reference: String) -> URL {
        URL(fileURLWithPath: NSString(string: reference).expandingTildeInPath)
            .standardizedFileURL
    }

    private func confirmationHint(_ confirmation: NativeActionConfirmation) -> String {
        switch confirmation {
        case .none: "A generated plan token is still required."
        case .explicit: "A generated plan token is required."
        case let .typedPhrase(phrase): "Type exactly: \(phrase)"
        }
    }

    private func cataloguedNativeAction(_ actionID: String) -> CataloguedNativeAction? {
        NativeActionProcessPolicy.cataloguedAction(id: actionID)
    }

    private func currentProcessState(for candidate: Candidate) -> ActiveState {
        switch candidate.ruleID {
        case let id where id.hasPrefix("gradle."):
            processes.state(for: KnownProcessProbes.gradle)
        case let id where id.hasPrefix("lldb."):
            processes.state(for: KnownProcessProbes.lldb)
        case let id where id.hasPrefix("kotlin-native."):
            processes.state(for: KnownProcessProbes.kotlinNative)
        case let id where id.hasPrefix("codex."):
            processes.state(for: KnownProcessProbes.codex)
        case let id where id.hasPrefix("android."):
            processes.state(for: KnownProcessProbes.android)
        case let id where id.hasPrefix("containers."):
            processes.state(for: KnownProcessProbes.colimaDocker)
        case let id where id.hasPrefix("cocoapods."):
            processes.state(for: KnownProcessProbes.cocoaPods)
        case let id where id.hasPrefix("maven."):
            processes.state(for: KnownProcessProbes.maven)
        case let id where id.hasPrefix("xcode."):
            processes.state(for: KnownProcessProbes.xcode)
        case let id where id.hasPrefix("vscode."):
            processes.state(for: KnownProcessProbes.visualStudioCode)
        case "project.artifacts", "cachedir-tag.valid":
            processes.state(matching: [
                "cargo", "clang", "cmake", "dart", "flutter", "gradle", "java", "node",
                "npm", "pnpm", "pod", "python", "swift", "xcodebuild", "yarn",
            ])
        default:
            .inactive
        }
    }

    private func revalidateRuleMembership(_ reviewed: Candidate) async throws {
        let adapters = catalog.defaultAdapters(homePath: homePath, roots: [homePath])
        guard let adapter = adapters.first(where: { $0.descriptor.id == reviewed.ruleID }) else {
            throw KeepItCleanError.blockedCandidate("Unknown cleanup rule: \(reviewed.ruleID)")
        }

        let parentValidatedRules: Set<String> = ["project.artifacts", "cachedir-tag.valid"]
        let validationRoot = parentValidatedRules.contains(reviewed.ruleID)
            ? URL(fileURLWithPath: reviewed.path).deletingLastPathComponent().path
            : reviewed.path
        let fresh = try await adapter.scan(request: ScanRequest(
            roots: [validationRoot],
            homePath: homePath,
            deep: true
        ))
        guard let candidate = fresh.first(where: {
            $0.ruleID == reviewed.ruleID && $0.path == reviewed.path && $0.id == reviewed.id
        }), candidate.ruleVersion == reviewed.ruleVersion,
              candidate.actionKind == .trash, !candidate.isBlocked,
              let reviewedIdentity = reviewed.identity,
              let freshIdentity = candidate.identity,
              reviewedIdentity.matchesForMutation(freshIdentity),
              reviewedIdentity.logicalBytes == freshIdentity.logicalBytes,
              reviewedIdentity.allocatedBytes == freshIdentity.allocatedBytes,
              reviewedIdentity.reclaimableBytes == freshIdentity.reclaimableBytes
        else {
            throw KeepItCleanError.blockedCandidate(
                "Candidate no longer matches its reviewed rule and identity: \(reviewed.path)"
            )
        }
    }
}

private struct NativeActionProcessPolicy: Sendable {
    let processes: ConservativeProcessStateProbe
    let processSnapshotProvider: any ProcessSnapshotProviding

    static func cataloguedAction(id actionID: String) -> CataloguedNativeAction? {
        if let action = NativeActionCatalog.allStatic.first(where: { $0.descriptor.id == actionID }) {
            return action
        }
        if actionID.hasPrefix("colima.stop.") {
            return NativeActionCatalog.colimaStop(
                profile: String(actionID.dropFirst("colima.stop.".count))
            )
        }
        if actionID.hasPrefix("android.avd-delete.") {
            return NativeActionCatalog.deleteAVD(
                name: String(actionID.dropFirst("android.avd-delete.".count))
            )
        }
        if actionID.hasPrefix("vscode.extension-uninstall.") {
            return NativeActionCatalog.uninstallVSCodeExtension(
                identifier: String(actionID.dropFirst("vscode.extension-uninstall.".count))
            )
        }
        return nil
    }

    func validate(_ action: CataloguedNativeAction) throws {
        if action.isReadOnly {
            guard NativeActionCatalog.allStatic.contains(action) else {
                throw KeepItCleanError.unsupported(
                    "Only exact static read-only native actions may bypass activity checks."
                )
            }
            return
        }

        let actionID = action.descriptor.id
        switch actionID {
        case "gradle.stop":
            try requireObservable(
                processes.state(for: KnownProcessProbes.gradle),
                actionID: actionID,
                owner: "Gradle"
            )
        case "cocoapods.cache-clean-all":
            try requireInactive(
                processes.state(for: KnownProcessProbes.cocoaPods),
                actionID: actionID,
                owner: "CocoaPods"
            )
        case "docker.image-prune":
            // Docker owns this exact daemon action; activity is expected.
            return
        case let id where id.hasPrefix("colima.stop."):
            try requireObservable(
                processes.state(for: KnownProcessProbes.colimaDocker),
                actionID: actionID,
                owner: "Colima/Docker"
            )
        case let id where id.hasPrefix("android.avd-delete."):
            try requireInactive(
                androidAVDState(named: String(id.dropFirst("android.avd-delete.".count))),
                actionID: actionID,
                owner: "Android emulator"
            )
        case let id where id.hasPrefix("vscode.extension-uninstall."):
            try requireInactive(
                processes.state(for: KnownProcessProbes.visualStudioCode),
                actionID: actionID,
                owner: "Visual Studio Code"
            )
        default:
            throw KeepItCleanError.unsupported(
                "Native action has no reviewed process-safety policy: \(actionID)"
            )
        }
    }

    private func requireObservable(
        _ state: ActiveState,
        actionID: String,
        owner: String
    ) throws {
        guard state != .unknown else {
            throw KeepItCleanError.blockedCandidate(
                "Cannot prove \(owner) process state for native action \(actionID)."
            )
        }
    }

    private func requireInactive(
        _ state: ActiveState,
        actionID: String,
        owner: String
    ) throws {
        switch state {
        case .inactive:
            return
        case .active:
            throw KeepItCleanError.blockedCandidate(
                "\(owner) is active; native action \(actionID) is blocked."
            )
        case .unknown:
            throw KeepItCleanError.blockedCandidate(
                "Cannot prove \(owner) is inactive for native action \(actionID)."
            )
        }
    }

    private func androidAVDState(named targetName: String) -> ActiveState {
        let records: [ProcessRecord]
        do {
            records = try processSnapshotProvider.snapshot()
        } catch {
            return .unknown
        }
        guard !records.isEmpty else { return .unknown }

        let target = targetName.lowercased()
        var unidentifiedEmulator = false
        for record in records {
            let executable = URL(fileURLWithPath: record.executable)
                .lastPathComponent.lowercased()
            let arguments = record.arguments.lowercased()
            let isEmulator = executable == "emulator"
                || executable.hasPrefix("qemu-system-")
                || arguments.contains("qemu-system-")
            guard isEmulator else { continue }

            let names = referencedAVDNames(in: arguments)
            if names.contains(target) { return .active }
            if names.isEmpty { unidentifiedEmulator = true }
        }
        return unidentifiedEmulator ? .unknown : .inactive
    }

    private func referencedAVDNames(in arguments: String) -> Set<String> {
        let tokens = arguments
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        var names = Set<String>()
        for index in tokens.indices {
            if tokens[index] == "-avd", tokens.indices.contains(index + 1) {
                names.insert(tokens[index + 1].lowercased())
            }
            if tokens[index].hasPrefix("@"), tokens[index].count > 1 {
                names.insert(String(tokens[index].dropFirst()).lowercased())
            }
            for rawComponent in tokens[index].split(separator: "/") {
                let component = String(rawComponent)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if component.lowercased().hasSuffix(".avd") {
                    names.insert(String(component.dropLast(4)).lowercased())
                }
            }
        }
        return names
    }
}

struct SystemNativeActionRunner: NativeActionRunning, Sendable {
    private let operationStore: any OperationStoring
    private let host: any HostIdentifying
    private let preLaunchValidation: @Sendable (NativeActionDescriptor) throws -> Void
    private let resolveExecutable: @Sendable (String) throws -> ResolvedNativeExecutable
    private let revalidateExecutable: @Sendable (ResolvedNativeExecutable) throws -> Void
    private let launchProcess: @Sendable (Process) throws -> Void

    init(
        operationStore: any OperationStoring,
        host: any HostIdentifying,
        preLaunchValidation: @escaping @Sendable (NativeActionDescriptor) throws -> Void = { _ in },
        resolveExecutable: @escaping @Sendable (String) throws -> ResolvedNativeExecutable =
            NativeExecutableResolver.resolve,
        revalidateExecutable: @escaping @Sendable (ResolvedNativeExecutable) throws -> Void =
            NativeExecutableResolver.revalidate,
        launchProcess: @escaping @Sendable (Process) throws -> Void = { try $0.run() }
    ) {
        self.operationStore = operationStore
        self.host = host
        self.preLaunchValidation = preLaunchValidation
        self.resolveExecutable = resolveExecutable
        self.revalidateExecutable = revalidateExecutable
        self.launchProcess = launchProcess
    }

    func run(plan: NativeActionPlan, confirmationToken: String) throws -> OperationRecord {
        guard plan.schemaVersion == keepItCleanSchemaVersion else {
            throw KeepItCleanError.unsupported("Unsupported native-action plan schema.")
        }
        guard plan.isValid(hostID: host.currentHostID()) else {
            if Date() > plan.expiresAt { throw KeepItCleanError.planExpired }
            if plan.hostID != host.currentHostID() { throw KeepItCleanError.hostMismatch }
            throw KeepItCleanError.unsupported("Native-action plan has an invalid schema or review window.")
        }
        guard plan.confirmationToken == confirmationToken else {
            throw KeepItCleanError.confirmationMismatch
        }
        guard NativeActionCatalog.isAllowlisted(plan.descriptor) else {
            throw KeepItCleanError.unsupported("Native action argv is not allowlisted.")
        }

        let startedAt = Date()
        let resolvedExecutable = try resolveExecutable(plan.descriptor.executable)
        let executable = resolvedExecutable.url
        var operation = OperationRecord(
            planID: plan.id,
            kind: .native,
            state: .running,
            startedAt: startedAt,
            items: [OperationItem(
                candidateID: plan.descriptor.id,
                originalPath: executable.path,
                identity: resolvedExecutable.identity,
                status: .pending
            )]
        )

        // A durable running record is the launch precondition. If journaling
        // fails, no tool-managed state is allowed to change. Every later
        // outcome appends the same operation UUID, so history lookup observes
        // a stable state transition instead of unrelated records.
        try operationStore.append(operation: operation)

        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = plan.descriptor.arguments
        process.standardOutput = output
        process.standardError = output

        do {
            try preLaunchValidation(plan.descriptor)
            try revalidateExecutable(resolvedExecutable)
            try launchProcess(process)
        } catch {
            operation.state = .failed
            operation.completedAt = Date()
            operation.items[0].status = .failed
            operation.items[0].message = "Unable to launch: \(error.localizedDescription)"
            try operationStore.append(operation: operation)
            throw KeepItCleanError.io("Unable to launch native action: \(error.localizedDescription)")
        }

        let outputHandle = output.fileHandleForReading
        defer { try? outputHandle.close() }
        var data = Data()
        do {
            while let chunk = try outputHandle.read(upToCount: 32 * 1_024), !chunk.isEmpty {
                if data.count < 4_096 {
                    data.append(chunk.prefix(4_096 - data.count))
                }
            }
        } catch {
            terminateAndWait(process)
            let message = "Unable to read native action output: \(error.localizedDescription)"
            operation.state = .failed
            operation.completedAt = Date()
            operation.items[0].status = .failed
            operation.items[0].message = message
            try operationStore.append(operation: operation)
            throw KeepItCleanError.io(message)
        }
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let succeeded = process.terminationStatus == 0
        let message = text.isEmpty
            ? "Exit status \(process.terminationStatus)."
            : "Exit status \(process.terminationStatus): \(text)"
        operation.state = succeeded ? .completed : .failed
        operation.completedAt = Date()
        operation.items[0].status = succeeded ? .executed : .failed
        operation.items[0].message = message
        try operationStore.append(operation: operation)
        guard succeeded else {
            throw KeepItCleanError.io("Native action failed with exit status \(process.terminationStatus).")
        }
        return operation
    }

    private func terminateAndWait(_ process: Process) {
        if process.isRunning {
            process.terminate()
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
    }

}

struct ResolvedNativeExecutable: Sendable {
    let url: URL
    let identity: FileIdentity
}

private enum NativeExecutableResolver {
    static func resolve(_ executable: String) throws -> ResolvedNativeExecutable {
        guard NativeActionCatalog.allowedExecutables.contains(executable),
              !executable.contains("/"), !executable.isEmpty
        else {
            throw KeepItCleanError.unsupported("Executable is not allowlisted: \(executable)")
        }

        var directories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/Applications/Visual Studio Code.app/Contents/Resources/app/bin",
        ]
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let sdk = ProcessInfo.processInfo.environment[key], sdk.hasPrefix("/") {
                directories.append("\(sdk)/cmdline-tools/latest/bin")
                directories.append("\(sdk)/tools/bin")
            }
        }

        for directory in Array(Set(directories)).sorted() where directory.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(executable)
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            var value = stat()
            guard resolved.path.withCString({ Darwin.lstat($0, &value) }) == 0,
                  value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  value.st_uid == 0 || value.st_uid == getuid()
            else { continue }
            let identity = try LocalFileSystemReader().identity(at: resolved.path)
            return ResolvedNativeExecutable(url: resolved, identity: identity)
        }
        throw KeepItCleanError.unsupported("Optional tool is not available: \(executable)")
    }

    static func revalidate(_ executable: ResolvedNativeExecutable) throws {
        let current = try LocalFileSystemReader().identity(at: executable.url.path)
        guard current.fileKind == .regularFile,
              executable.identity.matchesForMutation(current)
        else {
            throw KeepItCleanError.identityChanged(executable.url.path)
        }
    }
}
