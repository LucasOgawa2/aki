import Foundation

extension LinuxMarking {
    public struct PixelRect: Equatable, Sendable {
        public var x: Int, y: Int, width: Int, height: Int
        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public struct PixelSize: Equatable, Sendable {
        public var width: Int, height: Int
        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    /// Ported from the Mac's `MarkingSession.cropRect` and `ScreenGrab.crop`: an area with
    /// 12 px of room around it, a point with 440×300 of its surroundings, widened to whole
    /// pixels and held to the screen (X11 pixels, scale 1). Nil off the screen.
    public static func cropRect(for rect: Rect, screen: PixelSize) -> PixelRect? {
        let wanted = rect.isPoint
            ? (x: rect.x + rect.width / 2 - 220, y: rect.y + rect.height / 2 - 150, width: 440.0, height: 300.0)
            : (x: rect.x - 12, y: rect.y - 12, width: rect.width + 24, height: rect.height + 24)
        let minX = max(0, Int(wanted.x.rounded(.down))), minY = max(0, Int(wanted.y.rounded(.down)))
        let maxX = min(screen.width, Int((wanted.x + wanted.width).rounded(.up)))
        let maxY = min(screen.height, Int((wanted.y + wanted.height).rounded(.up)))
        guard maxX > minX, maxY > minY else { return nil }
        return PixelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The JPEG's size, as the Mac's `jpegData` makes it: at most 1200 px on the long
    /// side (only the sum: the overlay encodes). Nil when it would shrink to nothing.
    public static func encodedSize(of crop: PixelSize) -> PixelSize? {
        let longest = Double(max(crop.width, crop.height))
        guard longest > 0 else { return nil }
        let factor = min(1, 1200 / longest)
        let width = Int(Double(crop.width) * factor), height = Int(Double(crop.height) * factor)
        guard width > 0, height > 0 else { return nil }
        return PixelSize(width: width, height: height)
    }
}
