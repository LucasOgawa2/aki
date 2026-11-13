import AkiCore
import CGtk
import Foundation

/// The marking overlay: one fullscreen window per monitor showing its slice of the
/// frozen capture, with the marks, the card of the one being written, the queue, the
/// destination and the warnings. Every decision is `OverlayState`'s; this only turns
/// GTK's events into its events and draws what it holds.
final class Overlay {
    private var state: LinuxMarking.OverlayState
    private let capture: Capture
    private let monitors: [LinuxMarking.Monitor]
    private let gdkMonitors: [UnsafeMutableRawPointer]
    private let app: UnsafeMutableRawPointer
    private let reader: TextReader?
    private let pages: PageReading?
    private var screens: [Screen] = []
    private var built = false
    private var closed = false
    /// Setting the entry's text from the state fires `changed`: not echoed back.
    private var syncing = false
    private var drag: (screen: Int, from: LinuxMarking.Point, to: LinuxMarking.Point)?
    /// The mark whose card last took the keyboard: focusing again would select what's typed.
    private var focused: UUID?

    private final class Screen {
        let index: Int
        let window: UnsafeMutableRawPointer
        let area: UnsafeMutableRawPointer
        let card: UnsafeMutableRawPointer
        let cardTitle: UnsafeMutableRawPointer
        let entry: UnsafeMutableRawPointer
        let cardText: UnsafeMutableRawPointer
        let status: UnsafeMutableRawPointer
        let warning: UnsafeMutableRawPointer

        init(index: Int, window: UnsafeMutableRawPointer, area: UnsafeMutableRawPointer, card: UnsafeMutableRawPointer,
             cardTitle: UnsafeMutableRawPointer, entry: UnsafeMutableRawPointer, cardText: UnsafeMutableRawPointer,
             status: UnsafeMutableRawPointer, warning: UnsafeMutableRawPointer) {
            self.index = index
            self.window = window
            self.area = area
            self.card = card
            self.cardTitle = cardTitle
            self.entry = entry
            self.cardText = cardText
            self.status = status
            self.warning = warning
        }
    }

    init(app: UnsafeMutableRawPointer, capture: Capture, monitors: [(LinuxMarking.Monitor, UnsafeMutableRawPointer)],
         sessions: [AgentTerminal], reader: TextReader?, pages: PageReading?) {
        self.app = app
        self.reader = reader
        self.pages = pages
        self.capture = capture
        self.monitors = monitors.map(\.0)
        gdkMonitors = monitors.map(\.1)
        state = LinuxMarking.OverlayState(sessions: sessions, readsText: reader != nil, readsPage: pages != nil && capture.window != nil)
    }

    /// GtkApplication's `activate`: the first builds the windows, later ones (the
    /// shortcut pressed again) only bring them forward.
    func activate() {
        guard !closed else { return }
        if !built {
            built = true
            loadStyle()
            screens = monitors.indices.map(makeScreen)
            refresh()
        }
        // The pointer's monitor last, so it has the keyboard.
        let first = capture.pointer.flatMap { LinuxMarking.monitor(containing: $0, in: monitors) } ?? 0
        for screen in screens where screen.index != first { gtk_window_present(typed(screen.window)) }
        if first < screens.count { gtk_window_present(typed(screens[first].window)) }
    }

    // MARK: Events

    private func dispatch(_ event: LinuxMarking.OverlayState.Event) {
        guard !closed else { return }
        let effect = state.handle(event)
        switch effect {
        case .close?: close()
        case let .send(marks, destination)?: send(marks, to: destination)
        case let .enrich(mark, sources)?:
            // From the end of the drag: usually read before Ctrl+Enter.
            if sources.contains(.text) {
                reader?.read(mark, capture: capture, monitors: monitors) { [weak self] text in
                    self?.dispatch(.enriched(id: mark.id, source: .text, .init(text: text)))
                }
            }
            if sources.contains(.page) {
                if let pages, let window = capture.window {
                    pages.read(mark, window: window, title: capture.app?.window, monitors: monitors) { [weak self] read in
                        self?.dispatch(.enriched(id: mark.id, source: .page, .init(url: read.url, element: read.element)))
                    }
                } else {
                    dispatch(.enriched(id: mark.id, source: .page, .init()))
                }
            }
        case let .wait(token)?:
            // As the Mac: a send waits for the reads up to 3 s, then goes with what it has.
            onGtkThread(after: 3000) { [weak self] in self?.dispatch(.deadline(token)) }
        case nil: break
        }
        if !closed { refresh() }
    }

