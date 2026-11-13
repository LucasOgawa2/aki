import Foundation

extension LinuxMarking {
    /// The words under an area, read by tesseract: the Linux stand-in for the Mac's
    /// `ScreenText` (Vision). Only the pure parts and the run through `Command`; the
    /// overlay decides when, one at a time and off GTK's thread.
    public enum OCR {
        /// The languages to read with, from `tesseract --list-langs`'s output: Portuguese
        /// and English when installed (never `osd`, which is layout only). None: no OCR.
        public static func languages(fromListLangs output: String) -> [String] {
            // One language per line after the heading; a whole line, so the heading's path never matches.
            let installed = Set(output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
            return ["por", "eng"].filter(installed.contains)
        }
    
        /// `tesseract <image> <base> -l por+eng --dpi 300 tsv`: it writes `<base>.tsv`.
        public static func arguments(image: String, outputBase: String, languages: [String]) -> [String] {
            [image, outputBase, "-l", languages.joined(separator: "+"), "--dpi", "300", "tsv"]
        }

        /// How much a crop is enlarged before reading (UI text of 11-13 px reads badly
        /// at its own size): 3x while that stays within ~2.5 MP, else 2x, else as it is.
        public static func scale(for crop: PixelSize) -> Int {
            [3, 2].first { crop.width * crop.height * $0 * $0 <= maxPixels } ?? 1
        }

        /// The enlarged crop's most pixels.
        static let maxPixels = 2_500_000
    
        /// Packed RGB as a binary PPM (P6), each pixel made a `scale`×`scale` block (nearest
        /// neighbour). Nil when the bytes aren't `size`'s, or there's nothing.
        public static func ppm(rgb: [UInt8], size: PixelSize, scale: Int) -> Data? {
            guard size.width > 0, size.height > 0, scale >= 1, rgb.count == size.width * size.height * 3 else { return nil }
            let width = size.width * scale
            var out = Data("P6\n\(width) \(size.height * scale)\n255\n".utf8)
            var row = [UInt8]()
            row.reserveCapacity(width * 3)
            out.reserveCapacity(out.count + width * size.height * scale * 3)
            for y in 0..<size.height {
                row.removeAll(keepingCapacity: true)
                for x in 0..<size.width {
                    let at = (y * size.width + x) * 3
                    for _ in 0..<scale { row.append(contentsOf: rgb[at..<(at + 3)]) }
                }
                for _ in 0..<scale { out.append(contentsOf: row) }
            }
            return out
        }
    
        /// Where an area's words are read from: its crop (`cropRect`, 12 px of room, held
        /// to the monitor) in the monitor's own pixels and in the capture's, and how much
        /// it's enlarged.
        public struct Region: Equatable, Sendable {
            /// Local to the monitor, the mark's own frame: lines are placed back in it.
            public var local: PixelRect
            /// In the capture (the root window): where its pixels are.
            public var root: PixelRect
            public var scale: Int

            public init(local: PixelRect, root: PixelRect, scale: Int) {
                self.local = local
                self.root = root
                self.scale = scale
            }
        }

        /// None for a point (only an area reads its words, as on the Mac) or a mark off its monitor.
        public static func region(for mark: PortableMark, on monitor: Monitor) -> Region? {
            guard !mark.rect.isPoint, let local = cropRect(for: mark.rect, screen: devicePixels(of: monitor)) else { return nil }
            // As `Overlay.jpeg`: the monitor's origin only to find its pixels.
            let origin = rootRect(of: .init(x: 0, y: 0, width: 0, height: 0), on: monitor)
            return Region(local: local, root: .init(x: local.x + Int(origin.x), y: local.y + Int(origin.y), width: local.width, height: local.height),
                          scale: scale(for: .init(width: local.width, height: local.height)))
        }
    
        /// The text of tesseract's TSV that lies under `rect` (the mark's, local to its
        /// monitor), as the Mac's `ScreenText.text(in:)`: the lines whose middle falls
        /// inside it, top to bottom then left to right, joined with newlines; cut at 4000.
        /// Nil when none.
        public static func text(fromTSV tsv: String, region: Region, in rect: Rect) -> String? {
            struct Line {
                var words: [String] = []
                var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
            }
            struct Key: Hashable { var block: Int, par: Int, line: Int }
            var lines: [Key: Line] = [:]
            var order: [Key] = []
            let scale = Double(region.scale)
            for row in tsv.split(whereSeparator: \.isNewline) {
                // Levels 1-4 end in an empty text: empty fields count.
                let column = row.split(separator: "\t", omittingEmptySubsequences: false)
                // Words only; the header and a last line cut short don't parse.
                guard column.count >= 12, column[0] == "5",
                      let block = Int(column[2]), let par = Int(column[3]), let number = Int(column[4]),
                      let left = Double(column[6]), let top = Double(column[7]), let width = Double(column[8]), let height = Double(column[9]),
                      let conf = Double(column[10]), conf >= 0
                else { continue }
                let word = column[11...].joined(separator: "\t").trimmingCharacters(in: .whitespaces)
                guard !word.isEmpty else { continue }
                let key = Key(block: block, par: par, line: number)
                if lines[key] == nil { order.append(key) }
                var line = lines[key, default: Line()]
                line.words.append(word)
                // Back in the monitor's pixels: undo the enlargement, then the crop's place.
                line.minX = min(line.minX, Double(region.local.x) + left / scale)
                line.minY = min(line.minY, Double(region.local.y) + top / scale)
                line.maxX = max(line.maxX, Double(region.local.x) + (left + width) / scale)
                line.maxY = max(line.maxY, Double(region.local.y) + (top + height) / scale)
                lines[key] = line
            }
            let inside = order.compactMap { lines[$0] }.filter { line in
                // As CGRect.contains: the right and bottom edges are outside.
                let x = (line.minX + line.maxX) / 2, y = (line.minY + line.maxY) / 2
                return x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height
            }
            .sorted { abs($0.minY - $1.minY) > 4 ? $0.minY < $1.minY : $0.minX < $1.minX }
            let text = inside.map { $0.words.joined(separator: " ") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : String(text.prefix(textLimit))
        }
    
        /// Why a read gave nothing; only for the log (the mark goes without its text).
        public enum Failure: Error, Equatable, CustomStringConvertible {
            case noLanguages, badImage, couldNotWrite, failed, noOutput
            public var description: String {
                switch self {
                case .noLanguages: "tesseract has neither Portuguese nor English installed"
                case .badImage: "the crop's pixels don't match its size"
                case .couldNotWrite: "couldn't write the crop for tesseract"
                case .failed: "tesseract failed or didn't end in time"
                case .noOutput: "tesseract wrote no TSV"
                }
            }
        }

        /// Where the crops go while read: the session's runtime folder (private to the
        /// user), else the temporary one.
        public static func temporaryDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
            var isFolder: ObjCBool = false
            if let runtime = environment["XDG_RUNTIME_DIR"], !runtime.isEmpty,
               FileManager.default.fileExists(atPath: runtime, isDirectory: &isFolder), isFolder.boolValue {
                return URL(filePath: runtime, directoryHint: .isDirectory)
            }
            return FileManager.default.temporaryDirectory
        }

        /// Reads `rgb` (the region's crop, packed RGB) with tesseract and gives the text
        /// under `rect` (nil when there's none). Blocks until it ends or `timeout`; the
        /// crop and its TSV never outlive the call.
        public static func read(rgb: [UInt8], region: Region, in rect: Rect, tesseract: String, languages: [String],
                                directory: URL, timeout: TimeInterval = 4) -> Result<String?, Failure> {
            guard !languages.isEmpty else { return .failure(.noLanguages) }
            guard let image = ppm(rgb: rgb, size: .init(width: region.local.width, height: region.local.height), scale: region.scale)
            else { return .failure(.badImage) }
            let base = directory.appending(path: "\(prefix)\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)").path
            let imagePath = base + ".ppm", tsvPath = base + ".tsv"
            defer {
                try? FileManager.default.removeItem(atPath: imagePath)
                try? FileManager.default.removeItem(atPath: tsvPath)
            }
            // Both made private before anything is in them: tesseract truncates the TSV, keeping its mode.
            guard writePrivate(image, to: imagePath), writePrivate(Data(), to: tsvPath) else { return .failure(.couldNotWrite) }
            guard Command.succeeds(tesseract, arguments(image: imagePath, outputBase: base, languages: languages), timeout: timeout)
            else { return .failure(.failed) }
            guard let data = FileManager.default.contents(atPath: tsvPath) else { return .failure(.noOutput) }
            return .success(text(fromTSV: String(decoding: data, as: UTF8.self), region: region, in: rect))
        }

        /// Crops left behind by a run that ended mid-read, older than `cutoff`.
        public static func removeStale(in directory: URL, before cutoff: Date) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where name.hasPrefix(prefix) {
                let path = directory.appending(path: name).path
                guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                      modified < cutoff else { continue }
                try? FileManager.default.removeItem(atPath: path)
            }
        }

        static let prefix = "aki-ocr-"

        /// A new file only its owner reads (0600, never one already there), with `data`.
        private static func writePrivate(_ data: Data, to path: String) -> Bool {
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { return false }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            return (try? handle.write(contentsOf: data)) != nil
        }
    }
}
