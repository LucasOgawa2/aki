import AkiCore
import Foundation
#if os(Linux)
import Glibc
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor func serverChecks() async throws {
    // MARK: Real server

    print("server")
    let token = String(repeating: "k", count: 64)
    let netAPI = AkiAPI(store: AnnotationStore(directory: temp.appending(path: "net")), token: token)
    let server = HTTPServer(port: 0, maxBody: 1024) { await netAPI.handle($0) }
    let port = try await server.start()
    check(port > 0, "starts on a free port (\(port))")

    func call(_ method: String, _ path: String, body: String? = nil, token: String? = nil) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, data)
    }

    check(try await call("GET", "/health").0 == 200, "health over the network")
    check(try await call("GET", "/api/annotations").0 == 401, "token required over the network")
    check(
        try await call("POST", "/api/annotations", body: #"{"id":"n1","url":"u","comment":"ção ✓"}"#, token: token).0 == 200,
        "POST over the network")
    let (_, listed) = try await call("GET", "/api/annotations?status=all", token: token)
    check(String(data: listed, encoding: .utf8)?.contains("ção ✓") == true, "UTF-8 survives the round trip")
    check(
        try await call("POST", "/api/annotations", body: String(repeating: "x", count: 2048), token: token).0 == 413,
        "oversized body → 413")

    let lsof = Process()
    lsof.executableURL = URL(filePath: Command.lsof)
    lsof.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
    let pipe = Pipe()
    lsof.standardOutput = pipe
    try lsof.run()
    lsof.waitUntilExit()
    let listening = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    check(listening.contains("127.0.0.1:\(port)") && !listening.contains("*:\(port)"), "listens on 127.0.0.1 only")
    #if os(Linux)
    // Real sockets exercise connection scheduling and time limits without URLSession pooling.
    func connectClient(to port: UInt16) -> Int32 {
        let client = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard client >= 0 else { return -1 }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        guard setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            close(client)
            return -1
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { close(client); return -1 }
        return client
    }

    func sendRequest(_ request: String, on client: Int32) -> Bool {
        let bytes = Array(request.utf8)
        return bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Glibc.send(client, raw.baseAddress! + offset, raw.count - offset, Int32(MSG_NOSIGNAL))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    do {
        let idleServer = HTTPServer(port: 0) { await netAPI.handle($0) }
        let idlePort = try await idleServer.start()
        var clients: [Int32] = []
        defer {
            for client in clients { close(client) }
            idleServer.stop()
        }
        var sent = true
        for _ in 0..<40 {
            let client = connectClient(to: idlePort)
            if client >= 0 { clients.append(client) }
            sent = sendRequest("GET /health HTTP/1.1\r\nHost: localhost\r\n", on: client) && sent
        }
        let health = connectClient(to: idlePort)
        if health >= 0 { clients.append(health) }
        let started = ProcessInfo.processInfo.systemUptime
        sent = sendRequest("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n", on: health) && sent
        var reply = [UInt8](repeating: 0, count: 4096)
        let count = recv(health, &reply, reply.count, 0)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        check(sent && clients.count == 41 && count > 0 && String(decoding: reply.prefix(max(0, count)), as: UTF8.self).hasPrefix("HTTP/1.1 200 ") && elapsed < 2,
              "health responds within two seconds with 40 idle connections (\(elapsed) s)")
    }

    do {
        let slowServer = HTTPServer(port: 0, requestTimeout: 1) { _ in HTTPResponse(status: 200) }
        let slowPort = try await slowServer.start()
        let client = connectClient(to: slowPort)
        defer {
            if client >= 0 { close(client) }
            slowServer.stop()
        }
        let started = ProcessInfo.processInfo.systemUptime
        var received = -1
        var byte: UInt8 = 0
        for character in "GET /health HTTP/1.1".prefix(12) {
            _ = sendRequest(String(character), on: client)
            usleep(300_000)
            received = recv(client, &byte, 1, Int32(MSG_DONTWAIT))
            if received == 0 { break }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        check(client >= 0 && received == 0 && elapsed >= 0.8 && elapsed < 3,
              "trickling header reaches EOF at the total request deadline (\(elapsed) s)")
    }

    do {
        let cappedServer = HTTPServer(port: 0) { _ in HTTPResponse(status: 200) }
        let cappedPort = try await cappedServer.start()
        var clients: [Int32] = []
        defer {
            for client in clients { close(client) }
            cappedServer.stop()
        }
        for _ in 0..<64 {
            let client = connectClient(to: cappedPort)
            if client >= 0 { clients.append(client) }
        }
        let extra = connectClient(to: cappedPort)
        if extra >= 0 { clients.append(extra) }
        let started = ProcessInfo.processInfo.systemUptime
        var byte: UInt8 = 0
        let received = recv(extra, &byte, 1, 0)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        check(clients.count == 65 && received == 0 && elapsed < 2,
              "65th idle connection reaches EOF within two seconds (\(elapsed) s)")
    }

    do {
        let stalledServer = HTTPServer(port: 0, handlerTimeout: 0.5) { _ in
            try? await Task.sleep(for: .seconds(3))
            return HTTPResponse(status: 200)
        }
        let stalledPort = try await stalledServer.start()
        let client = connectClient(to: stalledPort)
        defer {
            if client >= 0 { close(client) }
            stalledServer.stop()
        }
        let started = ProcessInfo.processInfo.systemUptime
        let sent = sendRequest("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n", on: client)
        var reply = [UInt8](repeating: 0, count: 4096)
        let count = recv(client, &reply, reply.count, 0)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let text = String(decoding: reply.prefix(max(0, count)), as: UTF8.self)
        check(client >= 0 && sent && count > 0 && text.hasPrefix("HTTP/1.1 503 Service Unavailable\r\n") && elapsed < 2,
              "stalled handler receives 503 within two seconds (\(elapsed) s)")
        check(text.contains("timed out; a write may still be applied"),
              "stalled handler's 503 warns that a write may still be applied")
    }

    // Send well beyond one server read before reading the rejection, like an upload client.
    func oversizedUploadReply() -> (sent: Bool, response: String, readError: Int32) {
        let client = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard client >= 0 else { return (false, "", errno) }
        defer { close(client) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        guard setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            return (false, "", errno)
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return (false, "", errno) }
        let bodySize = 512 * 1024
        let upload = Array(("POST /api/annotations HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(bodySize)\r\n\r\n" + String(repeating: "x", count: bodySize)).utf8)
        let sentAll = upload.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let count = Glibc.send(client, raw.baseAddress! + offset, raw.count - offset, Int32(MSG_NOSIGNAL))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        shutdown(client, Int32(SHUT_WR))
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(client, &chunk, chunk.count, 0)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { return (sentAll, String(decoding: reply, as: UTF8.self), count < 0 ? errno : 0) }
            reply.append(contentsOf: chunk[..<count])
        }
    }
    let rejectedUpload = oversizedUploadReply()
    check(rejectedUpload.sent && rejectedUpload.readError == 0 && rejectedUpload.response.hasPrefix("HTTP/1.1 413 "),
          "oversized streaming upload receives 413 without reset (read errno \(rejectedUpload.readError))")
    check(Worktree.server(ofPort: Int(port))?.pid == getpid(), "procfs finds the check process's live listening socket")
    check(Worktree.ports(servedFrom: FileManager.default.currentDirectoryPath).contains(Int(port)), "procfs includes a live server in worktree port filtering")
    let liveLog = temp.appending(path: "rollout-live.jsonl")
    _ = FileManager.default.createFile(atPath: liveLog.path, contents: Data())
    let liveLogHandle = try FileHandle(forReadingFrom: liveLog)
    check(CodexSessions.openLogs(of: [getpid()])[getpid()]?.contains(liveLog) == true, "Codex log discovery uses the process's real open descriptors")
    try liveLogHandle.close()
    #endif
    server.stop()

    #if os(Linux)
    for failure in [EINTR, ECONNABORTED, ENETDOWN, EPROTO, ENOPROTOOPT, EHOSTDOWN, ENONET, EHOSTUNREACH, EOPNOTSUPP, ENETUNREACH] {
        check(HTTPServer.acceptAction(for: failure) == .retry, "accept retries connection error \(failure) immediately")
    }
    for failure in [EPERM, EMFILE, ENFILE, ENOBUFS, ENOMEM] {
        check(HTTPServer.acceptAction(for: failure) == .pause, "accept pauses on firewall denial or resource exhaustion \(failure)")
    }
    for failure in [EBADF, EINVAL] {
        check(HTTPServer.acceptAction(for: failure) == .stop, "accept stops on invalid listener \(failure)")
    }

    // Exhaust descriptors only after creating the client, so connect can still queue
    // a connection while accept sees EMFILE. Restore the limit before Foundation I/O.
    let pressureServer = HTTPServer(port: 0) { _ in HTTPResponse(status: 200, body: Data("recovered".utf8)) }
    let pressurePort = try await pressureServer.start()
    let pressureClient = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    let pressureClientError = errno
    check(pressureClient >= 0, "pressure client socket creation succeeds (errno \(pressureClientError))")
    let warmClient = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    let warmClientError = errno
    check(warmClient >= 0, "warm-up client socket creation succeeds (errno \(warmClientError))")
    var oldLimit = rlimit()
    _ = getrlimit(__rlimit_resource_t(RLIMIT_NOFILE.rawValue), &oldLimit)
    // Keep extra descriptors open to cover runners already above 128, when allowed.
    let initialDescriptors = try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd").count
    let extraDescriptors = min(140, max(0, Int(min(oldLimit.rlim_cur, 512)) - initialDescriptors - 32))
    let inheritedDescriptors = (0..<extraDescriptors).compactMap { _ -> Int32? in
        let descriptor = dup(pressureClient)
        return descriptor >= 0 ? descriptor : nil
    }
    let openDescriptors = try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd").count
    var smallLimit = rlimit(rlim_cur: min(rlim_t(openDescriptors + 32), oldLimit.rlim_max), rlim_max: oldLimit.rlim_max)
    let changedLimit = setrlimit(__rlimit_resource_t(RLIMIT_NOFILE.rawValue), &smallLimit) == 0
    var occupied: [Int32] = []
    if changedLimit {
        while true {
            let descriptor = dup(pressureClient)
            if descriptor < 0 { break }
            occupied.append(descriptor)
        }
    }
    var pressureAddress = sockaddr_in()
    pressureAddress.sin_family = sa_family_t(AF_INET)
    pressureAddress.sin_port = pressurePort.bigEndian
    pressureAddress.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
    _ = withUnsafePointer(to: &pressureAddress) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(warmClient, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    usleep(30_000)
    let queued = withUnsafePointer(to: &pressureAddress) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(pressureClient, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    usleep(60_000)
    for descriptor in occupied { close(descriptor) }
    close(warmClient)
    for descriptor in inheritedDescriptors { close(descriptor) }
    _ = setrlimit(__rlimit_resource_t(RLIMIT_NOFILE.rawValue), &oldLimit)
    var pressureTimeout = timeval(tv_sec: 2, tv_usec: 0)
    _ = setsockopt(pressureClient, SOL_SOCKET, SO_RCVTIMEO, &pressureTimeout, socklen_t(MemoryLayout<timeval>.size))
    let pressureRequest = Array("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
    _ = pressureRequest.withUnsafeBytes { Glibc.send(pressureClient, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
    var pressureBuffer = [UInt8](repeating: 0, count: 1024)
    let recovered = recv(pressureClient, &pressureBuffer, pressureBuffer.count, 0)
    check(changedLimit && !occupied.isEmpty && queued == 0 && recovered > 0, "listener recovers after accept runs out of descriptors")
    close(pressureClient)
    pressureServer.stop()

    // A stopped accept loop must not close the descriptor of its successor.
    let retiring = HTTPServer(port: 0) { _ in HTTPResponse(status: 200) }
    _ = try await retiring.start()
    usleep(10_000)
    retiring.stop()
    retiring.stop()
    let successor = HTTPServer(port: 0) { _ in HTTPResponse(status: 200) }
    let successorPort = try await successor.start()
    var successorRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(successorPort)/")!)
    successorRequest.timeoutInterval = 2
    let successorReply = try? await URLSession.shared.data(for: successorRequest)
    check((successorReply?.1 as? HTTPURLResponse)?.statusCode == 200, "stopping a blocked accept loop leaves the next server alive")
    successor.stop()
    #endif

}
