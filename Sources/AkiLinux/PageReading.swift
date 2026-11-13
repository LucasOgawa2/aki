import AkiCore
import Foundation

/// A mark's page, asked of Chrome's DevTools off GTK's thread: one read at a time on its
/// own queue, each with one deadline for everything (1.5 s; the Mac's AppleScript has
/// 1 s), each answer back on GTK's thread. The tab found by the first is kept for the
/// next marks (`CDP.PageReader`). None when `AKI_CDP_URL` is refused.
final class PageReading: @unchecked Sendable {
    private let reader: LinuxMarking.CDP.PageReader
    private let queue = DispatchQueue(label: "app.aki.mark.page")
    /// Set when the overlay is gone: reads still queued are dropped, answers too.
    private var closing = false
    private let lock = NSLock()
    static let timeout: Duration = .milliseconds(1500)

    init?(environment: [String: String]) {
        switch LinuxMarking.CDP.endpoint(from: environment["AKI_CDP_URL"]) {
        case let .success(endpoint):
            reader = LinuxMarking.CDP.PageReader { deadline in try Browser.connect(to: endpoint, until: deadline) }
        case let .failure(refusal):
            FileHandle.standardError.write(Data("aki-mark: \(refusal.reason): marks go without their page\n".utf8))
            return nil
        }
    }

    /// Reads `mark`'s page (the element under a point; for an area, only the address).
    /// `done` runs on GTK's thread; nil fields: nothing, or the read failed.
    func read(_ mark: LinuxMarking.PortableMark, window: Capture.Window, title: String?, monitors: [LinuxMarking.Monitor],
              done: @escaping (LinuxMarking.CDP.PageRead) -> Void) {
        guard monitors.indices.contains(mark.screen) else {
            onGtkThread { done(.init()) }
            return
        }
        let monitor = monitors[mark.screen]
        let root = LinuxMarking.rootRect(of: mark.rect, on: monitor)
        let point = mark.rect.isPoint ? LinuxMarking.Point(x: root.x, y: root.y) : nil
        let width = Double(LinuxMarking.devicePixels(of: monitor).width)
        queue.async {
            guard !self.lock.withLock({ self.closing }) else { return }
            let read = self.reader.read(window: window.geometry, title: title, point: point, monitorWidth: width,
                                        until: ContinuousClock.now + Self.timeout)
            if read.url == nil {
                FileHandle.standardError.write(Data("aki-mark: mark \(mark.number) goes without its page (no answer from the browser, or no single tab in that window)\n".utf8))
            }
            onGtkThread {
                guard !self.lock.withLock({ self.closing }) else { return }
                done(read)
            }
        }
    }

    /// After the overlay closed: drops what's queued, waits for the read going (at most
    /// its deadline) and closes the browser's socket.
    func finish() {
        lock.withLock { closing = true }
        let done = DispatchSemaphore(value: 0)
        queue.async {
            self.reader.close()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
    }
}