    private func key(_ keyval: UInt32, _ modifiers: GdkModifierType) -> Bool {
        let ctrl = modifiers.rawValue & GDK_CONTROL_MASK.rawValue != 0
        let shift = modifiers.rawValue & GDK_SHIFT_MASK.rawValue != 0
        switch Int32(keyval) {
        case GDK_KEY_Escape: dispatch(.escape)
        case GDK_KEY_Return, GDK_KEY_KP_Enter, GDK_KEY_ISO_Enter: dispatch(ctrl ? .send : .commit)
        case GDK_KEY_ISO_Left_Tab: dispatch(.previousDestination)
        case GDK_KEY_Tab, GDK_KEY_KP_Tab: dispatch(shift ? .previousDestination : .nextDestination)
        case GDK_KEY_1...GDK_KEY_9 where ctrl: dispatch(.destination(Int(Int32(keyval) - GDK_KEY_0)))
        case GDK_KEY_KP_1...GDK_KEY_KP_9 where ctrl: dispatch(.destination(Int(Int32(keyval) - GDK_KEY_KP_0)))
        case GDK_KEY_z where ctrl && !shift, GDK_KEY_Z where ctrl && !shift:
            // The state's undo with no card open or on the one just made, still empty;
            // else it's the entry's own Ctrl+Z.
            guard state.editing == nil || (state.justMade && state.draft.isEmpty) else { return false }
            dispatch(.undo)
        default: return false
        }
        return true
    }

    private func pressed(on screen: Int, x: Double, y: Double) {
        guard !state.sending else { return }
        let at = LinuxMarking.devicePoint(.init(x: x, y: y), on: monitors[screen])
        drag = (screen, at, at)
        gtk_widget_queue_draw(typed(screens[screen].area))
    }

    private func moved(on screen: Int, dx: Double, dy: Double, ended: Bool) {
        guard let start = drag, start.screen == screen else { return }
        let scale = Double(monitors[screen].scale)
        let to = LinuxMarking.devicePoint(.init(x: start.from.x / scale + dx, y: start.from.y / scale + dy), on: monitors[screen])
        if ended {
            drag = nil
            let rect = LinuxMarking.OverlayState.rect(from: start.from, to: to)
            let onBrowser = LinuxMarking.isOnBrowser(rect, on: monitors[screen], window: capture.window?.geometry.rect, appName: capture.app?.name)
            dispatch(.pointer(screen: screen, from: start.from, to: to, app: capture.app, onBrowser: onBrowser))
        } else {
            drag = (screen, start.from, to)
            gtk_widget_queue_draw(typed(screens[screen].area))
        }
    }

    // MARK: Send

    private func send(_ marks: [LinuxMarking.PortableMark], to destination: String) {
        let capture = self.capture, monitors = self.monitors
        let home = AkiHome.default
        Task.detached {
            // A listing taken now: whether the session is asking something is read here.
            let sessions = LinuxMarking.sessions(home: home) { AgentSessions.terminals() }
            let report = await LinuxMarking.deliver(
                marks, to: destination, sessions: sessions, jpeg: { Overlay.jpeg(of: $0, capture: capture, monitors: monitors) },
                store: AnnotationStore(directory: home.url), home: home, orca: LinuxMarking.orcaRunner(), aki: Overlay.akiInvocation())
            onGtkThread { [weak self] in
                self?.dispatch(.sessionsChanged(sessions))
                self?.dispatch(.sendFinished(failed: report.failed, warning: report.outcome.warning))
            }
        }
    }

