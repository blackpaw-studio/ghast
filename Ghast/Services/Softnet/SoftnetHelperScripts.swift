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
        guard let url = bundle.url(forResource: "install-softnet-helper", withExtension: "sh"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { throw ScriptError.resourceMissing }
        return text
    }

    /// Removes the helper, and its folder when that is empty. Takes no arguments.
    static let removeScript = "/bin/rm -f \(helperPath); /bin/rmdir \(helperDirectory) 2>/dev/null; exit 0"
}
