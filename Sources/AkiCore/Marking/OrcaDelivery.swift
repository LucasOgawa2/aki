import Foundation

/// Runs Orca's command line (`orca-ide`) with these arguments. The real one and the
/// checks' fake share it; `AKI_DRY_DELIVER=1` swaps in one that only writes them down.
public protocol OrcaRunner: Sendable {
    func run(_ arguments: [String]) -> Command.Outcome
}

/// Typing the marks' message into the session's Orca tab. Differences from the Mac
/// (`TerminalJump.deliver`): one `terminal send` with Enter, always; the Mac first reads
/// the tab's screen and, with a draft in the agent's input box, sends the text after a
/// blank line and the Enter on its own. Never sent twice: `--retry-request` would reuse
/// an earlier request's answer, and repeating it by hand would type the message again.
extension LinuxMarking {
    public static func sendArguments(handle: String, prompt: String) -> [String] {
        ["terminal", "send", "--terminal", handle, "--text", prompt, "--enter", "--json"]
    }

    /// Orca's CLI: `orca-ide` on PATH, else in `~/.local/bin`. Never `orca`: outside
    /// Orca's terminals, `/usr/bin/orca` is GNOME's screen reader.
    public static func orcaExecutable(path: String?, home: URL) -> String? {
        executable(named: "orca-ide", path: path, also: [home.appending(path: ".local/bin").path])
    }

    /// The runner for this environment: the dry one with `AKI_DRY_DELIVER=1`, else the
    /// real `orca-ide`; nil when there's none.
    public static func orcaRunner(
        environment: [String: String] = ProcessInfo.processInfo.environment, akiHome: AkiHome = .default,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> (any OrcaRunner)? {
        if environment["AKI_DRY_DELIVER"] == "1" { return DryOrcaRunner(home: akiHome) }
        return orcaExecutable(path: environment["PATH"], home: home).map { ProcessOrcaRunner(executable: $0) }
    }

    public struct ProcessOrcaRunner: OrcaRunner {
        public let executable: String
        public init(executable: String) { self.executable = executable }

        /// Five seconds at most (its command starts a whole Node); no answer by then is
        /// `.timedOut`, which a send must take as "may have gone".
        public func run(_ arguments: [String]) -> Command.Outcome {
            Command.outcome(executable, arguments, timeout: 5)
        }
    }

    /// Types nothing: writes each run's arguments (without the program) as a JSON array,
    /// one per line, in `$AKI_HOME/dry-deliver.log`, and answers as Orca would. Its tab
    /// list is `$AKI_HOME/dry-terminals.json` when there is one (an end-to-end check's
    /// fixture), else empty.
    public struct DryOrcaRunner: OrcaRunner {
        public let home: AkiHome
        public init(home: AkiHome) { self.home = home }
        public var logURL: URL { home.url.appending(path: "dry-deliver.log") }

        public func run(_ arguments: [String]) -> Command.Outcome {
            guard (try? FileManager.default.createDirectory(at: home.url, withIntermediateDirectories: true)) != nil,
                  var line = try? JSONSerialization.data(withJSONObject: arguments)
            else { return .couldNotStart }
            line.append(0x0A)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                guard FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                else { return .couldNotStart }
            }
            guard let log = try? FileHandle(forWritingTo: logURL) else { return .couldNotStart }
            defer { try? log.close() }
            guard (try? log.seekToEnd()) != nil, (try? log.write(contentsOf: line)) != nil else { return .couldNotStart }
            if arguments.starts(with: ["terminal", "list"]) {
                let tabs = (try? Data(contentsOf: home.url.appending(path: "dry-terminals.json")))
                    ?? Data(#"{"ok":true,"result":{"terminals":[]}}"#.utf8)
                return .exited(status: 0, output: tabs)
            }
            return .exited(status: 0, output: Data(#"{"ok":true,"dry":true}"#.utf8))
        }
    }
}