    /// How the message names `aki`: the one beside this `aki-mark`.
    static func akiInvocation() -> String {
        guard let me = LinuxMarking.currentExecutable() else { return "aki" }
        let aki = LinuxMarking.sibling("aki", of: me)
        return LinuxMarking.akiInvocation(executable: URL(filePath: aki).resolvingSymlinksInPath().path, akiOnPath: LinuxMarking.akiOnPath())
    }

    /// A mark's crop as JPEG 70, the long side at most 1200 px. Runs off the GTK thread
    /// (only its own pixbufs).
    static func jpeg(of mark: LinuxMarking.PortableMark, capture: Capture, monitors: [LinuxMarking.Monitor]) -> Data? {
        guard monitors.indices.contains(mark.screen) else { return nil }
        let monitor = monitors[mark.screen]
        guard let local = LinuxMarking.cropRect(for: mark.rect, screen: LinuxMarking.devicePixels(of: monitor)) else { return nil }
        let origin = LinuxMarking.rootRect(of: .init(x: 0, y: 0, width: 0, height: 0), on: monitor)
        let crop = LinuxMarking.PixelRect(x: local.x + Int(origin.x), y: local.y + Int(origin.y), width: local.width, height: local.height)
        guard let rgb = LinuxMarking.rgb(of: capture.bytes, layout: capture.layout, crop: crop),
              let size = LinuxMarking.encodedSize(of: .init(width: crop.width, height: crop.height))
        else { return nil }
        let bytes = rgb.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
        defer { g_bytes_unref(bytes) }
        guard let full = gdk_pixbuf_new_from_bytes(bytes, GDK_COLORSPACE_RGB, 0, 8, Int32(crop.width), Int32(crop.height), Int32(crop.width * 3))
        else { return nil }
        defer { g_object_unref(UnsafeMutableRawPointer(full)) }
        var pixbuf = full
        if size.width != crop.width || size.height != crop.height {
            guard let scaled = gdk_pixbuf_scale_simple(full, Int32(size.width), Int32(size.height), GDK_INTERP_BILINEAR) else { return nil }
            pixbuf = scaled
        }
        defer { if pixbuf != full { g_object_unref(UnsafeMutableRawPointer(pixbuf)) } }
        var buffer: UnsafeMutablePointer<gchar>?
        var length: gsize = 0
        var error: UnsafeMutablePointer<GError>?
        guard aki_pixbuf_jpeg(pixbuf, &buffer, &length, &error) != 0, let buffer else {
            if let error { g_error_free(error) }
            return nil
        }
        defer { g_free(buffer) }
        return Data(bytes: buffer, count: Int(length))
    }

    private func close() {
        guard !closed else { return }
        closed = true
        for screen in screens { gtk_window_destroy(typed(screen.window)) }
        g_application_quit(typed(app))
    }

    // MARK: Windows

