import Foundation

extension LinuxMarking {
    /// How an X11 `XImage` in ZPixmap format lays out its bytes.
    public struct XImageLayout: Equatable, Sendable {
        public enum ByteOrder: Sendable { case lsbFirst, msbFirst }
        public var width: Int, height: Int, bytesPerLine: Int, bitsPerPixel: Int
        public var byteOrder: ByteOrder
        public var redMask: UInt32, greenMask: UInt32, blueMask: UInt32

        public init(width: Int, height: Int, bytesPerLine: Int, bitsPerPixel: Int, byteOrder: ByteOrder,
                    redMask: UInt32, greenMask: UInt32, blueMask: UInt32) {
            self.width = width
            self.height = height
            self.bytesPerLine = bytesPerLine
            self.bitsPerPixel = bitsPerPixel
            self.byteOrder = byteOrder
            self.redMask = redMask
            self.greenMask = greenMask
            self.blueMask = blueMask
        }
    }

    /// The pixels of `crop` as packed RGB (3 bytes each, no padding), from an XImage's
    /// bytes. Nil for depths other than 24/32 bits per pixel, masks that aren't 8 bits in
    /// a row, a crop outside the image or a buffer shorter than its layout says.
    public static func rgb(of bytes: [UInt8], layout: XImageLayout, crop: PixelRect) -> [UInt8]? {
        guard layout.bitsPerPixel == 24 || layout.bitsPerPixel == 32 else { return nil }
        let size = layout.bitsPerPixel / 8
        func shift(_ mask: UInt32) -> Int? {
            let low = mask.trailingZeroBitCount
            return mask != 0 && mask >> low == 0xFF && low + 8 <= layout.bitsPerPixel ? low : nil
        }
        guard let red = shift(layout.redMask), let green = shift(layout.greenMask), let blue = shift(layout.blueMask),
              Set([red, green, blue]).count == 3,
              crop.width > 0, crop.height > 0, crop.x >= 0, crop.y >= 0,
              crop.x + crop.width <= layout.width, crop.y + crop.height <= layout.height,
              layout.bytesPerLine >= layout.width * size,
              bytes.count >= (crop.y + crop.height - 1) * layout.bytesPerLine + (crop.x + crop.width) * size
        else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(crop.width * crop.height * 3)
        for row in crop.y..<(crop.y + crop.height) {
            var at = row * layout.bytesPerLine + crop.x * size
            for _ in 0..<crop.width {
                var pixel: UInt32 = 0
                for i in 0..<size {
                    let byte = UInt32(bytes[at + i])
                    pixel |= layout.byteOrder == .lsbFirst ? byte << (8 * i) : byte << (8 * (size - 1 - i))
                }
                out.append(UInt8(truncatingIfNeeded: pixel >> red))
                out.append(UInt8(truncatingIfNeeded: pixel >> green))
                out.append(UInt8(truncatingIfNeeded: pixel >> blue))
                at += size
            }
        }
        return out
    }
}
