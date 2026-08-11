import Foundation
import KeepItCleanCore
@testable import KeepItCleanRules
import Testing

@Test func nativeCatalogUsesArgvWithoutShellInterpolation() {
    for action in NativeActionCatalog.allStatic {
        #expect(NativeActionCatalog.isAllowlisted(action.descriptor))
        #expect(action.descriptor.executable != "sh")
        #expect(action.descriptor.executable != "bash")
        #expect(!action.descriptor.arguments.contains(where: { $0.contains("$()") }))
        #expect(!action.descriptor.arguments.contains(where: { $0.contains(";") }))
    }

    #expect(NativeActionCatalog.gradleStop.descriptor.arguments == ["--stop"])
    #expect(NativeActionCatalog.cocoaPodsCleanAll.descriptor.arguments == ["cache", "clean", "--all"])
    #expect(NativeActionCatalog.dockerImagePrune.descriptor.arguments == ["image", "prune", "--force"])
    #expect(NativeActionCatalog.avdList.descriptor.arguments == ["list", "avd"])
    #expect(NativeActionCatalog.vscodeListExtensions.descriptor.arguments == ["--list-extensions", "--show-versions"])
}

@Test func dynamicNativeActionsRejectUntrustedIdentifiers() {
    let avd = NativeActionCatalog.deleteAVD(name: "Pixel_8_API_35")
    #expect(avd != nil)
    #expect(avd.map { NativeActionCatalog.isAllowlisted($0.descriptor) } == true)
    #expect(NativeActionCatalog.deleteAVD(name: "Pixel; rm -rf /") == nil)
    let colima = NativeActionCatalog.colimaStop(profile: "default")
    #expect(colima != nil)
    #expect(colima.map { NativeActionCatalog.isAllowlisted($0.descriptor) } == true)
    #expect(NativeActionCatalog.colimaStop(profile: "default && bad") == nil)
    let extensionAction = NativeActionCatalog.uninstallVSCodeExtension(identifier: "publisher.foo-2fa")
    #expect(extensionAction != nil)
    #expect(extensionAction.map { NativeActionCatalog.isAllowlisted($0.descriptor) } == true)
    #expect(extensionAction?.descriptor.arguments == ["--uninstall-extension", "publisher.foo-2fa"])
    #expect(extensionAction?.descriptor.affectedState.contains("including the newest") == true)
    #expect(extensionAction?.confirmation == .typedPhrase("UNINSTALL EXTENSION publisher.foo-2fa"))
    #expect(NativeActionCatalog.uninstallVSCodeExtension(identifier: "extension-only") == nil)
    #expect(NativeActionCatalog.uninstallVSCodeExtension(identifier: "publisher.foo-2fa-1.0.0") == nil)
    #expect(NativeActionCatalog.uninstallVSCodeExtension(identifier: "publisher.foo.extra") == nil)
    #expect(NativeActionCatalog.uninstallVSCodeExtension(identifier: ".extension") == nil)
    #expect(NativeActionCatalog.uninstallVSCodeExtension(identifier: "publisher.") == nil)

    let unapproved = NativeActionDescriptor(
        id: "docker.unapproved",
        title: "Unapproved",
        summary: "fixture",
        executable: "docker",
        arguments: ["volume", "prune", "--force"],
        affectedState: "fixture"
    )
    #expect(!NativeActionCatalog.isAllowlisted(unapproved))
}

@Test func fakeRunnerReceivesExactNativeArgvAndChecksPlanToken() throws {
    let runner = FakeNativeActionRunner()
    let plan = NativeActionPlan(
        descriptor: NativeActionCatalog.dockerDiskUsage.descriptor,
        hostID: "fixture-host",
        confirmationToken: "RUN-FIXTURE"
    )

    let record = try runner.run(plan: plan, confirmationToken: "RUN-FIXTURE")
    #expect(record.state == .completed)
    #expect(runner.receivedDescriptor?.executable == "docker")
    #expect(runner.receivedDescriptor?.arguments == ["system", "df", "--verbose"])
    #expect(throws: KeepItCleanError.confirmationMismatch) {
        try runner.run(plan: plan, confirmationToken: "WRONG")
    }
}

private final class FakeNativeActionRunner: NativeActionRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var storedDescriptor: NativeActionDescriptor?

    var receivedDescriptor: NativeActionDescriptor? {
        lock.withLock { storedDescriptor }
    }

    func run(plan: NativeActionPlan, confirmationToken: String) throws -> OperationRecord {
        guard plan.confirmationToken == confirmationToken else {
            throw KeepItCleanError.confirmationMismatch
        }
        lock.withLock {
            storedDescriptor = plan.descriptor
        }
        return OperationRecord(
            kind: .native,
            state: .completed,
            completedAt: Date(),
            items: []
        )
    }
}
