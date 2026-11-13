import Foundation

extension LinuxMarking {
    /// A monitor as GDK gives it: its place in the root window in logical pixels, and
    /// its scale (the capture, an XImage of the root, is in device pixels).
    public struct Monitor: Equatable, Sendable {
        public var x: Int, y: Int, width: Int, height: Int, scale: Int

        public init(x: Int, y: Int, width: Int, height: Int, scale: Int = 1) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.scale = max(1, scale)
        }
    }

    /// The monitor (its place in GDK's list, which is a mark's `screen`) holding this
    /// root point, in logical pixels; each one's right and bottom edges are its neighbour's.
    public static func monitor(containing point: Point, in monitors: [Monitor]) -> Int? {
        monitors.firstIndex { m in
            point.x >= Double(m.x) && point.x < Double(m.x + m.width) && point.y >= Double(m.y) && point.y < Double(m.y + m.height)
        }
    }

    /// A point in a monitor's overlay window (logical, top-left origin) in that monitor's
    /// device pixels, held inside it: a drag that runs off its monitor stops at the edge.
    public static func devicePoint(_ point: Point, on monitor: Monitor) -> Point {
        let size = devicePixels(of: monitor), s = Double(monitor.scale)
        return Point(x: min(max(0, point.x * s), Double(size.width - 1)), y: min(max(0, point.y * s), Double(size.height - 1)))
    }

    /// A monitor's size in the capture's pixels.
    public static func devicePixels(of monitor: Monitor) -> PixelSize {
        PixelSize(width: monitor.width * monitor.scale, height: monitor.height * monitor.scale)
    }

    /// A mark's rect (device pixels, local to its monitor) in the root window's device
    /// pixels: where its crop is in the capture.
    public static func rootRect(of rect: Rect, on monitor: Monitor) -> Rect {
        Rect(x: rect.x + Double(monitor.x * monitor.scale), y: rect.y + Double(monitor.y * monitor.scale), width: rect.width, height: rect.height)
    }
}
