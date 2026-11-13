import Foundation

/// What a Linux mark records, ported from the Mac's `MarkingSession.save`
/// (Sources/Aki/Marking/MarkingSession.swift): the same fields and the same folder
/// (`marks/<day>/<code>/` with `mark.json` and `crop.jpg`). Differences from the Mac:
/// - `source` is "linux", and `app` has no `bundle_id` (X11 windows have none);
/// - the crop always goes (the Mac sends it only when `sendsImage` is on: there's no
///   such toggle here);
/// - `selected_text` is the words tesseract read under an area (the Mac's Vision), cut
///   at 4000 characters as there;
/// - `url`, `element_context`, `selector` and `source_file_path` come from Chrome's
///   DevTools (`AKI_CDP_URL`) instead of AppleScript; `kind` stays "point" for a click on
///   an element (the Mac turns it into the element's frame: there's no hover outline here);
/// - one destination for the whole round (the Mac keeps one per mark).
extension LinuxMarking {
    /// `aki_<ms>_<8 chars>`, as the Mac makes them.
    public static func markID(at date: Date, random: String) -> String {
        "aki_\(Int(date.timeIntervalSince1970 * 1000))_\(random)"
    }

    public static func batchID(at date: Date) -> String {
        "batch_\(Int(date.timeIntervalSince1970 * 1000))"
    }

    /// The session a mark goes to, and who it is (the Mac's `identityFields`): the
    /// terminal is Orca when the session runs in one of its tabs, else unknown (null).
    public static func sessionFields(of terminal: AgentTerminal) -> [String: JSONValue] {
        [
            "session_id": .string(terminal.id), "worktree": .string(terminal.worktree),
            "agent": .string(terminal.agent.rawValue), "session_name": .string(terminal.name),
            "terminal_app": terminal.orcaHandle == nil ? .null : ["name": "Orca"],
        ]
    }

    /// The most of a mark's text that goes, as the Mac's `text(of:)`.
    public static let textLimit = 4000

    public static func fields(
        of mark: PortableMark, id: String, batch: String, terminal: AgentTerminal, imagePath: String
    ) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "id": .string(id), "comment": .string(mark.comment), "status": "pending",
            "kind": .string(mark.rect.isPoint ? "point" : "area"), "batch_id": .string(batch),
            "number": .number(Double(mark.number)), "source": "linux",
            "rect": [
                "x": .number(mark.rect.x), "y": .number(mark.rect.y),
                "width": .number(mark.rect.width), "height": .number(mark.rect.height),
                "screen": .number(Double(mark.screen)),
            ],
            "image_path": .string(imagePath),
        ]
        var app: [String: JSONValue] = [:]
        if let name = mark.app?.name { app["name"] = .string(name) }
        if let window = mark.app?.window, !window.isEmpty { app["window"] = .string(window) }
        if !app.isEmpty { fields["app"] = .object(app) }
        if let text = mark.selectedText, !text.isEmpty { fields["selected_text"] = .string(String(text.prefix(textLimit))) }
        if let url = mark.url { fields["url"] = .string(url) }
        if let element = mark.element {
            // Same shape as Vibe Annotations' element_context, so agents read it alike (the Mac's).
            var info: [String: JSONValue] = ["path": .string(element.path), "tag": .string(element.tag)]
            if let text = element.text { info["text"] = .string(text) }
            if let id = element.id { info["id"] = .string(id) }
            if !element.classes.isEmpty { info["classes"] = .array(element.classes.map { .string($0) }) }
            if let source = element.source {
                info["source"] = .string(source)
                fields["source_file_path"] = .string(source)
            }
            if let html = element.html { info["html"] = .string(html) }
            fields["element_context"] = .object(info)
            fields["selector"] = .string(element.selector ?? element.path)
        }
        fields.merge(sessionFields(of: terminal)) { _, new in new }
        return fields
    }

    public struct SaveResult: Sendable {
        /// As the store has them.
        public var saved: [Annotation] = []
        /// Couldn't be saved (no JPEG, disk full, no permission): they stay in the queue.
        public var failed: [UUID] = []
    }

    /// Saves each mark with its crop for `terminal`. `jpeg` gives a mark's crop, already
    /// encoded; none (or one that can't be written) and the mark isn't saved, its
    /// folder removed, as on the Mac.
    public static func save(
        _ marks: [PortableMark], to terminal: AgentTerminal, jpeg: (PortableMark) -> Data?,
        store: AnnotationStore, home: AkiHome, clock: Clock = .system
    ) async -> SaveResult {
        let batch = batchID(at: clock.now())
        var result = SaveResult()
        for mark in marks {
            let now = clock.now()
            let id = markID(at: now, random: clock.random())
            guard let folder = MarkFolder.make(for: id, created: now, home: home) else {
                result.failed.append(mark.id)
                continue
            }
            let file = folder.appending(path: "crop.jpg")
            guard let data = jpeg(mark), (try? data.write(to: file, options: .atomic)) != nil else {
                try? FileManager.default.removeItem(at: folder)
                result.failed.append(mark.id)
                continue
            }
            let fields = fields(of: mark, id: id, batch: batch, terminal: terminal, imagePath: file.path)
            guard let saved = try? await store.upsert(Annotation(fields)) else {
                try? FileManager.default.removeItem(at: folder)
                result.failed.append(mark.id)
                continue
            }
            MarkFolder.writeRecord(of: saved, in: folder)
            result.saved.append(saved)
        }
        return result
    }
}
