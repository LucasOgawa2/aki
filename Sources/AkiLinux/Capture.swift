import AkiCore
import CX11
import Foundation

/// The screen as it was when `aki mark` ran, before any window of ours: the whole root
/// window in one `XGetImage`, and the window that was active (for each mark's `app`).
struct Capture {
    var bytes: [UInt8]
    var layout: LinuxMarking.XImageLayout
    var app: LinuxMarking.AppInfo?
    /// Where the pointer was, in root pixels (its monitor's overlay takes the keyboard).
    var pointer: LinuxMarking.Point?

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
        let app = activeApp(display, root: root)
        var rootReturn: Window = 0, child: Window = 0, rootX: Int32 = 0, rootY: Int32 = 0, winX: Int32 = 0, winY: Int32 = 0, mask: UInt32 = 0
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
        return Capture(bytes: bytes, layout: layout, app: app, pointer: pointer)
    }

    /// `_NET_ACTIVE_WINDOW`'s `WM_CLASS` and `_NET_WM_NAME` (nil when there's none).
    private static func activeApp(_ display: OpaquePointer, root: Window) -> LinuxMarking.AppInfo? {
        let active = XInternAtom(display, "_NET_ACTIVE_WINDOW", 0)
        guard let ids = property(display, root, active, type: Atom(XA_WINDOW)), ids.count >= MemoryLayout<UInt>.size else { return nil }
        // Format 32 comes as C longs.
        let window = ids.withUnsafeBytes { Window($0.load(as: UInt.self)) }
        guard window != 0 else { return nil }
        let name = property(display, window, Atom(XA_WM_CLASS), type: Atom(AnyPropertyType)).flatMap(LinuxMarking.windowClass(fromWMClass:))
        let title = property(display, window, XInternAtom(display, "_NET_WM_NAME", 0), type: XInternAtom(display, "UTF8_STRING", 0))
            .flatMap(LinuxMarking.windowTitle(fromProperty:))
        guard name != nil || title != nil else { return nil }
        return LinuxMarking.AppInfo(name: name, window: title)
    }

    /// A window property's bytes (at most 64 KiB), nil when it's missing or of another type.
    private static func property(_ display: OpaquePointer, _ window: Window, _ atom: Atom, type: Atom) -> [UInt8]? {
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
