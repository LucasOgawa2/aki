import AkiCore
import Foundation

/// The words under an area, read by tesseract off GTK's thread: one read at a time on
/// its own queue (tesseract uses OpenMP; two at once is more memory and no faster), each
/// answer back on GTK's thread. None without tesseract: the marks go without text.
final class TextReader: @unchecked Sendable {
    private let tesseract: String
    private let directory: URL
    private let queue = DispatchQueue(label: "app.aki.mark.ocr")
    /// Asked once (on the queue): Portuguese and English, when installed.
    private var languages: [String]?
    /// Set when the overlay is gone: reads still queued are dropped.
    private var closing = false
    private let lock = NSLock()
    /// tesseract's own limit; the send waits less (3 s) and goes with what it has.
    static let timeout: TimeInterval = 4

    init?(environment: [String: String]) {
        guard let tesseract = LinuxMarking.executable(named: "tesseract", path: environment["PATH"], also: ["/usr/bin"]) else { return nil }
        self.tesseract = tesseract
        directory = LinuxMarking.OCR.temporaryDirectory(environment: environment)
    }

    /// Crops a run that ended mid-read left behind, and the languages asked for before the first mark.
    func prepare() {
        queue.async {
            LinuxMarking.OCR.removeStale(in: self.directory, before: Date().addingTimeInterval(-60))
            _ = self.installedLanguages()
        }
    }

    /// Reads `mark`'s area in `capture`; `done` runs on GTK's thread, with nil when
    /// there's nothing (no words, or the read failed: said on stderr).
    func read(_ mark: LinuxMarking.PortableMark, capture: Capture, monitors: [LinuxMarking.Monitor], done: @escaping (String?) -> Void) {
        queue.async {
            guard !self.lock.withLock({ self.closing }) else { return }
            let result = self.text(of: mark, capture: capture, monitors: monitors)
            if case let .failure(why) = result {
                FileHandle.standardError.write(Data("aki-mark: mark \(mark.number) goes without its text: \(why)\n".utf8))
            }
            let text = (try? result.get()) ?? nil
            onGtkThread { done(text) }
        }
    }

    /// After the overlay closed: drops what's queued and waits for the read going (at
    /// most its timeout, which stops tesseract), so its crop and TSV are removed and no
    /// tesseract outlives `aki-mark`.
    func finish() {
        lock.withLock { closing = true }
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        _ = done.wait(timeout: .now() + Self.timeout + 2)
    }

    private func text(of mark: LinuxMarking.PortableMark, capture: Capture, monitors: [LinuxMarking.Monitor])
        -> Result<String?, LinuxMarking.OCR.Failure> {
        guard monitors.indices.contains(mark.screen),
              let region = LinuxMarking.OCR.region(for: mark, on: monitors[mark.screen]) else { return .success(nil) }
        guard let rgb = LinuxMarking.rgb(of: capture.bytes, layout: capture.layout, crop: region.root) else { return .failure(.badImage) }
        return LinuxMarking.OCR.read(rgb: rgb, region: region, in: mark.rect, tesseract: tesseract, languages: installedLanguages(),
                                     directory: directory, timeout: Self.timeout)
    }

    /// On the queue only.
    private func installedLanguages() -> [String] {
        if let languages { return languages }
        let output = Command.output(tesseract, ["--list-langs"], timeout: Self.timeout).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let found = LinuxMarking.OCR.languages(fromListLangs: output)
        if found.isEmpty {
            FileHandle.standardError.write(Data("aki-mark: tesseract has neither por nor eng installed (tesseract-ocr-por, tesseract-ocr-eng): marks go without text\n".utf8))
        }
        languages = found
        return found
    }
}
