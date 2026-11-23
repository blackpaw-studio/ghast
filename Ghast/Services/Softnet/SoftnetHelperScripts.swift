import Foundation

/// The privileged scripts and fixed paths of the softnet helper. The scripts are constants: the
/// variable parts (source path, target folder) travel as arguments, never inside the text.
enum SoftnetHelperScripts {
    static let helperDirectory = "/usr/local/libexec/ghast"
    static let helperPath = helperDirectory + "/softnet"

    enum ScriptError: Error, Equatable {
        case resourceMissing
    }

    /// `install-softnet-helper.sh SOURCE TARGET_DIR`, read from the app bundle.
    static func installScript(bundle: Bundle = .main) throws -> String {
        try script(named: "install-softnet-helper", in: bundle)
    }

    /// `remove-softnet-helper.sh` (no arguments), read from the app bundle. It checks the same
    /// folder chain as the install script before it deletes anything.
    static func removeScript(bundle: Bundle = .main) throws -> String {
        try script(named: "remove-softnet-helper", in: bundle)
    }

    private static func script(named name: String, in bundle: Bundle) throws -> String {
        guard let url = bundle.url(forResource: name, withExtension: "sh"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { throw ScriptError.resourceMissing }
        return text
    }
}
