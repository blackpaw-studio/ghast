import Testing
import Foundation
@testable import Ghast

@Suite("Softnet helper setup")
@MainActor
struct SoftnetHelperSetupTests {
    private final class ChangeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func bump() { lock.withLock { value += 1 } }
    }

    @MainActor private struct Rig {
        let checker: FakeSoftnetChecker
        let runner = FakePrivilegedRunner()
        let changes = ChangeCounter()
        let model: SoftnetHelperModel

        init(
            _ status: SoftnetHelperStatus = .notInstalled,
            installScript: String? = "INSTALL SCRIPT '$1'",
            removeScript: String? = "REMOVE SCRIPT"
        ) {
            let checker = FakeSoftnetChecker(status)
            let changes = changes
            self.checker = checker
            model = SoftnetHelperModel(
                checker: checker,
                runner: runner,
                installScript: installScript,
                removeScript: removeScript,
                onStatusChange: { changes.bump() }
            )
        }
    }

    @Test("setup passes the script and quoted arguments separately, then re-checks")
    func setUp() async {
        let rig = Rig()
        await rig.model.refresh()
        let checker = rig.checker
        rig.runner.onRun = { checker.status = .ready(version: "0.26.0") }

        await rig.model.setUp()

        let call = rig.runner.calls.first
        #expect(rig.runner.calls.count == 1)
        #expect(call?.script == "INSTALL SCRIPT '$1'")
        #expect(call?.script.contains("/opt/homebrew") == false)
        #expect(call?.arguments == ["/opt/homebrew/bin/softnet", "/usr/local/libexec/ghast"])
        #expect(rig.model.status == .ready(version: "0.26.0"))
        #expect(rig.model.errorMessage == nil)
        #expect(!rig.model.isWorking)
    }

    @Test("a cancelled prompt leaves the status as it was")
    func cancelled() async {
        let rig = Rig(.notInstalled)
        await rig.model.refresh()
        let before = rig.changes.count
        let checks = rig.checker.checks
        rig.runner.result = .failure(.cancelled)

        await rig.model.setUp()

        #expect(rig.model.status == .notInstalled)
        #expect(rig.model.errorMessage == nil)
        #expect(rig.changes.count == before)
        #expect(rig.checker.checks == checks)
        #expect(!rig.model.isWorking)
    }

    @Test("a failed script shows its message and re-checks")
    func failed() async {
        let rig = Rig(.notInstalled)
        await rig.model.refresh()
        let checks = rig.checker.checks
        let checker = rig.checker
        rig.runner.result = .failure(.failed("unsafe folder: /usr/local/libexec"))
        rig.runner.onRun = { checker.status = .unsafe(.unsafeFolder("/usr/local/libexec")) }

        await rig.model.setUp()

        #expect(rig.model.errorMessage == "unsafe folder: /usr/local/libexec")
        #expect(rig.checker.checks == checks + 1)
        #expect(rig.model.status == .unsafe(.unsafeFolder("/usr/local/libexec")))
    }

    @Test("the next action clears the earlier error")
    func errorClears() async {
        let rig = Rig()
        rig.runner.result = .failure(.failed("nope"))
        await rig.model.setUp()
        #expect(rig.model.errorMessage == "nope")

        rig.runner.result = .success(())
        await rig.model.setUp()
        #expect(rig.model.errorMessage == nil)
    }

    @Test("with no softnet to copy from, setup shows that and runs nothing")
    func noSource() async {
        let rig = Rig(.notInstalled)
        rig.checker.source = nil

        await rig.model.setUp()

        #expect(rig.runner.calls.isEmpty)
        #expect(rig.model.status == .softnetMissing)
    }

    @Test("with no install script in the bundle, setup shows an error and runs nothing")
    func noScript() async {
        let rig = Rig(installScript: nil)

        await rig.model.setUp()

        #expect(rig.runner.calls.isEmpty)
        #expect(rig.model.errorMessage != nil)
    }

    @Test("a refused removal shows the script's message and re-checks")
    func removalRefused() async {
        let rig = Rig(.ready(version: "0.26.0"))
        await rig.model.refresh()
        let checks = rig.checker.checks
        rig.runner.result = .failure(.failed("unsafe folder: /usr/local/libexec"))

        await rig.model.remove()

        #expect(rig.model.errorMessage == "unsafe folder: /usr/local/libexec")
        #expect(rig.checker.checks == checks + 1)
        #expect(rig.model.status == .ready(version: "0.26.0"))
    }

    @Test("with no removal script in the bundle, removal shows an error and runs nothing")
    func noRemoveScript() async {
        let rig = Rig(removeScript: nil)

        await rig.model.remove()

        #expect(rig.runner.calls.isEmpty)
        #expect(rig.model.errorMessage != nil)
    }

    @Test("removal runs the bundled script with no arguments")
    func removal() async {
        let rig = Rig(.ready(version: "0.26.0"))
        await rig.model.refresh()
        let checker = rig.checker
        rig.runner.onRun = { checker.status = .notInstalled }

        await rig.model.remove()

        #expect(rig.runner.calls == [.init(script: "REMOVE SCRIPT", arguments: [])])
        #expect(rig.model.status == .notInstalled)
    }

    @Test("a change callback fires only when the status differs")
    func callbackOnChange() async {
        let rig = Rig(.notInstalled)
        await rig.model.refresh()
        await rig.model.refresh()
        #expect(rig.changes.count == 1)

        rig.checker.status = .ready(version: "0.26.0")
        await rig.model.refresh()
        #expect(rig.changes.count == 2)
    }

    @Test("the privileged handler compiles")
    func handlerCompiles() {
        var error: NSDictionary?
        let script = NSAppleScript(source: AppleScriptPrivilegedRunner.handlerSource)
        #expect(script?.compileAndReturnError(&error) == true)
        #expect(error == nil)
    }
}
