import AkiCore
import Foundation
#if os(Linux)
import Glibc
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension Array { func at(_ i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }

struct FakeGSettingsTimeout: GSettingsRunner {
    func run(_ arguments: [String]) -> Command.Outcome { .timedOut }
}

final class FakeGSettings: GSettingsRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    let list: String
    let failing: String?
    init(list: String, failing: String? = nil) {
        self.list = list
        self.failing = failing
    }
    var ran: [[String]] { lock.withLock { calls } }
    var writes: [[String]] { ran.filter { $0.first != "get" } }
    func run(_ arguments: [String]) -> Command.Outcome {
        lock.withLock { calls.append(arguments) }
        if let failing, arguments.contains(failing) { return .exited(status: 1, output: Data()) }
        return .exited(status: 0, output: Data((arguments.first == "get" ? list + "\n" : "").utf8))
    }
}

typealias Overlay = LinuxMarking.OverlayState

func waitToken(_ effect: Overlay.Effect?) -> Int? {
    if case let .wait(token)? = effect { return token }
    return nil
}

func at(_ x: Double, _ y: Double) -> LinuxMarking.Point { .init(x: x, y: y) }

@MainActor func overlayChecks(orcaBin: URL) async throws {
    print("linux marking: overlay")
    let sessionA = LinuxMarking.terminal(id: "a", name: "A", worktree: "/a", lastSent: Date(timeIntervalSince1970: 10))
    let sessionB = LinuxMarking.terminal(id: "b", name: "B", worktree: "/b", lastSent: Date(timeIntervalSince1970: 20))
    let sessionC = LinuxMarking.terminal(id: "c", name: "C", worktree: "/c")
    check(Overlay(sessions: [sessionA, sessionB, sessionC]).destination == "b", "the destination starts on the session used last")
    check(Overlay(sessions: [sessionC, LinuxMarking.terminal(id: "d", name: "D", worktree: "/d")]).destination == "c", "none used yet: the first")
    check(Overlay(sessions: []).destination == nil, "no sessions: no destination")

    var overlay = Overlay(sessions: [sessionA, sessionB, sessionC])
    var edge = Overlay(sessions: [sessionA])
    _ = edge.handle(.pointer(screen: 0, from: at(100, 100), to: at(103, 104), app: nil))
    check(edge.marks.first?.rect == .init(x: 100, y: 100, width: 3, height: 4), "moved 5 px: already a drag")
    _ = overlay.handle(.pointer(screen: 1, from: at(100, 100), to: at(102, 103), app: .init(name: "firefox")))
    check(overlay.marks.count == 1 && overlay.marks.at(0)?.rect == .init(x: 100, y: 100, width: 0, height: 0) && overlay.marks.at(0)?.rect.isPoint == true
          && overlay.marks.at(0)?.screen == 1 && overlay.marks.at(0)?.app == .init(name: "firefox"), "moved under 5 px: a point where it was pressed")
    check(overlay.editing == overlay.marks.at(0)?.id && overlay.justMade && overlay.marks.at(0)?.number == 1, "and its card opens")
    _ = overlay.handle(.draft("  first note "))
    check(overlay.draft == "  first note " && !overlay.justMade, "typing edits the draft")
    _ = overlay.handle(.pointer(screen: 0, from: at(200, 90), to: at(20, 10), app: nil))
    check(overlay.marks.count == 2 && overlay.marks.at(0)?.comment == "first note" && overlay.marks.at(1)?.rect == .init(x: 20, y: 10, width: 180, height: 80),
          "a drag is an area; the card before it closes with its note kept (trimmed)")
    check(overlay.editing == overlay.marks.at(1)?.id && overlay.draft == "" && overlay.marks.at(1)?.number == 2, "the new one's card opens empty")
    check(overlay.handle(.undo) == nil && overlay.marks.count == 1 && overlay.editing == nil, "Ctrl+Z on a mark just made, nothing typed: it goes")
    _ = overlay.handle(.pointer(screen: 0, from: at(5, 5), to: at(5, 5), app: nil))
    _ = overlay.handle(.draft("words"))
    _ = overlay.handle(.undo)
    check(overlay.marks.count == 2 && overlay.draft == "words", "Ctrl+Z with words in the card: the mark stays")
    check(overlay.handle(.escape) == nil && overlay.marks.count == 2 && overlay.draft == "" && overlay.editing != nil, "Esc with words: clears them")
    check(overlay.handle(.escape) == nil && overlay.marks.count == 1 && overlay.editing == nil, "Esc on an empty card: drops its mark")
    _ = overlay.handle(.pointer(screen: 0, from: at(1, 1), to: at(1, 1), app: nil))
    _ = overlay.handle(.draft("second"))
    _ = overlay.handle(.pointer(screen: 0, from: at(2, 2), to: at(2, 2), app: nil))
    _ = overlay.handle(.draft("third"))
    _ = overlay.handle(.escape)
    _ = overlay.handle(.escape)
    check(overlay.editing == nil && overlay.marks.map(\.number) == [1, 2], "numbers stay in a row")
    _ = overlay.handle(.undo)
    check(overlay.marks.map(\.comment) == ["first note"], "Ctrl+Z with no card: the last mark goes")

    _ = overlay.handle(.nextDestination)
    check(overlay.destination == "c", "Tab: the next session")
    _ = overlay.handle(.nextDestination)
    check(overlay.destination == "a", "and round again")
    _ = overlay.handle(.previousDestination)
    check(overlay.destination == "c", "Shift+Tab: the one before")
    _ = overlay.handle(.destination(4))
    check(overlay.destination == "c", "Ctrl+4 with three sessions: nothing")
    _ = overlay.handle(.destination(1))
    check(overlay.destination == "a", "Ctrl+1: the first")

    _ = overlay.handle(.pointer(screen: 0, from: at(7, 7), to: at(7, 7), app: nil))
    _ = overlay.handle(.draft(" last "))
    let sendEffect = overlay.handle(.send)
    check(sendEffect == .send(overlay.marks, destination: "a") && overlay.marks.map(\.comment) == ["first note", "last"],
          "Ctrl+Enter closes the card and sends the queue to the destination")
    check(overlay.sending && overlay.editing == nil, "sending")
    check(overlay.handle(.send) == nil, "Ctrl+Enter twice: sent once")
    check(overlay.handle(.escape) == nil && overlay.sending, "Esc mid-send: ignored")
    _ = overlay.handle(.pointer(screen: 0, from: at(9, 9), to: at(9, 9), app: nil))
    _ = overlay.handle(.undo)
    check(overlay.marks.count == 2, "no mark made nor undone mid-send")
    let keptMark = overlay.marks.at(1)?.id ?? UUID()
    check(overlay.handle(.sendFinished(failed: [keptMark], warning: nil)) == nil && overlay.marks.map(\.id) == [keptMark]
          && overlay.marks.at(0)?.number == 1 && !overlay.sending, "a mark that couldn't be saved stays in the queue, numbered again")
    check(overlay.warning == "1 mark couldn't be saved: it's still here to send again.", "and the overlay says so")
    _ = overlay.handle(.send)
    check(overlay.handle(.sendFinished(failed: [], warning: nil)) == .close, "all sent: the overlay closes")

    var heldOverlay = Overlay(sessions: [sessionA])
    _ = heldOverlay.handle(.pointer(screen: 0, from: at(1, 1), to: at(1, 1), app: nil))
    _ = heldOverlay.handle(.send)
    check(heldOverlay.handle(.sendFinished(failed: [], warning: "A is asking you something")) == nil && heldOverlay.marks.isEmpty
          && heldOverlay.warning == "A is asking you something", "held: saved marks leave the queue, the overlay stays to say why")
    check(heldOverlay.handle(.escape) == .close, "Esc with no card: leaves")

    var emptyOverlay = Overlay(sessions: [sessionA])
    check(emptyOverlay.handle(.send) == .close, "Ctrl+Enter with an empty queue closes, as on the Mac")
    var lonely = Overlay(sessions: [])
    _ = lonely.handle(.pointer(screen: 0, from: at(1, 1), to: at(1, 1), app: nil))
    check(lonely.handle(.send) == nil && !lonely.sending && lonely.warning == "No agent session to send to: open one and mark again.",
          "zero sessions: not sent, and why")
    var late = Overlay(sessions: [])
    _ = late.handle(.sessionsChanged([sessionA, sessionB]))
    check(late.destination == "a", "the first sessions arriving with nothing marked: the first is the destination (as updateTerminals)")
    var lateMarked = Overlay(sessions: [])
    _ = lateMarked.handle(.pointer(screen: 0, from: at(1, 1), to: at(1, 1), app: nil))
    _ = lateMarked.handle(.sessionsChanged([sessionA]))
    check(lateMarked.destination == nil && lateMarked.handle(.send) == nil && lateMarked.warning == "Choose a session with Tab.",
          "marks made with no session and none chosen: not sent, and why")
    var orphan = Overlay(sessions: [sessionA, sessionB])
    _ = orphan.handle(.pointer(screen: 0, from: at(1, 1), to: at(1, 1), app: nil))
    _ = orphan.handle(.sessionsChanged([sessionA]))
    check(orphan.destination == "b" && orphan.handle(.send) == nil && !orphan.sending
          && orphan.warning == "B closed: choose another session with Tab.", "the destination gone from the list: not sent, and why")
    _ = orphan.handle(.nextDestination)
    check(orphan.destination == "a" && orphan.warning == nil, "choosing again clears the warning")

    print("linux marking: GNOME shortcut")
    let mediaKeys = "org.gnome.settings-daemon.plugins.media-keys"
    let akiKey = "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/aki/"
    let custom0 = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
    let custom1 = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1/"
    // Expected values worked out with GLib itself (python3-gi: g_shell_parse_argv, GVariant.parse).
    let oddAki = #"/home/u/my dir/it's "q"/aki"#
    check(GnomeShortcut.command(executable: oddAki) == #"'/home/u/my dir/it'\''s "q"/aki' mark"#, "the command: the path quoted for g_shell_parse_argv, then mark")
    check(GnomeShortcut.gvariantString(GnomeShortcut.command(executable: oddAki)) == #"'\'/home/u/my dir/it\'\\\'\'s "q"/aki\' mark'"#,
          "then as a GVariant string")
    check(GnomeShortcut.parseList("@as []") == [] && GnomeShortcut.parseList("[]") == [], "an empty list, typed or not")
    check(GnomeShortcut.parseList("['\(custom0)', '\(custom1)']") == [custom0, custom1], "a list with others")
    check(GnomeShortcut.parseList(#"['/a/', "/b'/", '/c\'d/']"#) == ["/a/", "/b'/", "/c'd/"], "quoted either way, escapes read")
    check(GnomeShortcut.parseList("['/a/'") == nil && GnomeShortcut.parseList("nonsense") == nil && GnomeShortcut.parseList("['/a/' '/b/']") == nil,
          "anything strange: nil")
    check(GnomeShortcut.formatList([]) == "@as []" && GnomeShortcut.formatList(["/a/", "/b'/"]) == #"['/a/', '/b\'/']"#, "the list written back")

    let freshGS = FakeGSettings(list: "@as []")
    let freshInstall = GnomeShortcut.install(executable: "/usr/local/bin/aki", runner: freshGS)
    check(freshInstall.ok && freshInstall.warning == nil && freshGS.writes == [
        ["set", akiKey, "name", "'Aki'"],
        ["set", akiKey, "command", "'\\'/usr/local/bin/aki\\' mark'"],
        ["set", akiKey, "binding", "'<Shift><Super>a'"],
        ["set", mediaKeys, "custom-keybindings", "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/aki/']"],
    ], "install on an empty list: the three keys, then the path in the list")
    check(freshGS.ran.first == ["get", mediaKeys, "custom-keybindings"], "the list read first")
    let othersGS = FakeGSettings(list: "['\(custom0)', '\(custom1)']")
    _ = GnomeShortcut.install(executable: "/usr/local/bin/aki", runner: othersGS)
    check(othersGS.writes.last == ["set", mediaKeys, "custom-keybindings", "['\(custom0)', '\(custom1)', '\(GnomeShortcut.path)']"],
          "the shortcuts already there stay")
    let againGS = FakeGSettings(list: "['\(custom0)', '\(GnomeShortcut.path)']")
    let again = GnomeShortcut.install(executable: "/usr/local/bin/aki", runner: againGS)
    check(again.ok && againGS.writes.count == 3 && !againGS.writes.contains { $0.contains("custom-keybindings") }, "installed already: the keys renewed, the list untouched")
    let buildGS = FakeGSettings(list: "@as []")
    let fromBuild = GnomeShortcut.install(executable: "/home/u/aki/.build/debug/aki", runner: buildGS)
    check(fromBuild.ok && fromBuild.warning == "This aki is inside .build: the shortcut breaks if that build goes away.", "from a build folder: installed, with a warning")
    let strangeGS = FakeGSettings(list: "{'what': 1}")
    check(!GnomeShortcut.install(executable: "/usr/local/bin/aki", runner: strangeGS).ok && strangeGS.writes.isEmpty, "a list it can't read: nothing written")
    let failingGS = FakeGSettings(list: "@as []", failing: "binding")
    let failedInstall = GnomeShortcut.install(executable: "/usr/local/bin/aki", runner: failingGS)
    check(!failedInstall.ok && !failingGS.writes.contains { $0.contains("custom-keybindings") }, "a key that can't be written: the list isn't touched")

    let removeGS = FakeGSettings(list: "['\(custom0)', '\(GnomeShortcut.path)', '\(custom1)']")
    let removed = GnomeShortcut.remove(runner: removeGS)
    check(removed.ok && removeGS.writes == [
        ["set", mediaKeys, "custom-keybindings", "['\(custom0)', '\(custom1)']"],
        ["reset", akiKey, "name"], ["reset", akiKey, "command"], ["reset", akiKey, "binding"],
    ], "remove: out of the list first, then its keys reset; the others stay")
    let removeLastGS = FakeGSettings(list: "['\(GnomeShortcut.path)']")
    _ = GnomeShortcut.remove(runner: removeLastGS)
    check(removeLastGS.writes.first == ["set", mediaKeys, "custom-keybindings", "@as []"], "the last one out: an empty list")
    let notThereGS = FakeGSettings(list: "['\(custom0)']")
    let notThere = GnomeShortcut.remove(runner: notThereGS)
    check(notThere.ok && notThereGS.writes.count == 3 && notThereGS.writes.allSatisfy { $0.first == "reset" }, "remove when it isn't there: only the keys reset")
    let slowGS = FakeGSettingsTimeout()
    check(!GnomeShortcut.install(executable: "/usr/local/bin/aki", runner: slowGS).ok
          && GnomeShortcut.install(executable: "/usr/local/bin/aki", runner: slowGS).message == "gsettings didn't answer in time.", "gsettings not answering: fails, says so")
    _ = FileManager.default.createFile(atPath: orcaBin.appending(path: "gsettings").path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    check(GnomeShortcut.gsettings(path: "/nonexistent") == nil && GnomeShortcut.gsettings(path: "/nonexistent:" + orcaBin.path) == orcaBin.appending(path: "gsettings").path,
          "gsettings found on PATH")

    print("linux marking: Enter, root and monitors, window names, dry sessions")
    var entering = Overlay(sessions: [sessionA])
    _ = entering.handle(.pointer(screen: 0, from: at(10, 10), to: at(80, 60), app: nil))
    _ = entering.handle(.draft("  queue me "))
    check(entering.handle(.commit) == nil && entering.editing == nil && entering.marks.at(0)?.comment == "queue me" && !entering.sending,
          "Enter with a note: it goes to the queue, nothing sent")
    let enterSends = entering.handle(.commit)
    check(enterSends == .send(entering.marks, destination: "a") && entering.sending, "Enter with no card open: sends the queue")
    var enterEmpty = Overlay(sessions: [sessionA])
    _ = enterEmpty.handle(.pointer(screen: 0, from: at(10, 10), to: at(10, 10), app: nil))
    _ = enterEmpty.handle(.draft("   "))
    check(enterEmpty.handle(.commit) == .send(enterEmpty.marks, destination: "a") && enterEmpty.marks.at(0)?.comment == "",
          "Enter on a card with an empty (blank) note: sends, the mark with it")

    // This machine's monitors, in GDK's order (not left to right): eDP-1 on the right, HDMI-1-0 on the left.
    let eDP = LinuxMarking.Monitor(x: 1920, y: 0, width: 1920, height: 1080)
    let hdmi = LinuxMarking.Monitor(x: 0, y: 0, width: 1920, height: 1080)
    let monitors = [eDP, hdmi]
    check(LinuxMarking.monitor(containing: at(2500, 300), in: monitors) == 0 && LinuxMarking.monitor(containing: at(100, 900), in: monitors) == 1,
          "a root point's monitor is its place in GDK's list, not left to right")
    check(LinuxMarking.monitor(containing: at(1920, 0), in: monitors) == 0 && LinuxMarking.monitor(containing: at(1919.5, 0), in: monitors) == 1,
          "on the edge between them: the one it starts (right edge excluded)")
    check(LinuxMarking.monitor(containing: at(4000, 10), in: monitors) == nil && LinuxMarking.monitor(containing: at(10, 1080), in: monitors) == nil,
          "outside every monitor: none")
    check(LinuxMarking.rootRect(of: .init(x: 100, y: 50, width: 300, height: 200), on: eDP) == .init(x: 2020, y: 50, width: 300, height: 200)
          && LinuxMarking.rootRect(of: .init(x: 100, y: 50, width: 0, height: 0), on: hdmi) == .init(x: 100, y: 50, width: 0, height: 0),
          "a mark's local rect back in root pixels, for the crop")
    let hidpi = LinuxMarking.Monitor(x: 1280, y: 0, width: 1280, height: 720, scale: 2)
    check(LinuxMarking.devicePoint(at(10, 20.5), on: hidpi) == at(20, 41) && LinuxMarking.devicePoint(at(10, 20), on: eDP) == at(10, 20),
          "a window point in device pixels: times the scale")
    check(LinuxMarking.rootRect(of: .init(x: 20, y: 40, width: 100, height: 60), on: hidpi) == .init(x: 2580, y: 40, width: 100, height: 60),
          "scale 2: the monitor's origin in device pixels too")
    check(LinuxMarking.devicePoint(at(-30, 1200), on: eDP) == at(0, 1079) && LinuxMarking.devicePoint(at(5000, -1), on: hidpi) == at(2559, 0),
          "a drag that leaves its monitor stops at its edge (a mark never spans two)")
    check(LinuxMarking.devicePixels(of: hidpi) == .init(width: 2560, height: 1440) && LinuxMarking.devicePixels(of: hdmi) == .init(width: 1920, height: 1080),
          "a monitor's size in the capture's pixels")

    check(LinuxMarking.windowClass(fromWMClass: Array("google-chrome\0Google-chrome\0".utf8)) == "Google-chrome", "WM_CLASS: the class, not the instance")
    check(LinuxMarking.windowClass(fromWMClass: Array("xterm\0XTerm".utf8)) == "XTerm", "WM_CLASS without its last NUL")
    check(LinuxMarking.windowClass(fromWMClass: Array("solo\0".utf8)) == "solo" && LinuxMarking.windowClass(fromWMClass: []) == nil
          && LinuxMarking.windowClass(fromWMClass: Array("\0\0".utf8)) == nil, "only an instance: that; nothing: none")
    check(LinuxMarking.windowTitle(fromProperty: Array("Inbox — Mozilla Firefox".utf8)) == "Inbox — Mozilla Firefox", "_NET_WM_NAME is UTF-8")
    check(LinuxMarking.windowTitle(fromProperty: Array("title\0".utf8)) == "title" && LinuxMarking.windowTitle(fromProperty: []) == nil
          && LinuxMarking.windowTitle(fromProperty: [0x61, 0xFF, 0x62]) == "a\u{FFFD}b", "a trailing NUL dropped, empty is none, bad bytes replaced")

    let fakeSessionsHome = AkiHome(url: temp.appending(path: "dry-sessions-home"))
    try FileManager.default.createDirectory(at: fakeSessionsHome.url, withIntermediateDirectories: true)
    try Data(#"[{"id":"s1","name":"SITE","worktree":"/w/site","orcaHandle":"term_x","state":"waiting","agent":"codex","lastSent":20},{"id":"s2","name":"API","worktree":"/w/api"}]"#.utf8)
        .write(to: fakeSessionsHome.url.appending(path: "dry-sessions.json"))
    let realOne = [LinuxMarking.terminal(id: "real", name: "REAL", worktree: "/real")]
    let fakeSessions = LinuxMarking.sessions(environment: ["AKI_DRY_DELIVER": "1"], home: fakeSessionsHome) { realOne }
    check(fakeSessions == [
        LinuxMarking.terminal(id: "s1", agent: .codex, name: "SITE", worktree: "/w/site", state: .waiting, orcaHandle: "term_x", lastSent: Date(timeIntervalSince1970: 20)),
        LinuxMarking.terminal(id: "s2", name: "API", worktree: "/w/api"),
    ], "dry: the sessions come from $AKI_HOME/dry-sessions.json, never the real ones")
    check(LinuxMarking.sessions(environment: [:], home: fakeSessionsHome) { realOne } == realOne, "not dry: that file is ignored, the real listing")
    try Data("[]".utf8).write(to: fakeSessionsHome.url.appending(path: "dry-sessions.json"))
    check(LinuxMarking.sessions(environment: ["AKI_DRY_DELIVER": "1"], home: fakeSessionsHome) { realOne }.isEmpty, "dry with an empty list: zero sessions")
    try Data("{nope".utf8).write(to: fakeSessionsHome.url.appending(path: "dry-sessions.json"))
    check(LinuxMarking.sessions(environment: ["AKI_DRY_DELIVER": "1"], home: fakeSessionsHome) { realOne }.isEmpty
          && LinuxMarking.sessions(environment: ["AKI_DRY_DELIVER": "1"], home: AkiHome(url: temp.appending(path: "none"))) { realOne }.isEmpty,
          "dry with no file or a broken one: zero sessions, still not the real ones")

    check(LinuxMarking.sibling("aki-mark", of: "/home/u/.local/bin/aki") == "/home/u/.local/bin/aki-mark"
          && LinuxMarking.sibling("aki", of: "/opt/aki dir/aki-mark") == "/opt/aki dir/aki", "aki and aki-mark find each other in the same folder")

    print("linux marking: text read under an area (OCR)")
    var textMark = LinuxMarking.PortableMark(screen: 0, rect: .init(x: 10, y: 20, width: 300, height: 40), number: 1, selectedText: "Save changes\nCancel")
    check(LinuxMarking.fields(of: textMark, id: "aki_1_t", batch: "batch_1", terminal: plainSession, imagePath: "/h/t.jpg")["selected_text"] == "Save changes\nCancel",
          "the text read under an area goes in selected_text")
    textMark.selectedText = String(repeating: "é", count: 4100)
    check(LinuxMarking.fields(of: textMark, id: "aki_1_t", batch: "batch_1", terminal: plainSession, imagePath: "/h/t.jpg")["selected_text"]
          == .string(String(repeating: "é", count: 4000)), "cut at 4000 characters, as the Mac")
    textMark.selectedText = ""
    check(LinuxMarking.fields(of: textMark, id: "aki_1_t", batch: "batch_1", terminal: plainSession, imagePath: "/h/t.jpg")["selected_text"] == nil
          && LinuxMarking.fields(of: areaMark, id: "aki_1_a", batch: "batch_1", terminal: orcaSession, imagePath: "/h/crop.jpg")["selected_text"] == nil,
          "no text, or empty: no selected_text")

    typealias OCR = LinuxMarking.OCR
    let listLangs = "List of available languages in \"/usr/share/tesseract-ocr/5/tessdata/\" (3):\neng\nosd\npor\n"
    check(OCR.languages(fromListLangs: listLangs) == ["por", "eng"], "languages: Portuguese and English when installed, never osd")
    check(OCR.languages(fromListLangs: "List of available languages in \"/x/\" (2):\neng\nosd\n") == ["eng"], "only English: that")
    check(OCR.languages(fromListLangs: "List of available languages in \"/por/eng/\" (1):\nosd\n").isEmpty && OCR.languages(fromListLangs: "").isEmpty,
          "neither (the heading's path doesn't count): none, no OCR")

    check(OCR.arguments(image: "/run/a.ppm", outputBase: "/run/a", languages: ["por", "eng"]) == ["/run/a.ppm", "/run/a", "-l", "por+eng", "--dpi", "300", "tsv"]
          && OCR.arguments(image: "i", outputBase: "o", languages: ["eng"]) == ["i", "o", "-l", "eng", "--dpi", "300", "tsv"],
          "tesseract's arguments: the image, the output's base, the languages, 300 dpi, TSV")
    check(OCR.scale(for: .init(width: 324, height: 64)) == 3 && OCR.scale(for: .init(width: 500, height: 555)) == 3,
          "a small crop: 3x (500x555 at 3x is 2.497 MP)")
    check(OCR.scale(for: .init(width: 500, height: 556)) == 2 && OCR.scale(for: .init(width: 790, height: 790)) == 2, "too big for 3x: 2x")
    check(OCR.scale(for: .init(width: 791, height: 791)) == 1 && OCR.scale(for: .init(width: 1944, height: 1104)) == 1, "too big for 2x: as it is")

    let twoPixels: [UInt8] = [1, 2, 3, 4, 5, 6]
    check(OCR.ppm(rgb: twoPixels, size: .init(width: 2, height: 1), scale: 2) == Data("P6\n4 2\n255\n".utf8) + Data([1, 2, 3, 1, 2, 3, 4, 5, 6, 4, 5, 6, 1, 2, 3, 1, 2, 3, 4, 5, 6, 4, 5, 6]),
          "the crop as a P6 PPM, each pixel a 2x2 block")
    check(OCR.ppm(rgb: twoPixels, size: .init(width: 1, height: 2), scale: 1) == Data("P6\n1 2\n255\n".utf8) + Data(twoPixels), "scale 1: as it is")
    check(OCR.ppm(rgb: twoPixels, size: .init(width: 3, height: 1), scale: 1) == nil && OCR.ppm(rgb: [], size: .init(width: 0, height: 0), scale: 3) == nil
          && OCR.ppm(rgb: twoPixels, size: .init(width: 2, height: 1), scale: 0) == nil, "bytes that aren't the size's, nothing, or no scale: none")

    let rightMonitor = LinuxMarking.Monitor(x: 1920, y: 0, width: 1920, height: 1080)
    let cornerMark = LinuxMarking.PortableMark(screen: 0, rect: .init(x: 0, y: 0, width: 100, height: 20), number: 1)
    check(OCR.region(for: cornerMark, on: rightMonitor) == .init(local: .init(x: 0, y: 0, width: 112, height: 32), root: .init(x: 1920, y: 0, width: 112, height: 32), scale: 3),
          "an area in the corner of a monitor at x=1920: its crop held to the monitor, moved to the root only for the pixels")
    let hidpiMonitor = LinuxMarking.Monitor(x: 1280, y: 0, width: 1280, height: 720, scale: 2)
    check(OCR.region(for: .init(screen: 0, rect: .init(x: 100, y: 50, width: 1000, height: 500), number: 1), on: hidpiMonitor)
          == .init(local: .init(x: 88, y: 38, width: 1024, height: 524), root: .init(x: 2648, y: 38, width: 1024, height: 524), scale: 2),
          "scale 2 monitor: the root in device pixels; a big crop: 2x")
    check(OCR.region(for: .init(screen: 0, rect: .init(x: 5, y: 5, width: 0, height: 0), number: 1), on: rightMonitor) == nil
          && OCR.region(for: .init(screen: 0, rect: .init(x: 4000, y: 5, width: 50, height: 50), number: 1), on: rightMonitor) == nil,
          "a point reads nothing; an area off its monitor neither")

    // tesseract 5.3.4's TSV (levels 1-4 end in a tab, conf -1, no text), for a mark at
    // (100, 200) 300x40: its crop starts at (88, 188), read at 3x. Block 1 is the lower line.
    let tsvHeader = "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n"
    let tsvRegion = OCR.Region(local: .init(x: 88, y: 188, width: 324, height: 64), root: .init(x: 88, y: 188, width: 324, height: 64), scale: 3)
    let tsvRect = LinuxMarking.Rect(x: 100, y: 200, width: 300, height: 40)
    let tsv = tsvHeader + """
    1\t1\t0\t0\t0\t0\t0\t0\t972\t192\t-1\t
    2\t1\t1\t0\t0\t0\t60\t90\t400\t30\t-1\t
    3\t1\t1\t1\t0\t0\t60\t90\t400\t30\t-1\t
    4\t1\t1\t1\t1\t0\t60\t90\t400\t30\t-1\t
    5\t1\t1\t1\t1\t1\t60\t90\t110\t30\t96.87\tCancel
    5\t1\t1\t1\t1\t2\t180\t90\t30\t30\t-1\t~
    5\t1\t1\t1\t1\t3\t220\t90\t60\t30\t95.06\tthe
    5\t1\t1\t1\t1\t4\t290\t90\t120\t30\t1.22\torder
    2\t1\t2\t0\t0\t0\t60\t45\t230\t30\t-1\t
    4\t1\t2\t1\t1\t0\t60\t45\t230\t30\t-1\t
    5\t1\t2\t1\t1\t1\t60\t45\t90\t30\t84.6\tSave
    5\t1\t2\t1\t1\t2\t160\t45\t130\t30\t69.6\tchanges
    4\t1\t3\t1\t1\t0\t60\t150\t200\t30\t-1\t
    5\t1\t3\t1\t1\t1\t60\t150\t200\t30\t91.0\tcut
    4\t1\t4\t1\t1\t0\t300\t10\t30\t30\t-1\t
    5\t1\t4\t1\t1\t1\t300\t10\t30\t30\t-1\t
    5\t1\t4\t1\t1\t2\t340\t10
    """
    check(OCR.text(fromTSV: tsv, region: tsvRegion, in: tsvRect) == "Save changes\nCancel the order",
          "TSV: words joined per line, lines top to bottom whatever the block order; conf -1 dropped; the line cut at the edge (its middle outside) left out")
    let sideBySide = tsvHeader + """
    5\t1\t1\t1\t1\t1\t200\t66\t60\t30\t90\tRight
    5\t1\t2\t1\t1\t1\t60\t60\t60\t30\t90\tLeft
    """
    check(OCR.text(fromTSV: sideBySide, region: tsvRegion, in: tsvRect) == "Left\nRight", "lines within 4 px of the same top: left to right, as the Mac")
    check(OCR.text(fromTSV: "", region: tsvRegion, in: tsvRect) == nil && OCR.text(fromTSV: tsvHeader, region: tsvRegion, in: tsvRect) == nil
          && OCR.text(fromTSV: tsvHeader + "5\t1\t1\t1\t1\t1\t60\t45\t90\t30\t80\t   \n", region: tsvRegion, in: tsvRect) == nil,
          "nothing read, only the header, or only blanks: no text")
    check(OCR.text(fromTSV: tsvHeader + "5\t1\t1\t1\t1\t1\t60\t45\t90\t30\t80\t\(String(repeating: "x", count: 5000))\n", region: tsvRegion, in: tsvRect)?.count == 4000,
          "a huge read: cut at 4000")
    let cornerRegion = OCR.region(for: cornerMark, on: rightMonitor)!
    check(OCR.text(fromTSV: tsvHeader + "5\t1\t1\t1\t1\t1\t6\t6\t120\t30\t90\tFile\n5\t1\t2\t1\t1\t1\t310\t6\t30\t30\t90\tEdge\n", region: cornerRegion, in: cornerMark.rect) == "File",
          "a mark at (0, 0) on the monitor at x=1920: lines placed in the monitor's own pixels (one past the mark's right edge out)")

    // A stand-in tesseract (the CI has none): it says how it was called and writes its TSV.
    let ocrHome = temp.appending(path: "ocr")
    let ocrRun = ocrHome.appending(path: "run")
    try FileManager.default.createDirectory(at: ocrRun, withIntermediateDirectories: true)
    func fakeTesseract(_ name: String, _ body: String) -> String {
        let path = ocrHome.appending(path: name).path
        _ = FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n\(body)\n".utf8), attributes: [.posixPermissions: 0o755])
        return path
    }
    let calls = ocrHome.appending(path: "calls").path
    try Data((tsvHeader + "5\t1\t1\t1\t1\t1\t60\t45\t90\t30\t84.6\tSave\n").utf8).write(to: ocrHome.appending(path: "canned.tsv"))
    let goodTesseract = fakeTesseract("good", "echo \"$@\" > '\(calls)'; stat -c %a \"$1\" >> '\(calls)'; head -c 2 \"$1\" >> '\(calls)'; cp '\(ocrHome.appending(path: "canned.tsv").path)' \"$2.tsv\"")
    let tsvRGB = [UInt8](repeating: 255, count: 324 * 64 * 3)
    let readOK = OCR.read(rgb: tsvRGB, region: tsvRegion, in: tsvRect, tesseract: goodTesseract, languages: ["por", "eng"], directory: ocrRun)
    check(readOK == .success("Save"), "a read: tesseract's TSV, the text under the mark")
    let called = (try? String(contentsOfFile: calls, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
    check(called.at(0)?.hasSuffix(" -l por+eng --dpi 300 tsv") == true && called.at(0)?.hasPrefix(ocrRun.path + "/aki-ocr-\(getpid())-") == true
          && called.at(1) == "600" && called.at(2) == "P6", "the crop goes as a private (0600) PPM named aki-ocr-<pid>-…, in the folder given")
    check((try? FileManager.default.contentsOfDirectory(atPath: ocrRun.path))?.isEmpty == true, "and neither it nor the TSV is left")
    let failingTesseract = fakeTesseract("failing", "echo boom > \"$2.tsv\"; exit 1")
    check(OCR.read(rgb: tsvRGB, region: tsvRegion, in: tsvRect, tesseract: failingTesseract, languages: ["eng"], directory: ocrRun) == .failure(.failed)
          && (try? FileManager.default.contentsOfDirectory(atPath: ocrRun.path))?.isEmpty == true, "tesseract failing: no text, nothing left")
    let slowTesseract = fakeTesseract("slow", "exec sleep 10")
    let slowStart = Date()
    check(OCR.read(rgb: tsvRGB, region: tsvRegion, in: tsvRect, tesseract: slowTesseract, languages: ["eng"], directory: ocrRun, timeout: 0.5) == .failure(.failed)
          && Date().timeIntervalSince(slowStart) < 3 && (try? FileManager.default.contentsOfDirectory(atPath: ocrRun.path))?.isEmpty == true,
          "tesseract not ending in time: stopped, no text, nothing left")
    let silentTesseract = fakeTesseract("silent", "rm -f \"$2.tsv\"; exit 0")
    check(OCR.read(rgb: tsvRGB, region: tsvRegion, in: tsvRect, tesseract: silentTesseract, languages: ["eng"], directory: ocrRun) == .failure(.noOutput),
          "tesseract writing nothing: no text")
    let emptyTesseract = fakeTesseract("empty", "printf '' > \"$2.tsv\"")
    check(OCR.read(rgb: tsvRGB, region: tsvRegion, in: tsvRect, tesseract: emptyTesseract, languages: ["eng"], directory: ocrRun) == .success(nil),
          "an area with no words: read, no text")
    check(OCR.read(rgb: tsvRGB, region: tsvRegion, in: tsvRect, tesseract: goodTesseract, languages: [], directory: ocrRun) == .failure(.noLanguages)
          && OCR.read(rgb: [1, 2], region: tsvRegion, in: tsvRect, tesseract: goodTesseract, languages: ["eng"], directory: ocrRun) == .failure(.badImage)
          && OCR.read(rgb: tsvRGB, region: tsvRegion, in: tsvRect, tesseract: goodTesseract, languages: ["eng"], directory: ocrHome.appending(path: "nope")) == .failure(.couldNotWrite),
          "no language, pixels that don't fit, or a folder that isn't there: no text, tesseract not run")
    check(OCR.temporaryDirectory(environment: ["XDG_RUNTIME_DIR": ocrRun.path]).path == ocrRun.path
          && OCR.temporaryDirectory(environment: ["XDG_RUNTIME_DIR": "/nonexistent-aki"]).path == FileManager.default.temporaryDirectory.path
          && OCR.temporaryDirectory(environment: [:]).path == FileManager.default.temporaryDirectory.path, "crops go to XDG_RUNTIME_DIR when it's there, else the temporary folder")
    for (name, age) in [("aki-ocr-1-a.ppm", 3600.0), ("aki-ocr-1-a.tsv", 3600), ("aki-ocr-2-b.ppm", 0), ("other.ppm", 3600)] {
        let path = ocrRun.appending(path: name).path
        _ = FileManager.default.createFile(atPath: path, contents: Data())
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path)
    }
    OCR.removeStale(in: ocrRun, before: Date().addingTimeInterval(-60))
    check(Set((try? FileManager.default.contentsOfDirectory(atPath: ocrRun.path)) ?? []) == ["aki-ocr-2-b.ppm", "other.ppm"],
          "at start, old crops of ours are removed; a fresh one (another read) and anything else stay")

    print("linux marking: overlay waiting for the text")
    var reading = Overlay(sessions: [sessionA], readsText: true)
    let readArea = reading.handle(.pointer(screen: 0, from: at(10, 10), to: at(80, 60), app: nil))
    check(readArea == .enrich(reading.marks[0], sources: [.text]) && reading.isPending(reading.marks[0].id), "reading text: an area drawn asks for its words, and waits for them")
    check(reading.handle(.pointer(screen: 0, from: at(5, 5), to: at(5, 5), app: nil)) == nil && !reading.isPending(reading.marks[1].id),
          "a point reads nothing (as on the Mac)")
    var notReading = Overlay(sessions: [sessionA])
    check(notReading.handle(.pointer(screen: 0, from: at(10, 10), to: at(80, 60), app: nil)) == nil && !notReading.isPending(notReading.marks[0].id),
          "no tesseract: nothing asked, nothing waited for")

    let readID = reading.marks[0].id
    check(reading.handle(.enriched(id: readID, .init(text: "Save changes"))) == nil && reading.marks[0].selectedText == "Save changes" && !reading.isPending(readID),
          "the words arrive: on the mark, no longer waited for")
    check(reading.handle(.enriched(id: readID, .init(text: "again"))) == nil && reading.marks[0].selectedText == "Save changes",
          "a second answer for a mark not waited for: ignored")
    var undone = Overlay(sessions: [sessionA], readsText: true)
    _ = undone.handle(.pointer(screen: 0, from: at(10, 10), to: at(80, 60), app: nil))
    let undoneID = undone.marks[0].id
    _ = undone.handle(.undo)
    _ = undone.handle(.pointer(screen: 0, from: at(10, 10), to: at(80, 60), app: nil))
    check(undone.handle(.enriched(id: undoneID, .init(text: "late"))) == nil && !undone.isPending(undoneID) && undone.marks.allSatisfy { $0.selectedText == nil },
          "the words of a mark undone arrive late: ignored")
    let escapedID = undone.marks[0].id
    _ = undone.handle(.escape)
    check(undone.marks.isEmpty && !undone.isPending(escapedID) && undone.handle(.enriched(id: escapedID, .init(text: "x"))) == nil && undone.marks.isEmpty,
          "Esc on its card: the same")

    var waiting = Overlay(sessions: [sessionA, sessionB], readsText: true)
    _ = waiting.handle(.pointer(screen: 0, from: at(10, 10), to: at(80, 60), app: nil))
    _ = waiting.handle(.draft("rename it"))
    let waitingID = waiting.marks[0].id
    let firstToken = waitToken(waiting.handle(.send))
    check(firstToken != nil && waiting.sending && waiting.waitingForReads && waiting.marks[0].comment == "rename it" && waiting.destination == "b",
          "Ctrl+Enter with a read going: the card closes, the send waits for it")
    check(waiting.handle(.send) == nil && waiting.handle(.commit) == nil && waiting.handle(.escape) == nil && waiting.sending, "Ctrl+Enter twice, Enter and Esc while waiting: ignored")
    _ = waiting.handle(.nextDestination)
    _ = waiting.handle(.previousDestination)
    _ = waiting.handle(.destination(1))
    check(waiting.destination == "b", "Tab, Shift+Tab and Ctrl+1 while waiting: ignored, it goes where Ctrl+Enter said")
    let waitSend = waiting.handle(.enriched(id: waitingID, .init(text: "Old name")))
    check(waitSend == .send(waiting.marks, destination: "b") && waiting.marks[0].selectedText == "Old name" && !waiting.waitingForReads && waiting.sending,
          "the last read arrives: sent at once, with its words")
    check(waiting.handle(.deadline(firstToken ?? -1)) == nil, "the wait's time then up: nothing sent twice")
    check(waiting.handle(.sendFinished(failed: [], warning: nil)) == .close, "and it closes once saved")

    var slowRead = Overlay(sessions: [sessionA], readsText: true)
    _ = slowRead.handle(.pointer(screen: 0, from: at(10, 10), to: at(80, 60), app: nil))
    _ = slowRead.handle(.pointer(screen: 0, from: at(100, 100), to: at(180, 160), app: nil))
    let slowIDs = slowRead.marks.map(\.id)
    _ = slowRead.handle(.enriched(id: slowIDs[1], .init(text: "second")))
    let slowToken = waitToken(slowRead.handle(.send)) ?? -1
    check(slowToken >= 0 && slowRead.handle(.deadline(slowToken + 1)) == nil && slowRead.waitingForReads, "another wait's time: ignored")
    let deadlineSend = slowRead.handle(.deadline(slowToken))
    check(deadlineSend == .send(slowRead.marks, destination: "a") && slowRead.marks.map(\.selectedText) == [nil, "second"],
          "the time up with a read still going: sent with what was read")
    check(slowRead.handle(.enriched(id: slowIDs[0], .init(text: "too late"))) == nil, "its words arriving mid-send: nothing more sent")
    _ = slowRead.handle(.sendFinished(failed: [slowIDs[0]], warning: nil))
    check(slowRead.marks.map(\.id) == [slowIDs[0]] && !slowRead.isPending(slowIDs[0]), "a mark that couldn't be saved stays, no longer waited for")
    check(slowRead.handle(.send) == .send(slowRead.marks, destination: "a"), "sent again: nothing to wait for, at once")

    var oldTimer = Overlay(sessions: [sessionA], readsText: true)
    _ = oldTimer.handle(.pointer(screen: 0, from: at(10, 10), to: at(80, 60), app: nil))
    let oldToken = waitToken(oldTimer.handle(.send))
    let failedRead = oldTimer.handle(.enriched(id: oldTimer.marks[0].id, .init(text: nil)))
    check(failedRead == .send(oldTimer.marks, destination: "a") && oldTimer.marks[0].selectedText == nil, "a read that failed (no text) frees the wait: sent without words")
    _ = oldTimer.handle(.sendFinished(failed: [oldTimer.marks[0].id], warning: nil))
    _ = oldTimer.handle(.pointer(screen: 0, from: at(100, 100), to: at(180, 160), app: nil))
    let newToken = waitToken(oldTimer.handle(.send))
    check(newToken != nil && newToken != oldToken && oldTimer.handle(.deadline(oldToken ?? -1)) == nil && oldTimer.waitingForReads,
          "an old wait's timer never sends a new one")

    var warned = Overlay(sessions: [], readsText: true)
    _ = warned.handle(.pointer(screen: 0, from: at(10, 10), to: at(80, 60), app: nil))
    _ = warned.handle(.send)
    _ = warned.handle(.enriched(id: warned.marks[0].id, .init(text: "words")))
    check(warned.warning == "No agent session to send to: open one and mark again." && warned.marks[0].selectedText == "words",
          "words arriving while a warning shows: the warning stays")
    var heldRead = Overlay(sessions: [sessionA], readsText: true)
    _ = heldRead.handle(.pointer(screen: 0, from: at(10, 10), to: at(80, 60), app: nil))
    let heldToken = waitToken(heldRead.handle(.send))
    _ = heldRead.handle(.enriched(id: heldRead.marks[0].id, .init(text: "words")))
    _ = heldRead.handle(.sendFinished(failed: [], warning: "A is asking you something"))
    check(heldRead.handle(.deadline(heldToken ?? -1)) == nil && heldRead.warning == "A is asking you something", "the wait's timer firing after: the warning stays")

}
