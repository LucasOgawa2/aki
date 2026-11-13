import Foundation

extension LinuxMarking {
    /// What Aki types into the session when its marks go over: a faithful copy of the
    /// Mac's `TerminalJump.deliveryPrompt` (same sentences, in Portuguese as there), with
    /// the way to call `aki` given (`akiInvocation`). One line: a line break would send it early.
    public static func deliveryPrompt(for terminal: AgentTerminal, aki: String) -> String {
        let count = max(terminal.undelivered, terminal.pending, 1)
        // In the commands, the id's whole random part; on screen the short code people read.
        let codes = terminal.pendingIDs.map { MarkFolder.folderName($0) }.filter { !$0.isEmpty }
        // What they're about (newest first), each with its code.
        let newestFirst = Array(terminal.pendingIDs.reversed())
        let about = terminal.pendingComments.enumerated().prefix(3).map { i, comment -> String in
            let code = i < newestFirst.count ? markCode(newestFirst[i]) : ""
            guard comment != "(no text)" else { return code }
            let line = comment.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "`", with: "'").trimmingCharacters(in: .whitespaces)
            return (code.isEmpty ? "" : code + " ") + "“" + (line.count > 50 ? String(line.prefix(50)) + "…" : line) + "”"
        }.filter { !$0.isEmpty }.joined(separator: " · ")
        let marks = count == 1 ? "1 marca nova" : "\(count) marcas novas"
        let session = terminal.name.replacingOccurrences(of: "`", with: "'")
        let places = terminal.pendingPlaces.prefix(2).joined(separator: ", ")
        let head = "📍 Aki → \(session): \(marks)" + (places.isEmpty ? "" : " (de \(places))")
            + (about.isEmpty ? "." : " — \(about).")
        // Codes only for Aki's own marks, and not too many: else the session's list.
        guard !codes.isEmpty, codes.count <= 8, terminal.pendingIDs.allSatisfy({ $0.hasPrefix("aki_") }) else {
            return head + " Leia com `\(aki) list` (abra a foto só se o pedido for visual), resolva e feche com `\(aki) done <códigos>`."
                + " Se não forem para esta sessão, avise antes de mexer."
        }
        let list = codes.joined(separator: " ")
        return head + " Leia com `\(aki) show \(list)` (abra a foto só se o pedido for visual), resolva e feche com `\(aki) done \(list)`."
            + " Se não forem para esta sessão, avise antes de mexer."
    }

    /// How the message names Aki's command (the Mac's `AkiCommand.invocation`): `aki`
    /// when the `aki` on PATH is this very binary, else this one's path, quoted for the shell.
    /// Both paths come resolved (symlinks followed).
    public static func akiInvocation(executable: String, akiOnPath: String?) -> String {
        akiOnPath == executable ? "aki" : shellQuoted(executable)
    }

    /// `/proc/self/exe` of a binary replaced while it runs (a rebuild) reads "… (deleted)".
    public static func executablePath(fromProcLink link: String) -> String {
        link.hasSuffix(" (deleted)") ? String(link.dropLast(" (deleted)".count)) : link
    }

    /// `name` in the folder of `executable`: `aki` and `aki-mark` are installed side by side.
    public static func sibling(_ name: String, of executable: String) -> String {
        URL(filePath: executable).deletingLastPathComponent().appending(path: name).path
    }

    /// Single quotes for a POSIX shell (and GLib's `g_shell_parse_argv`), `'` as `'\''`.
    public static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    #if os(Linux)
    /// This binary, from `/proc/self/exe`.
    public static func currentExecutable() -> String? {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe")).map(executablePath(fromProcLink:))
    }

    /// The `aki` a shell would run, symlinks followed; nil when PATH has none.
    public static func akiOnPath(_ path: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        executable(named: "aki", path: path).map { URL(filePath: $0).resolvingSymlinksInPath().path }
    }

    /// How this process's messages name `aki`.
    public static func currentInvocation() -> String {
        guard let executable = currentExecutable() else { return "aki" }
        return akiInvocation(executable: executable, akiOnPath: akiOnPath())
    }
    #endif
}
