import AkiCore
import CGtk
import Foundation

// `aki mark` on Linux (GTK 4 on X11): `aki` execs this, so `aki` itself never needs GTK.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("aki-mark: \(message)\n".utf8))
    exit(1)
}

let environment = ProcessInfo.processInfo.environment
let dry = environment["AKI_DRY_DELIVER"] == "1"

if CommandLine.arguments.dropFirst().first == "--probe-capture" {
    // Not for people: the capture's size, the active window, and each half's mean brightness.
    do {
        let c = try Capture.take()
        print("capture \(c.layout.width)x\(c.layout.height) bpp \(c.layout.bitsPerPixel) app \(c.app.map { "\($0.name ?? "-") / \($0.window ?? "-")" } ?? "none")")
        for (name, x) in [("left", 0), ("right", c.layout.width / 2)] {
            let crop = LinuxMarking.PixelRect(x: x, y: 0, width: c.layout.width / 2, height: c.layout.height)
            let rgb = LinuxMarking.rgb(of: c.bytes, layout: c.layout, crop: crop) ?? []
            let mean = rgb.isEmpty ? 0 : Double(rgb.reduce(0) { $0 + Int($1) }) / Double(rgb.count)
            print("\(name) half mean \(String(format: "%.1f", mean))")
        }
    } catch { fail("\(error)") }
    exit(0)
}
guard CommandLine.arguments.count == 1 else { fail("usage: aki mark (no arguments)") }

if environment["XDG_SESSION_TYPE"] == "wayland" {
    fail("this is a Wayland session; aki mark needs X11 for now (pick \"GNOME on Xorg\" at the login screen)")
}
guard let display = environment["DISPLAY"], !display.isEmpty else { fail("no DISPLAY: aki mark needs an X11 desktop") }
// The capture and the windows are X11's: GTK on the same server.
g_setenv("GDK_BACKEND", "x11", 1)
guard gtk_init_check() != 0 else { fail("GTK couldn't open the display \(display)") }

// One overlay at a time: pressing the shortcut again only brings it forward.
let app = UnsafeMutableRawPointer(gtk_application_new(dry ? "app.aki.mark.dry" : "app.aki.mark", G_APPLICATION_DEFAULT_FLAGS))!
var registerError: UnsafeMutablePointer<GError>?
guard g_application_register(typed(app), nil, &registerError) != 0 else {
    let why = registerError.map { String(cString: $0.pointee.message) } ?? "unknown"
    fail("couldn't start (\(why))")
}
// Only argv[0]: anything after it would be taken as files to open.
let argc: Int32 = 1
if g_application_get_is_remote(typed(app)) != 0 {
    // Another aki mark is open: activate it (before any capture, which would photograph it).
    exit(g_application_run(typed(app), argc, CommandLine.unsafeArgv))
}

let capture: Capture
do { capture = try Capture.take() } catch { fail("\(error)") }

let gdkDisplay = gdk_display_get_default()
let list = gdk_display_get_monitors(gdkDisplay)
var monitors: [(LinuxMarking.Monitor, UnsafeMutableRawPointer)] = []
for i in 0..<g_list_model_get_n_items(list) {
    guard let item = g_list_model_get_item(list, i) else { continue }
    var geometry = GdkRectangle()
    gdk_monitor_get_geometry(OpaquePointer(item), &geometry)
    let monitor = LinuxMarking.Monitor(x: Int(geometry.x), y: Int(geometry.y), width: Int(geometry.width), height: Int(geometry.height),
                                       scale: Int(gdk_monitor_get_scale_factor(OpaquePointer(item))))
    monitors.append((monitor, item))
    if dry {
        let name = gdk_monitor_get_connector(OpaquePointer(item)).map { String(cString: $0) } ?? "?"
        FileHandle.standardError.write(Data("aki-mark: screen \(i) = \(name) \(monitor.width)x\(monitor.height)+\(monitor.x)+\(monitor.y) scale \(monitor.scale)\n".utf8))
    }
}
guard !monitors.isEmpty else { fail("GTK sees no monitor") }

// The real listing before any window: the destination starts on the one used last.
let overlay = Overlay(app: app, capture: capture, monitors: monitors, sessions: LinuxMarking.sessions { AgentSessions.terminals() })
onSignal(app, "activate") { overlay.activate() }
exit(g_application_run(typed(app), argc, CommandLine.unsafeArgv))
