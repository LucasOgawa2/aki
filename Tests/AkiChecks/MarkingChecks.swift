import AkiCore
import Foundation
#if os(Linux)
import Glibc
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class RandomParts: @unchecked Sendable {
    private var left: [String]
    private let lock = NSLock()
    init(_ parts: [String]) { left = parts }
    func next() -> String { lock.withLock { left.isEmpty ? "zzzzzzzz" : left.removeFirst() } }
}

final class FakeOrca: OrcaRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    let tabs: Command.Outcome, send: Command.Outcome
    init(tabs: Command.Outcome, send: Command.Outcome = .exited(status: 0, output: Data(#"{"ok":true}"#.utf8))) {
        self.tabs = tabs
        self.send = send
    }
    var ran: [[String]] { lock.withLock { calls } }
    var sends: [[String]] { ran.filter { $0.starts(with: ["terminal", "send"]) } }
    func run(_ arguments: [String]) -> Command.Outcome {
        lock.withLock { calls.append(arguments) }
        return arguments.starts(with: ["terminal", "list"]) ? tabs : send
    }
}

// Shared with the overlay's checks.
let orcaSession = LinuxMarking.terminal(id: "s1", name: "SITE", worktree: "/repo/site", orcaHandle: "term_1")
let plainSession = LinuxMarking.terminal(id: "codex:42", agent: .codex, name: "api", worktree: "/repo/api")
let areaMark = LinuxMarking.PortableMark(screen: 1, rect: .init(x: 10, y: 20, width: 300, height: 40), comment: "bigger", number: 2,
                                         app: .init(name: "firefox", window: "Docs — Mozilla Firefox"))

/// Returns the folder with the fake `orca` the overlay's checks use too.
@MainActor func markingChecks() async throws -> URL {
    // MARK: Linux marking (no interface)

    print("linux marking: fields")
    let markRandom = RandomParts(["df9f68ee", "0a1b2c3d"])
    let markClock = LinuxMarking.Clock(now: { Date(timeIntervalSince1970: 1_791_339_895.5) }, random: { markRandom.next() })
    check(LinuxMarking.markID(at: Date(timeIntervalSince1970: 1_791_339_895.5), random: "df9f68ee") == "aki_1791339895500_df9f68ee", "a mark's id is aki_<ms>_<8 chars>, as on the Mac")
    check(LinuxMarking.batchID(at: markClock.now()) == "batch_1791339895500", "the batch id is batch_<ms>")
    check(LinuxMarking.sessionFields(of: orcaSession) == [
        "session_id": "s1", "worktree": "/repo/site", "agent": "claude", "session_name": "SITE", "terminal_app": ["name": "Orca"],
    ], "a session in an Orca tab: its identity, terminal_app Orca")
    check(LinuxMarking.sessionFields(of: plainSession)["terminal_app"] == .null, "no Orca handle: terminal_app null, as the Mac without an owner app")
    check(LinuxMarking.fields(of: areaMark, id: "aki_1_a", batch: "batch_1", terminal: orcaSession, imagePath: "/h/crop.jpg") == [
        "id": "aki_1_a", "comment": "bigger", "status": "pending", "kind": "area", "batch_id": "batch_1", "number": 2, "source": "linux",
        "rect": ["x": 10, "y": 20, "width": 300, "height": 40, "screen": 1],
        "app": ["name": "firefox", "window": "Docs — Mozilla Firefox"],
        "session_id": "s1", "worktree": "/repo/site", "agent": "claude", "session_name": "SITE", "terminal_app": ["name": "Orca"],
        "image_path": "/h/crop.jpg",
    ], "an area's fields: as the Mac's save, source linux, image always")
    let pointMark = LinuxMarking.PortableMark(screen: 0, rect: .init(x: 5, y: 6, width: 0, height: 0), number: 1, app: .init(name: nil, window: ""))
    let pointFields = LinuxMarking.fields(of: pointMark, id: "aki_1_b", batch: "batch_1", terminal: plainSession, imagePath: "/h/c.jpg")
    check(pointFields["kind"] == "point" && pointFields["app"] == nil && pointFields["comment"] == "", "a click is a point; no app name nor title: no app")

    let markHome = AkiHome(url: temp.appending(path: "mark-home"))
    let markStore = AnnotationStore(directory: markHome.url)
    let savedRound = await LinuxMarking.save([areaMark, pointMark], to: orcaSession, jpeg: { @Sendable in $0.number == 1 ? nil : Data([0xFF, 0xD8, 0xFF]) },
                                             store: markStore, home: markHome, clock: markClock)
    check(savedRound.saved.map(\.id) == ["aki_1791339895500_df9f68ee"] && savedRound.failed == [pointMark.id], "a mark whose JPEG is missing fails and stays; the other is saved")
    let savedMark = await markStore.get("aki_1791339895500_df9f68ee")
    let savedFolder = MarkFolder.url(for: "aki_1791339895500_df9f68ee", created: markClock.now(), home: markHome)
    check(savedMark?["image_path"]?.string == savedFolder.appending(path: "crop.jpg").path
          && (try? Data(contentsOf: savedFolder.appending(path: "crop.jpg"))) == Data([0xFF, 0xD8, 0xFF]), "the JPEG goes to the mark's folder as crop.jpg")
    check(FileManager.default.fileExists(atPath: savedFolder.appending(path: "mark.json").path), "and its record, mark.json, beside it")
    check(savedMark?["batch_id"] == "batch_1791339895500" && savedMark?["session_id"] == "s1", "saved with its batch and session")
    let dayFolder = savedFolder.deletingLastPathComponent()
    check((try? FileManager.default.contentsOfDirectory(atPath: dayFolder.path)) == ["df9f68ee"], "the failed mark leaves no folder behind")

    print("linux marking: crop")
    let monitor = LinuxMarking.PixelSize(width: 1920, height: 1080)
    check(LinuxMarking.cropRect(for: .init(x: 100, y: 200, width: 300, height: 40), screen: monitor) == .init(x: 88, y: 188, width: 324, height: 64),
          "an area's crop: 12 px of room around it")
    check(LinuxMarking.cropRect(for: .init(x: 960, y: 540, width: 0, height: 0), screen: monitor) == .init(x: 740, y: 390, width: 440, height: 300),
          "a point's crop: 440×300 around it")
    check(LinuxMarking.cropRect(for: .init(x: 10, y: 1070, width: 0, height: 0), screen: monitor) == .init(x: 0, y: 920, width: 230, height: 160),
          "held to the screen's edges")
    check(LinuxMarking.cropRect(for: .init(x: 1900.5, y: 3.25, width: 30, height: 10), screen: monitor) == .init(x: 1888, y: 0, width: 32, height: 26),
          "fractions widen to whole pixels (CGRect.integral), then the edge")
    check(LinuxMarking.cropRect(for: .init(x: 3000, y: 3000, width: 0, height: 0), screen: monitor) == nil, "a mark off the screen has no crop")
    check(LinuxMarking.encodedSize(of: .init(width: 2400, height: 600)) == .init(width: 1200, height: 300), "the JPEG's long side is at most 1200 px")
    check(LinuxMarking.encodedSize(of: .init(width: 333, height: 2000)) == .init(width: 199, height: 1200), "a tall crop too, rounded down as on the Mac")
    check(LinuxMarking.encodedSize(of: .init(width: 440, height: 300)) == .init(width: 440, height: 300), "a small crop keeps its size")
    check(LinuxMarking.encodedSize(of: .init(width: 5000, height: 1)) == nil && LinuxMarking.encodedSize(of: .init(width: 0, height: 0)) == nil,
          "a crop that would shrink to nothing has no size")

    print("linux marking: X11 pixels")
    // 3×2 pixels, BGRx little-endian (the usual 24-bit depth), 4 bytes of padding per row.
    let bgrx: [UInt8] = [
        0x03, 0x02, 0x01, 0, 0x06, 0x05, 0x04, 0, 0x09, 0x08, 0x07, 0, 0xEE, 0xEE, 0xEE, 0xEE,
        0x13, 0x12, 0x11, 0, 0x16, 0x15, 0x14, 0, 0x19, 0x18, 0x17, 0, 0xEE, 0xEE, 0xEE, 0xEE,
    ]
    let bgrxLayout = LinuxMarking.XImageLayout(width: 3, height: 2, bytesPerLine: 16, bitsPerPixel: 32, byteOrder: .lsbFirst,
                                               redMask: 0xFF0000, greenMask: 0x00FF00, blueMask: 0x0000FF)
    check(LinuxMarking.rgb(of: bgrx, layout: bgrxLayout, crop: .init(x: 0, y: 0, width: 3, height: 2))
          == [1, 2, 3, 4, 5, 6, 7, 8, 9, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19],
          "BGRx little-endian to packed RGB, the row padding skipped")
    check(LinuxMarking.rgb(of: bgrx, layout: bgrxLayout, crop: .init(x: 1, y: 1, width: 2, height: 1)) == [0x14, 0x15, 0x16, 0x17, 0x18, 0x19],
          "a crop from the middle")
    let xrgbBig: [UInt8] = [0, 0x01, 0x02, 0x03, 0, 0x04, 0x05, 0x06]
    let msbLayout = LinuxMarking.XImageLayout(width: 2, height: 1, bytesPerLine: 8, bitsPerPixel: 32, byteOrder: .msbFirst,
                                              redMask: 0xFF0000, greenMask: 0x00FF00, blueMask: 0x0000FF)
    check(LinuxMarking.rgb(of: xrgbBig, layout: msbLayout, crop: .init(x: 0, y: 0, width: 2, height: 1)) == [1, 2, 3, 4, 5, 6], "MSBFirst (xRGB in memory)")
    let rgb24: [UInt8] = [0x03, 0x02, 0x01, 0x06, 0x05, 0x04, 0xEE, 0xEE]
    let layout24 = LinuxMarking.XImageLayout(width: 2, height: 1, bytesPerLine: 8, bitsPerPixel: 24, byteOrder: .lsbFirst,
                                             redMask: 0xFF0000, greenMask: 0x00FF00, blueMask: 0x0000FF)
    check(LinuxMarking.rgb(of: rgb24, layout: layout24, crop: .init(x: 0, y: 0, width: 2, height: 1)) == [1, 2, 3, 4, 5, 6], "24 bits per pixel")
    var rgbxLayout = bgrxLayout
    (rgbxLayout.redMask, rgbxLayout.blueMask) = (0x0000FF, 0xFF0000)
    check(LinuxMarking.rgb(of: bgrx, layout: rgbxLayout, crop: .init(x: 0, y: 0, width: 1, height: 1)) == [3, 2, 1], "other masks: red where its mask says")
    var bpp16 = bgrxLayout
    bpp16.bitsPerPixel = 16
    var oddMask = bgrxLayout
    oddMask.greenMask = 0x00F0F0
    check(LinuxMarking.rgb(of: bgrx, layout: bpp16, crop: .init(x: 0, y: 0, width: 1, height: 1)) == nil
          && LinuxMarking.rgb(of: bgrx, layout: oddMask, crop: .init(x: 0, y: 0, width: 1, height: 1)) == nil,
          "nil for 16 bits per pixel or a mask that isn't 8 bits in a row")
    check(LinuxMarking.rgb(of: bgrx, layout: bgrxLayout, crop: .init(x: 2, y: 1, width: 2, height: 1)) == nil
          && LinuxMarking.rgb(of: Array(bgrx.prefix(20)), layout: bgrxLayout, crop: .init(x: 0, y: 0, width: 3, height: 2)) == nil
          && LinuxMarking.rgb(of: bgrx, layout: bgrxLayout, crop: .init(x: 0, y: 0, width: 0, height: 1)) == nil,
          "nil for a crop outside the image, a short buffer or an empty crop")

    print("linux marking: delivery text")
    var promptSession = LinuxMarking.terminal(id: "s1", name: "SITE `x`", worktree: "/repo/site")
    promptSession.pendingIDs = ["aki_1_df9f68ee", "aki_2_0a1b2c3d"]
    promptSession.pendingComments = ["(no text)", "make the `button` bigger and blue, with a softer shadow too please"]
    promptSession.pending = 2
    promptSession.undelivered = 2
    promptSession.pendingPlaces = ["firefox", "Orca", "code"]
    check(LinuxMarking.deliveryPrompt(for: promptSession, aki: "aki")
          == "📍 Aki → SITE 'x': 2 marcas novas (de firefox, Orca) — #0a1b2c · #df9f68 “make the 'button' bigger and blue, with a softer s…”."
          + " Leia com `aki show df9f68ee 0a1b2c3d` (abra a foto só se o pedido for visual), resolva e feche com `aki done df9f68ee 0a1b2c3d`."
          + " Se não forem para esta sessão, avise antes de mexer.",
          "the message typed to the agent: the Mac's own words, codes newest first beside their comments")
    var oneMark = LinuxMarking.terminal(id: "s1", name: "api", worktree: "/repo/api")
    oneMark.pendingIDs = ["note_1"]
    oneMark.pendingComments = ["fix\nthis"]
    check(LinuxMarking.deliveryPrompt(for: oneMark, aki: "'/opt/my aki/aki'")
          == "📍 Aki → api: 1 marca nova — #1 “fix this”. Leia com `'/opt/my aki/aki' list` (abra a foto só se o pedido for visual), resolva e feche com `'/opt/my aki/aki' done <códigos>`."
          + " Se não forem para esta sessão, avise antes de mexer.",
          "a mark from elsewhere: the session's list, never a code")
    check(LinuxMarking.akiInvocation(executable: "/home/u/.local/bin/aki", akiOnPath: "/home/u/.local/bin/aki") == "aki",
          "the aki on PATH is this one: plain aki")
    check(LinuxMarking.akiInvocation(executable: "/home/u/it's here/aki", akiOnPath: "/usr/bin/aki") == "'/home/u/it'\\''s here/aki'"
          && LinuxMarking.akiInvocation(executable: "/b/aki", akiOnPath: nil) == "'/b/aki'",
          "another aki on PATH, or none: this one's path, quoted for the shell")
    check(LinuxMarking.executablePath(fromProcLink: "/repo/.build/debug/aki (deleted)") == "/repo/.build/debug/aki"
          && LinuxMarking.executablePath(fromProcLink: "/usr/bin/aki") == "/usr/bin/aki",
          "/proc/self/exe of a binary rebuilt meanwhile: without \" (deleted)\"")

    print("linux marking: Orca")
    check(Command.outcome("/bin/sleep", ["3"], timeout: 0.3) == .timedOut, "a program that doesn't end in time: timed out, not failed")
    check(Command.outcome("/bin/sh", ["-c", "echo hi; exit 3"]) == .exited(status: 3, output: Data("hi\n".utf8)), "its status and output however it ended")
    check(Command.outcome("/nonexistent/orca-ide", []) == .couldNotStart, "a missing program couldn't start")
    check(LinuxMarking.sendArguments(handle: "term_1", prompt: "📍 hi") == ["terminal", "send", "--terminal", "term_1", "--text", "📍 hi", "--enter", "--json"],
          "one send with Enter, no --retry-request")
    let orcaHome = temp.appending(path: "orca-home")
    let orcaBin = orcaHome.appending(path: ".local/bin")
    try FileManager.default.createDirectory(at: orcaBin, withIntermediateDirectories: true)
    let fakeOrcaIDE = orcaBin.appending(path: "orca-ide"), fakeOrca = orcaHome.appending(path: "orca")
    for file in [fakeOrcaIDE, fakeOrca] {
        _ = FileManager.default.createFile(atPath: file.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    }
    check(LinuxMarking.orcaExecutable(path: orcaHome.path, home: temp.appending(path: "nobody")) == nil,
          "never `orca` (outside Orca that's GNOME's screen reader)")
    check(LinuxMarking.orcaExecutable(path: "/nonexistent:" + orcaBin.path, home: temp) == fakeOrcaIDE.path, "orca-ide on PATH")
    check(LinuxMarking.orcaExecutable(path: "/nonexistent", home: orcaHome) == fakeOrcaIDE.path, "else in ~/.local/bin")
    let dryHome = AkiHome(url: temp.appending(path: "dry-home"))
    let dry = LinuxMarking.orcaRunner(environment: ["AKI_DRY_DELIVER": "1", "PATH": orcaBin.path], akiHome: dryHome, home: orcaHome)
    check(dry is LinuxMarking.DryOrcaRunner, "AKI_DRY_DELIVER=1: the runner only writes down what it would run")
    check(LinuxMarking.orcaRunner(environment: ["PATH": orcaBin.path], akiHome: dryHome, home: orcaHome).map { ($0 as? LinuxMarking.ProcessOrcaRunner)?.executable } == fakeOrcaIDE.path,
          "else the real orca-ide")
    check(LinuxMarking.orcaRunner(environment: ["PATH": "/nonexistent"], akiHome: dryHome, home: temp) == nil, "no orca-ide: no runner")
    let drySent = dry?.run(["terminal", "send", "--text", "a \"b\""])
    _ = dry?.run(["terminal", "list", "--json"])
    let dryLines = ((try? String(contentsOf: dryHome.url.appending(path: "dry-deliver.log"), encoding: .utf8)) ?? "").split(separator: "\n")
    check(dryLines.count == 2 && (try? JSONSerialization.jsonObject(with: Data(dryLines[0].utf8)) as? [String]) == ["terminal", "send", "--text", "a \"b\""],
          "each run a JSON array on its own line in $AKI_HOME/dry-deliver.log")
    check(drySent.flatMap { if case .exited(0, let data) = $0 { return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["ok"] as? Bool } else { return nil } } == true,
          "and answers as a send that went")
    try FileManager.default.createDirectory(at: dryHome.url, withIntermediateDirectories: true)
    try Data(#"{"ok":true,"result":{"terminals":[{"handle":"term_9","worktreePath":"/repo"}]}}"#.utf8)
        .write(to: dryHome.url.appending(path: "dry-terminals.json"))
    check(dry?.run(["terminal", "list", "--json", "--limit", "200"]) == .exited(status: 0, output: Data(#"{"ok":true,"result":{"terminals":[{"handle":"term_9","worktreePath":"/repo"}]}}"#.utf8)),
          "its tab list: $AKI_HOME/dry-terminals.json when there is one")
    check(LinuxMarking.ProcessOrcaRunner(executable: "/bin/echo").run(["terminal", "list"]) == .exited(status: 0, output: Data("terminal list\n".utf8)),
          "the real runner runs the program it was given")
    #if os(Linux)
    let akiLink = orcaBin.appending(path: "aki")
    try FileManager.default.createSymbolicLink(at: akiLink, withDestinationURL: fakeOrcaIDE)
    check(LinuxMarking.akiOnPath("/nonexistent:" + orcaBin.path) == fakeOrcaIDE.path && LinuxMarking.akiOnPath("/nonexistent") == nil,
          "the aki on PATH, its link followed; none: nil")
    #endif

    print("linux marking: delivery")
    let siteTab = Command.Outcome.exited(status: 0, output: Data(#"{"ok":true,"result":{"terminals":[{"handle":"term_1","worktreePath":"/repo"}]}}"#.utf8))
    let jpegBytes: @Sendable (LinuxMarking.PortableMark) -> Data? = { _ in Data([0xFF, 0xD8]) }
    func deliveryWorld(_ name: String) -> (AkiHome, AnnotationStore) {
        let home = AkiHome(url: temp.appending(path: "deliver-\(name)"))
        return (home, AnnotationStore(directory: home.url))
    }
    let siteSession = LinuxMarking.terminal(id: "s1", name: "SITE", worktree: "/repo/site", orcaHandle: "term_1")
    let otherSession = LinuxMarking.terminal(id: "s2", name: "API", worktree: "/repo/api", orcaHandle: "term_2")
    let firstMark = LinuxMarking.PortableMark(screen: 0, rect: .init(x: 1, y: 1, width: 50, height: 50), comment: "first", number: 1, app: .init(name: "firefox"))
    let secondMark = LinuxMarking.PortableMark(screen: 0, rect: .init(x: 9, y: 9, width: 0, height: 0), comment: "", number: 2)

    let (sentHome, sentStore) = deliveryWorld("sent")
    _ = try await sentStore.upsert(Annotation(["id": "aki_1_00000001", "session_id": "s1", "worktree": "/repo/site", "comment": "old",
                                               "created_at": "2026-01-01T00:00:00Z", "delivered_at": "2026-01-01T00:00:01Z"]))
    _ = try await sentStore.upsert(Annotation(["id": "aki_1_00000002", "session_id": "s2", "worktree": "/repo/site", "comment": "theirs",
                                               "created_at": "2026-01-01T00:00:00Z"]))
    _ = try await sentStore.upsert(Annotation(["id": "aki_1_00000003", "worktree": "/repo/site", "comment": "by folder",
                                               "created_at": "2026-01-01T00:00:00Z"]))
    let sentOrca = FakeOrca(tabs: siteTab)
    let sentClock = LinuxMarking.Clock(now: { Date(timeIntervalSince1970: 1_791_339_895.5) }, random: RandomParts(["aaaaaaa1", "aaaaaaa2"]).next)
    let sent = await LinuxMarking.deliver([firstMark, secondMark], to: "s1", sessions: [otherSession, siteSession], jpeg: jpegBytes,
                                          store: sentStore, home: sentHome, orca: sentOrca, aki: "aki", clock: sentClock)
    check(sent.outcome == .sent && sent.saved.count == 2 && sent.failed.isEmpty, "saved and typed")
    check(sentOrca.ran.first.map { Array($0.prefix(2)) } == ["terminal", "list"] && sentOrca.sends.count == 1, "the tab checked first, then one send")
    let typed = sentOrca.sends.first ?? []
    check(typed.count == 8 && Array(typed.prefix(5)) == ["terminal", "send", "--terminal", "term_1", "--text"] && Array(typed.suffix(2)) == ["--enter", "--json"],
          "typed into the session's own tab")
    check(typed.count > 5 && typed[5] == "📍 Aki → SITE: 3 marcas novas (de firefox) — #aaaaaa · #aaaaaa “first” · #000000 “by folder”."
          + " Leia com `aki show 00000003 aaaaaaa1 aaaaaaa2` (abra a foto só se o pedido for visual), resolva e feche com `aki done 00000003 aaaaaaa1 aaaaaaa2`."
          + " Se não forem para esta sessão, avise antes de mexer.",
          "naming the session's marks not delivered yet, oldest first (one sent earlier left out, another session's too)")
    check(sent.prompt == typed.last.flatMap { _ in typed.count > 5 ? typed[5] : nil }, "the report keeps the message typed")
    let afterSend = await sentStore.list().annotations
    func deliveredAt(_ id: String) -> String? { afterSend.first { $0.id == id }?["delivered_at"]?.string }
    check(deliveredAt("aki_1791339895500_aaaaaaa1") == "2026-10-07T02:24:55Z" && deliveredAt("aki_1791339895500_aaaaaaa2") == "2026-10-07T02:24:55Z"
          && deliveredAt("aki_1_00000003") == "2026-10-07T02:24:55Z", "each mark sent recorded as delivered (ISO 8601)")
    check(deliveredAt("aki_1_00000002") == nil && deliveredAt("aki_1_00000001") == "2026-01-01T00:00:01Z", "another session's mark untouched, an earlier delivery kept")

    let (heldHome, heldStore) = deliveryWorld("held")
    var askingSession = siteSession
    askingSession.state = .waiting
    let heldOrca = FakeOrca(tabs: siteTab)
    let held = await LinuxMarking.deliver([firstMark], to: "s1", sessions: [askingSession], jpeg: jpegBytes, store: heldStore, home: heldHome,
                                          orca: heldOrca, aki: "aki")
    check(held.outcome == .held("SITE is asking you something: the mark is saved and goes with your next send."), "asking something: held, with why")
    check(heldOrca.ran.isEmpty && held.saved.count == 1 && held.saved.first?["delivered_at"] == nil, "nothing typed, the mark saved and not delivered")

    let (noTabHome, noTabStore) = deliveryWorld("notab")
    let noTabOrca = FakeOrca(tabs: siteTab)
    let noTab = await LinuxMarking.deliver([firstMark, secondMark], to: "codex:42", sessions: [plainSession], jpeg: jpegBytes, store: noTabStore,
                                           home: noTabHome, orca: noTabOrca, aki: "aki")
    check(noTab.outcome == .notTyped("Saved for api, not typed: it isn't in an Orca tab. Its agent finds them with `aki list`.") && noTabOrca.ran.isEmpty
          && noTab.saved.count == 2, "no Orca handle: saved, not typed")
    let noOrca = await LinuxMarking.deliver([firstMark], to: "s1", sessions: [siteSession], jpeg: jpegBytes, store: noTabStore,
                                            home: noTabHome, orca: nil, aki: "aki")
    check(noOrca.outcome == .notTyped("Saved for SITE, not typed: orca-ide wasn't found."), "no orca-ide: saved, not typed")

    let (wrongTabHome, wrongTabStore) = deliveryWorld("wrongtab")
    let wrongTabOrca = FakeOrca(tabs: .exited(status: 0, output: Data(#"{"ok":true,"result":{"terminals":[{"handle":"term_1","worktreePath":"/elsewhere"}]}}"#.utf8)))
    let wrongTab = await LinuxMarking.deliver([firstMark], to: "s1", sessions: [siteSession], jpeg: jpegBytes, store: wrongTabStore,
                                              home: wrongTabHome, orca: wrongTabOrca, aki: "aki")
    check(wrongTab.outcome == .notTyped("Saved for SITE, not typed: Orca has no tab term_1 in its folder.") && wrongTabOrca.sends.isEmpty,
          "a handle Orca lists in another folder: saved, not typed")
    let listTimeout = FakeOrca(tabs: .timedOut)
    let unlisted = await LinuxMarking.deliver([firstMark], to: "s1", sessions: [siteSession], jpeg: jpegBytes, store: wrongTabStore,
                                              home: wrongTabHome, orca: listTimeout, aki: "aki")
    check(unlisted.outcome == .notTyped("Saved for SITE, not typed: Orca didn't list its tabs.") && listTimeout.sends.isEmpty,
          "Orca's list not answering: saved, not typed")

    let (zeroHome, zeroStore) = deliveryWorld("zero")
    let zero = await LinuxMarking.deliver([firstMark], to: nil, sessions: [], jpeg: jpegBytes, store: zeroStore, home: zeroHome, orca: FakeOrca(tabs: siteTab), aki: "aki")
    check(zero.outcome == .notSaved("No agent session to send to: nothing was saved.") && zero.failed == [firstMark.id], "zero sessions: nothing saved, why")
    let gone = await LinuxMarking.deliver([firstMark], to: "s9", sessions: [siteSession], jpeg: jpegBytes, store: zeroStore, home: zeroHome, orca: FakeOrca(tabs: siteTab), aki: "aki")
    check(gone.outcome == .notSaved("That session closed: choose another. Nothing was saved."), "the destination gone: nothing saved")
    let noJPEGOrca = FakeOrca(tabs: siteTab)
    let noJPEG = await LinuxMarking.deliver([firstMark], to: "s1", sessions: [siteSession], jpeg: { @Sendable _ in nil }, store: zeroStore, home: zeroHome, orca: noJPEGOrca, aki: "aki")
    check(noJPEG.outcome == .notSaved("The mark couldn't be saved: nothing was sent.") && noJPEGOrca.ran.isEmpty && noJPEG.failed == [firstMark.id],
          "nothing saved: nothing typed")
    check(await zeroStore.list().annotations.isEmpty, "and the store stays empty")

    let (slowHome, slowStore) = deliveryWorld("slow")
    let slowOrca = FakeOrca(tabs: siteTab, send: .timedOut)
    let slow = await LinuxMarking.deliver([firstMark], to: "s1", sessions: [siteSession], jpeg: jpegBytes, store: slowStore, home: slowHome, orca: slowOrca, aki: "aki")
    check(slow.outcome == .uncertain("Saved for SITE. Orca didn't answer in time: the message may have been typed, so it isn't sent again.")
          && slowOrca.sends.count == 1, "a send with no answer in time: uncertain, never sent again")
    check(await slowStore.list().annotations.allSatisfy { $0["delivered_at"] == nil }, "and not recorded as delivered (the next send names it)")
    let refusedOrca = FakeOrca(tabs: siteTab, send: .exited(status: 0, output: Data(#"{"ok":false,"error":{"message":"no such terminal"}}"#.utf8)))
    let refused = await LinuxMarking.deliver([firstMark], to: "s1", sessions: [siteSession], jpeg: jpegBytes, store: slowStore, home: slowHome, orca: refusedOrca, aki: "aki")
    check(refused.outcome == .typingFailed("Saved for SITE, but Orca didn't type the message.") && refusedOrca.sends.count == 1,
          "ok:false with exit 0 is a failure")
    let crashedOrca = FakeOrca(tabs: siteTab, send: .exited(status: 1, output: Data()))
    let crashed = await LinuxMarking.deliver([firstMark], to: "s1", sessions: [siteSession], jpeg: jpegBytes, store: slowStore, home: slowHome, orca: crashedOrca, aki: "aki")
    check(crashed.outcome == .typingFailed("Saved for SITE, but Orca didn't type the message."), "so is a non-zero exit")
    check(await slowStore.list().annotations.allSatisfy { $0["delivered_at"] == nil }, "none of those recorded as delivered")
    return orcaBin
}
