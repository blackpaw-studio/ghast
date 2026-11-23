import Foundation

enum PrivilegedScriptError: Error, Equatable, Sendable {
    /// The user dismissed the administrator password prompt.
    case cancelled
    /// The script ran and failed, or the prompt couldn't be shown. Carries the message to show.
    case failed(String)
}

/// Runs a shell script as root after the user approves with an administrator password.
protocol PrivilegedScriptRunning: Sendable {
    /// Runs `script` with `/bin/sh -c`, passing `arguments` as `$1`, `$2`, …; the script text
    /// never contains them.
    func run(script: String, arguments: [String]) async throws(PrivilegedScriptError)
}

/// `do shell script … with administrator privileges` through `NSAppleScript`, which shows the
/// system password prompt. The AppleScript source is one constant handler: the script text and
/// each argument travel as handler parameters and are quoted by AppleScript, never spliced
/// into source.
@MainActor
struct AppleScriptPrivilegedRunner: PrivilegedScriptRunning {
    /// AppleScript's error number for "User canceled".
    private static let userCancelled = -128
    private static let handlerName = "runprivileged"
    /// AppleScript's `kASAppleScriptSuite`, `kASSubroutineEvent` and `keyASSubroutineName`,
    /// which Swift doesn't import.
    private static let appleScriptSuite = fourCharCode("ascr")
    private static let subroutineEvent = fourCharCode("psbr")
    private static let subroutineName = fourCharCode("snam")
    /// `$0` of the script, so error messages from `sh` name something recognisable.
    private static let shellName = "ghast-softnet"

    static let handlerSource = """
    on runPrivileged(scriptText, args)
        set command to "/bin/sh -c " & quoted form of scriptText & " \(shellName)"
        repeat with argument in args
            set command to command & " " & quoted form of (argument as text)
        end repeat
        do shell script command with administrator privileges
    end runPrivileged
    """

    func run(script: String, arguments: [String]) async throws(PrivilegedScriptError) {
        guard let handlers = NSAppleScript(source: Self.handlerSource) else {
            throw .failed("The administrator prompt couldn't be prepared.")
        }
        var error: NSDictionary?
        _ = handlers.executeAppleEvent(Self.callEvent(script: script, arguments: arguments), error: &error)
        guard let error else { return }
        if (error[NSAppleScript.errorNumber] as? Int) == Self.userCancelled { throw .cancelled }
        let message = error[NSAppleScript.errorMessage] as? String
        throw .failed(message?.isEmpty == false ? message! : "The administrator command failed.")
    }

    private static func fourCharCode(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    /// A call of `runPrivileged(script, arguments)`: a subroutine event with a list of parameters.
    private static func callEvent(script: String, arguments: [String]) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(appleScriptSuite),
            eventID: AEEventID(subroutineEvent),
            targetDescriptor: NSAppleEventDescriptor.currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: handlerName), forKeyword: AEKeyword(subroutineName))
        let argumentList = NSAppleEventDescriptor.list()
        for (index, argument) in arguments.enumerated() {
            argumentList.insert(NSAppleEventDescriptor(string: argument), at: index + 1)
        }
        let parameters = NSAppleEventDescriptor.list()
        parameters.insert(NSAppleEventDescriptor(string: script), at: 1)
        parameters.insert(argumentList, at: 2)
        event.setParam(parameters, forKeyword: keyDirectObject)
        return event
    }
}
