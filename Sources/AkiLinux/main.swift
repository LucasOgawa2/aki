import AkiCore
import CGtk
import CX11
import Foundation

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
    } catch { print("aki-mark: \(error)"); exit(1) }
    exit(0)
}
print("aki-mark: gtk \(gtk_get_major_version()).\(gtk_get_minor_version())")