    private func makeScreen(_ index: Int) -> Screen {
        let monitor = monitors[index]
        let window = UnsafeMutableRawPointer(gtk_application_window_new(typed(app)))!
        gtk_window_set_title(typed(window), "Aki")
        gtk_window_set_decorated(typed(window), 0)

        let overlay = UnsafeMutableRawPointer(gtk_overlay_new())!
        gtk_window_set_child(typed(window), typed(overlay))

        // The frozen screen: its slice of the capture, in device pixels.
        let slice = LinuxMarking.devicePixels(of: monitor)
        let origin = LinuxMarking.rootRect(of: .init(x: 0, y: 0, width: 0, height: 0), on: monitor)
        if let rgb = LinuxMarking.rgb(of: capture.bytes, layout: capture.layout,
                                      crop: .init(x: Int(origin.x), y: Int(origin.y), width: slice.width, height: slice.height)) {
            let bytes = rgb.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
            let texture = gdk_memory_texture_new(Int32(slice.width), Int32(slice.height), GDK_MEMORY_R8G8B8, bytes, gsize(slice.width * 3))
            g_bytes_unref(bytes)
            let picture = UnsafeMutableRawPointer(gtk_picture_new_for_paintable(texture))!
            g_object_unref(UnsafeMutableRawPointer(texture!))
            gtk_picture_set_content_fit(typed(picture), GTK_CONTENT_FIT_FILL)
            gtk_picture_set_can_shrink(typed(picture), 1)
            gtk_overlay_set_child(typed(overlay), typed(picture))
        }

        let area = UnsafeMutableRawPointer(gtk_drawing_area_new())!
        gtk_widget_set_hexpand(typed(area), 1)
        gtk_widget_set_vexpand(typed(area), 1)
        gtk_overlay_add_overlay(typed(overlay), typed(area))
        setDraw(area) { [unowned self] cairo, _, _ in self.draw(screen: index, cairo) }

        let gesture = UnsafeMutableRawPointer(gtk_gesture_drag_new())!
        onDrag(gesture, "drag-begin") { [unowned self] x, y in self.pressed(on: index, x: x, y: y) }
        onDrag(gesture, "drag-update") { [unowned self] dx, dy in self.moved(on: index, dx: dx, dy: dy, ended: false) }
        onDrag(gesture, "drag-end") { [unowned self] dx, dy in self.moved(on: index, dx: dx, dy: dy, ended: true) }
        gtk_widget_add_controller(typed(area), OpaquePointer(gesture))

        // The card: the mark's number and its note.
        let card = UnsafeMutableRawPointer(gtk_box_new(GTK_ORIENTATION_VERTICAL, 4))!
        gtk_widget_add_css_class(typed(card), "aki-card")
        gtk_widget_set_halign(typed(card), GTK_ALIGN_START)
        gtk_widget_set_valign(typed(card), GTK_ALIGN_START)
        let cardTitle = UnsafeMutableRawPointer(gtk_label_new(nil))!
        gtk_widget_set_halign(typed(cardTitle), GTK_ALIGN_START)
        gtk_widget_add_css_class(typed(cardTitle), "aki-card-title")
        gtk_box_append(typed(card), typed(cardTitle))
        let entry = UnsafeMutableRawPointer(gtk_entry_new())!
        gtk_entry_set_placeholder_text(typed(entry), "What should the agent do here?")
        gtk_widget_set_size_request(typed(entry), 360, -1)
        gtk_box_append(typed(card), typed(entry))
        // The start of the words read under it (or that they're being read).
        let cardText = UnsafeMutableRawPointer(gtk_label_new(nil))!
        gtk_widget_set_halign(typed(cardText), GTK_ALIGN_START)
        gtk_label_set_ellipsize(typed(cardText), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(typed(cardText), 48)
        gtk_widget_add_css_class(typed(cardText), "aki-card-text")
        gtk_widget_set_visible(typed(cardText), 0)
        gtk_box_append(typed(card), typed(cardText))
        onSignal(entry, "changed") { [unowned self] in
            guard !self.syncing, let text = gtk_editable_get_text(OpaquePointer(entry)) else { return }
            self.dispatch(.draft(String(cString: text)))
        }
        gtk_widget_set_visible(typed(card), 0)
        gtk_overlay_add_overlay(typed(overlay), typed(card))

        // The queue, the destination and the keys; above them, the warnings.
        let bottom = UnsafeMutableRawPointer(gtk_box_new(GTK_ORIENTATION_VERTICAL, 6))!
        gtk_widget_set_halign(typed(bottom), GTK_ALIGN_CENTER)
        gtk_widget_set_valign(typed(bottom), GTK_ALIGN_END)
        gtk_widget_set_margin_bottom(typed(bottom), 48)
        gtk_widget_set_can_target(typed(bottom), 0)
        let warning = UnsafeMutableRawPointer(gtk_label_new(nil))!
        gtk_widget_add_css_class(typed(warning), "aki-warning")
        gtk_label_set_wrap(typed(warning), 1)
        gtk_label_set_max_width_chars(typed(warning), 90)
        gtk_box_append(typed(bottom), typed(warning))
        let status = UnsafeMutableRawPointer(gtk_label_new(nil))!
        gtk_widget_add_css_class(typed(status), "aki-status")
        gtk_box_append(typed(bottom), typed(status))
        gtk_overlay_add_overlay(typed(overlay), typed(bottom))

        let keys = UnsafeMutableRawPointer(gtk_event_controller_key_new())!
        // Capture phase: before the entry, and before GTK takes Tab for focus.
        gtk_event_controller_set_propagation_phase(OpaquePointer(keys), GTK_PHASE_CAPTURE)
        onKey(keys) { [unowned self] keyval, modifiers in self.key(keyval, modifiers) }
        gtk_widget_add_controller(typed(window), OpaquePointer(keys))

        // Alt+F4 and the like: an Esc (never while the marks go).
        onSignalHandled(window, "close-request") { [unowned self] in
            if !self.state.sending { self.dispatch(.escape) }
            return true
        }
        gtk_window_fullscreen_on_monitor(typed(window), OpaquePointer(gdkMonitors[index]))
        return Screen(index: index, window: window, area: area, card: card, cardTitle: cardTitle, entry: entry, cardText: cardText, status: status, warning: warning)
    }

    private func loadStyle() {
        let css = """
        .aki-card { background: rgba(28,28,30,0.96); color: white; border-radius: 10px; padding: 8px; border: 1px solid #ff9f0a; }
        .aki-card-title { font-weight: bold; color: #ff9f0a; }
        .aki-card-text { color: rgba(255,255,255,0.7); font-size: smaller; }
        .aki-status { background: rgba(28,28,30,0.9); color: white; border-radius: 10px; padding: 6px 14px; }
        .aki-warning { background: #c62828; color: white; border-radius: 10px; padding: 6px 14px; font-weight: bold; }
        """
        let provider = gtk_css_provider_new()
        gtk_css_provider_load_from_string(provider, css)
        gtk_style_context_add_provider_for_display(gdk_display_get_default(), OpaquePointer(provider), UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
    }

    /// Shows what the state holds now.
    private func refresh() {
        let editingMark = state.marks.first { $0.id == state.editing }
        let destination = state.sessions.firstIndex { $0.id == state.destination }
        let count = state.marks.count
        var parts = [count == 0 ? "Click a point or drag an area" : (count == 1 ? "1 mark" : "\(count) marks")]
        if state.waitingForReads {
            parts.append(state.marks.contains { state.pendingSources($0.id).contains(.page) } ? "Reading the page…" : "Reading text…")
        } else if state.sending {
            parts.append("Sending…")
        } else if state.sessions.isEmpty {
            parts.append("No agent session open")
        } else if let destination {
            let name = state.sessions[destination].name
            parts.append("→ \(destination + 1)/\(state.sessions.count) \(name)  (Tab, Ctrl+1…9)")
        } else if let gone = state.destination {
            parts.append("→ \(gone) (closed)  (Tab)")
        }
        parts.append("Enter queues · Ctrl+Enter sends · Esc")
        let status = parts.joined(separator: "   ·   ")

        if editingMark == nil { focused = nil }
        syncing = true
        defer { syncing = false }
        for screen in screens {
            gtk_label_set_text(typed(screen.status), status)
            gtk_label_set_text(typed(screen.warning), state.warning ?? "")
            gtk_widget_set_visible(typed(screen.warning), state.warning == nil ? 0 : 1)
            if let mark = editingMark, mark.screen == screen.index {
                let monitor = monitors[screen.index], scale = Double(monitor.scale)
                let rect = mark.rect
                // Under the mark, kept inside the monitor.
                let x = min(max(8, rect.x / scale), Double(monitor.width) - 380)
                let below = (rect.y + rect.height) / scale + 10
                let y = below + 90 > Double(monitor.height) ? max(8, rect.y / scale - 90) : below
                gtk_widget_set_margin_start(typed(screen.card), Int32(x))
                gtk_widget_set_margin_top(typed(screen.card), Int32(y))
                gtk_label_set_text(typed(screen.cardTitle), "Mark \(mark.number)")
                let current = gtk_editable_get_text(OpaquePointer(screen.entry)).map { String(cString: $0) } ?? ""
                if current != state.draft { gtk_editable_set_text(OpaquePointer(screen.entry), state.draft) }
                gtk_widget_set_sensitive(typed(screen.entry), state.sending ? 0 : 1)
                let reading = state.pendingSources(mark.id)
                let read = reading.contains(.text) ? "Reading text…" : reading.contains(.page) ? "Reading the page…"
                    : mark.selectedText.map { "Text: " + ($0.split(whereSeparator: \.isNewline).first.map(String.init) ?? "") }
                    ?? mark.element.map { "Element: " + $0.path }
                gtk_label_set_text(typed(screen.cardText), read ?? "")
                gtk_widget_set_visible(typed(screen.cardText), read == nil ? 0 : 1)
                gtk_widget_set_visible(typed(screen.card), 1)
                if focused != mark.id {
                    focused = mark.id
                    gtk_window_present(typed(screen.window))
                    gtk_entry_grab_focus_without_selecting(typed(screen.entry))
                }
            } else {
                gtk_widget_set_visible(typed(screen.card), 0)
                if !(gtk_editable_get_text(OpaquePointer(screen.entry)).map { String(cString: $0).isEmpty } ?? true) {
                    gtk_editable_set_text(OpaquePointer(screen.entry), "")
                }
            }
            gtk_widget_queue_draw(typed(screen.area))
        }
    }

    private func draw(screen index: Int, _ cr: OpaquePointer) {
        let monitor = monitors[index], scale = Double(monitor.scale)
        // A light tint over the frozen screen: it's Aki's, not the live one.
        cairo_set_source_rgba(cr, 0, 0, 0, 0.12)
        cairo_paint(cr)
        cairo_set_source_rgba(cr, 1, 0.62, 0.04, 1)
        cairo_set_line_width(cr, 4)
        cairo_rectangle(cr, 2, 2, Double(monitor.width) - 4, Double(monitor.height) - 4)
        cairo_stroke(cr)

        cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_BOLD)
        cairo_set_font_size(cr, 13)
        for mark in state.marks where mark.screen == index {
            let r = mark.rect
            let x = r.x / scale, y = r.y / scale, w = r.width / scale, h = r.height / scale
            let editing = mark.id == state.editing
            cairo_set_source_rgba(cr, 1, 0.62, 0.04, editing ? 1 : 0.85)
            if r.isPoint {
                cairo_arc(cr, x, y, 7, 0, 2 * .pi)
                cairo_fill(cr)
            } else {
                cairo_set_line_width(cr, editing ? 3 : 2)
                cairo_rectangle(cr, x, y, w, h)
                cairo_stroke(cr)
                cairo_set_source_rgba(cr, 1, 0.62, 0.04, 0.12)
                cairo_rectangle(cr, x, y, w, h)
                cairo_fill(cr)
            }
            // Its number, in a badge at its corner.
            let bx = r.isPoint ? x + 8 : x - 10, by = r.isPoint ? y - 22 : y - 10
            cairo_set_source_rgba(cr, 1, 0.62, 0.04, 1)
            cairo_arc(cr, bx + 10, by + 10, 11, 0, 2 * .pi)
            cairo_fill(cr)
            cairo_set_source_rgba(cr, 0, 0, 0, 1)
            let label = "\(mark.number)"
            cairo_move_to(cr, bx + (label.count > 1 ? 2 : 6), by + 15)
            cairo_show_text(cr, label)
        }
        if let drag, drag.screen == index {
            cairo_set_source_rgba(cr, 1, 0.62, 0.04, 0.9)
            cairo_set_line_width(cr, 2)
            let x = min(drag.from.x, drag.to.x) / scale, y = min(drag.from.y, drag.to.y) / scale
            cairo_rectangle(cr, x, y, abs(drag.to.x - drag.from.x) / scale, abs(drag.to.y - drag.from.y) / scale)
            cairo_stroke(cr)
        }
    }
}
