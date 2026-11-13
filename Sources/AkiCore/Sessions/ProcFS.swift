import Foundation

/// A process's details from Linux's `/proc` (what macOS answers through `sysctl` and
/// libproc). `root` is a folder laid out like `/proc`: the real one, or one the checks make.
public struct ProcFS: Sendable {
    public var root: URL
    /// The unit of the start times in `stat` (100 on every usual kernel).
    public var ticksPerSecond: Double

    public init(root: URL = URL(filePath: "/proc"), ticksPerSecond: Double = Double(sysconf(Int32(_SC_CLK_TCK)))) {
        self.root = root
        self.ticksPerSecond = ticksPerSecond
    }

    /// The process that started it.
    public func parent(of pid: Int32) -> Int32? {
        stat(of: pid).flatMap { $0.count > 1 ? Int32($0[1]) : nil }
    }

    /// The folder it works in (the `cwd` link; only the user's own processes can be read).
    public func cwd(of pid: Int32) -> String? {
        let path = try? FileManager.default.destinationOfSymbolicLink(atPath: root.appending(path: "\(pid)/cwd").path)
        guard let path, !path.isEmpty else { return nil }
        let suffix = " (deleted)"
        guard path.hasSuffix(suffix) else { return path }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return path
        }
        return String(path.dropLast(suffix.count))
    }

    /// The environment it started with (`environ`: one NUL-ended "NAME=value" each).
    public func environment(of pid: Int32) -> [String: String]? {
        guard let data = try? Data(contentsOf: root.appending(path: "\(pid)/environ")) else { return nil }
        var result: [String: String] = [:]
        for entry in data.split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "=") else { continue }
            let key = String(text[..<equals])
            if result[key] == nil { result[key] = String(text[text.index(after: equals)...]) }
        }
        return result
    }

    /// When it started: the system's boot time plus its start, counted in clock ticks.
    public func started(_ pid: Int32) -> Date? {
        guard let fields = stat(of: pid), fields.count > 19, let ticks = Double(fields[19]),
              let boot = bootTime(), ticksPerSecond > 0
        else { return nil }
        return Date(timeIntervalSince1970: boot + ticks / ticksPerSecond)
    }

    /// Descriptor targets readable by this user. Processes may exit during the scan.
    public func openFiles(of pid: Int32) -> [String] {
        let folder = root.appending(path: "\(pid)/fd")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return entries.compactMap { try? FileManager.default.destinationOfSymbolicLink(atPath: folder.appending(path: $0).path) }
    }

    /// lsof-compatible records, so the existing host/family preference stays shared.
    public func listeningSockets() -> String {
        var sockets: [String: (family: String, address: String, port: UInt16)] = [:]
        for (file, family) in [("tcp", "IPv4"), ("tcp6", "IPv6")] {
            for line in (read("net/" + file) ?? "").split(separator: "\n") {
                let fields = line.split(whereSeparator: { $0.isWhitespace })
                guard fields.count > 9, fields[3] == "0A" else { continue }
                let local = fields[1].split(separator: ":")
                guard local.count == 2, let port = UInt16(local[1], radix: 16) else { continue }
                let hex = String(local[0])
                let address: String
                // This hex decoding assumes a little-endian host; the kernel writes in native byte order.
                if family == "IPv4", hex.count == 8, let value = UInt32(hex, radix: 16) {
                    address = value == 0 ? "*" : (0..<4).map { String((value >> ($0 * 8)) & 255) }.joined(separator: ".")
                } else if family == "IPv6", hex.count == 32 {
                    // /proc prints each native-endian 32-bit word. Preserve family even
                    // for :: wildcard; tcp6 does not report the IPV6_V6ONLY option.
                    if hex == String(repeating: "0", count: 32) { address = "[::]" }
                    else if hex == "00000000000000000000000001000000" { address = "[::1]" }
                    else { address = "[" + hex + "]" }
                } else { continue }
                sockets[String(fields[9])] = (family, address, port)
            }
        }
        guard !sockets.isEmpty, let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return "" }
        var records: [String] = []
        for entry in entries.sorted() {
            guard let pid = Int32(entry) else { continue }
            for target in openFiles(of: pid) {
                guard target.hasPrefix("socket:["), target.hasSuffix("]"),
                      let socket = sockets[String(target.dropFirst(8).dropLast())] else { continue }
                records.append("p\(pid)\nt\(socket.family)\nn\(socket.address):\(socket.port)\n")
            }
        }
        return records.joined()
    }

    public struct CPUSample: Sendable {
        public let startTicks: UInt64
        public let ticks: UInt64
        public let at: Double
    }

    /// CPU counters and identity from one stat read; timestamps are monotonic seconds.
    public func cpuSample(of pid: Int32, at: Double) -> CPUSample? {
        guard let fields = stat(of: pid), fields.count > 19,
              let user = UInt64(fields[11]), let system = UInt64(fields[12]),
              let start = UInt64(fields[19]), user <= UInt64.max - system else { return nil }
        return CPUSample(startTicks: start, ticks: user + system, at: at)
    }

    /// Recent CPU, rather than ps's lifetime average. Missing/reused processes have no delta.
    public func cpuPercent(from previous: CPUSample, to current: CPUSample) -> Double? {
        guard current.startTicks == previous.startTicks, current.ticks >= previous.ticks,
              current.at > previous.at, ticksPerSecond > 0 else { return nil }
        return Double(current.ticks - previous.ticks) / ticksPerSecond / (current.at - previous.at) * 100
    }

    private func bootTime() -> Double? {
        guard let text = read("stat") else { return nil }
        return text.split(separator: "\n").first { $0.hasPrefix("btime ") }.flatMap { Double($0.dropFirst(6)) }
    }

    /// The fields of `<pid>/stat` after the name, from its state on. The name sits in
    /// parentheses and may hold spaces or parentheses itself: it ends at the last ")".
    private func stat(of pid: Int32) -> [Substring]? {
        guard let text = read("\(pid)/stat"),
              let close = text.lastIndex(of: ")")
        else { return nil }
        return text[text.index(after: close)...].split(separator: " ", omittingEmptySubsequences: true)
    }

    /// A file under the root. As Data: `/proc` files claim a size of 0, and a String
    /// read of `/proc/stat` comes back empty-handed.
    private func read(_ path: String) -> String? {
        (try? Data(contentsOf: root.appending(path: path))).map { String(decoding: $0, as: UTF8.self) }
    }
}
