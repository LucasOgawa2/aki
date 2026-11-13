import AkiCore
import CX11
import Foundation

/// The screen as it was when `aki mark` ran, before any window of ours: the whole root
/// window in one `XGetImage`, and the window that was active (for each mark's `app`).
struct Capture {
    var bytes: [UInt8]
    var layout: LinuxMarking.XImageLayout
    var app: LinuxMarking.AppInfo?
    /// The active window: its XID and where it is on the root (absolute), for the browser's page.
    var window: Window?
    /// Where the pointer was, in root pixels (its monitor's overlay takes the keyboard).
    var pointer: LinuxMarking.Point?

    struct Window {
        var xid: UInt
        var geometry: LinuxMarking.CDP.Window
    }

    enum Failure: Error, CustomStringConvertible {
        case noDisplay, noImage, unsupported(String)
        var description: String {
            switch self {
            case .noDisplay: "can't open the X display (is DISPLAY right?)"
            case .noImage: "X11 didn't give the screen's pixels (XGetImage failed)"
            case .unsupported(let why): "this screen's pixel format isn't supported: \(why)"
            }
        }
    }

    /// The root's pixels and the active window. Xlib errors (a window gone between two
    /// calls) are ignored: Xlib's default handler would end the process.
    static func take() throws -> Capture {
        _ = XSetErrorHandler { _, _ in 0 }
        guard let display = XOpenDisplay(nil) else { throw Failure.noDisplay }
        defer { XCloseDisplay(display) }
        let screen = XDefaultScreen(display)
        let root = XDefaultRootWindow(display)
        let width = UInt32(XDisplayWidth(display, screen)), height = UInt32(XDisplayHeight(display, screen))
        let (app, window) = activeApp(display, root: root)
        var rootReturn: CX11.Window = 0, child: CX11.Window = 0, rootX: Int32 = 0, rootY: Int32 = 0, winX: Int32 = 0, winY: Int32 = 0, mask: UInt32 = 0
        let pointer = XQueryPointer(display, root, &rootReturn, &child, &rootX, &rootY, &winX, &winY, &mask) != 0
            ? LinuxMarking.Point(x: Double(rootX), y: Double(rootY)) : nil
        // AllPlanes, ZPixmap (macros that don't import).
        guard let image = XGetImage(display, root, 0, 0, width, height, ~0, ZPixmap) else { throw Failure.noImage }
        defer { _ = image.pointee.f.destroy_image(image) }
        let x = image.pointee
        guard let data = x.data else { throw Failure.noImage }
        let layout = LinuxMarking.XImageLayout(
            width: Int(x.width), height: Int(x.height), bytesPerLine: Int(x.bytes_per_line), bitsPerPixel: Int(x.bits_per_pixel),
            byteOrder: x.byte_order == LSBFirst ? .lsbFirst : .msbFirst,
            redMask: UInt32(truncatingIfNeeded: x.red_mask), greenMask: UInt32(truncatingIfNeeded: x.green_mask),
            blueMask: UInt32(truncatingIfNeeded: x.blue_mask))
        guard layout.bitsPerPixel == 24 || layout.bitsPerPixel == 32 else {
            throw Failure.unsupported("\(layout.bitsPerPixel) bits per pixel")
        }
        let count = Int(x.bytes_per_line) * Int(x.height)
        let bytes = data.withMemoryRebound(to: UInt8.self, capacity: count) { Array(UnsafeBufferPointer(start: $0, count: count)) }
        return Capture(bytes: bytes, layout: layout, app: app, window: window, pointer: pointer)
    }

    /// `_NET_ACTIVE_WINDOW`'s `WM_CLASS` and `_NET_WM_NAME` (nil when there's none), and
    /// where it is: `XGetGeometry` is relative to the window manager's frame (Mutter
    /// reparents), so its origin is translated to the root's.
    private static func activeApp(_ display: OpaquePointer, root: CX11.Window) -> (LinuxMarking.AppInfo?, Window?) {
        let active = XInternAtom(display, "_NET_ACTIVE_WINDOW", 0)
        guard let ids = property(display, root, active, type: Atom(XA_WINDOW)), ids.count >= MemoryLayout<UInt>.size else { return (nil, nil) }
        // Format 32 comes as C longs.
        let window = ids.withUnsafeBytes { CX11.Window($0.load(as: UInt.self)) }
        guard window != 0 else { return (nil, nil) }
        let place = geometry(display, window, root: root)
        let name = property(display, window, Atom(XA_WM_CLASS), type: Atom(AnyPropertyType)).flatMap(LinuxMarking.windowClass(fromWMClass:))
        let title = property(display, window, XInternAtom(display, "_NET_WM_NAME", 0), type: XInternAtom(display, "UTF8_STRING", 0))
            .flatMap(LinuxMarking.windowTitle(fromProperty:))
        guard name != nil || title != nil else { return (nil, place) }
        return (LinuxMarking.AppInfo(name: name, window: title), place)
    }

    private static func geometry(_ display: OpaquePointer, _ window: CX11.Window, root: CX11.Window) -> Window? {
        var rootReturn: CX11.Window = 0, child: CX11.Window = 0
        var x: Int32 = 0, y: Int32 = 0, width: UInt32 = 0, height: UInt32 = 0, border: UInt32 = 0, depth: UInt32 = 0
        guard XGetGeometry(display, window, &rootReturn, &x, &y, &width, &height, &border, &depth) != 0, width > 0, height > 0 else { return nil }
        var rootX: Int32 = 0, rootY: Int32 = 0
        guard XTranslateCoordinates(display, window, root, 0, 0, &rootX, &rootY, &child) != 0 else { return nil }
        // GTK's invisible shadow border, when the window draws its own frame: left, right, top, bottom.
        let extents = property(display, window, XInternAtom(display, "_GTK_FRAME_EXTENTS", 0), type: Atom(XA_CARDINAL))
            .flatMap { bytes -> [Double]? in
                guard bytes.count >= 4 * MemoryLayout<UInt>.size else { return nil }
                return bytes.withUnsafeBytes { raw in (0..<4).map { Double(raw.load(fromByteOffset: $0 * MemoryLayout<UInt>.size, as: UInt.self)) } }
            }
        return Window(xid: UInt(window), geometry: .init(rect: .init(x: Double(rootX), y: Double(rootY), width: Double(width), height: Double(height)), extents: extents))
    }

    /// A window property's bytes (at most 64 KiB), nil when it's missing or of another type.
    private static func property(_ display: OpaquePointer, _ window: CX11.Window, _ atom: Atom, type: Atom) -> [UInt8]? {
        var actualType: Atom = 0, format: Int32 = 0, items: UInt = 0, after: UInt = 0
        var data: UnsafeMutablePointer<UInt8>?
        guard XGetWindowProperty(display, window, atom, 0, 16384, 0, type, &actualType, &format, &items, &after, &data) == Success,
              let data else { return nil }
        defer { XFree(data) }
        guard actualType != 0, items > 0 else { return nil }
        // Format 32 items are C longs in memory.
        let size = format == 32 ? MemoryLayout<UInt>.size : Int(format) / 8
        return Array(UnsafeBufferPointer(start: data, count: Int(items) * size))
    }
}
