import Foundation

extension LinuxMarking {
    /// `app.name` from the active window's `WM_CLASS` bytes (`instance\0class\0`): the
    /// class ("Google-chrome"), else the instance when that's all there is.
    public static func windowClass(fromWMClass bytes: [UInt8]) -> String? {
        let parts = bytes.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        return parts.count >= 2 ? parts[1] : parts.first
    }

    /// `app.window` from `_NET_WM_NAME`'s bytes (UTF-8, maybe NUL-ended).
    public static func windowTitle(fromProperty bytes: [UInt8]) -> String? {
        let text = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }
}
