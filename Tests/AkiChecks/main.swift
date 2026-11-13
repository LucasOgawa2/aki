import AkiCore
import Foundation
#if os(Linux)
import Glibc
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Run with `swift run AkiChecks`. Exits 1 if any check fails.

var failures = 0

@MainActor func check(_ condition: Bool, _ name: String, line: Int = #line) {
    if condition {
        print("  ✓ \(name)")
    } else {
        failures += 1
        print("  ✗ \(name) (line \(line))")
    }
}

let temp = FileManager.default.temporaryDirectory.appending(path: "aki-checks-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: temp) }

// MARK: Client errors

#if os(Linux)
check(AkiClient.Failure.serverDown(port: 3850).description == "Aki isn't running (nothing on 127.0.0.1:3850). Run `aki serve`.", "Linux server-down message offers the CLI server")
#else
check(AkiClient.Failure.serverDown(port: 3850).description == "Aki isn't running (nothing on 127.0.0.1:3850). Open Aki.app or run `aki serve`.", "macOS server-down message offers both the app and CLI server")
#endif

// MARK: Store

print("store")
let store = AnnotationStore(directory: temp)
let first = try await store.upsert(Annotation(["url": "http://localhost:3000/", "comment": "make it bigger"]))
check(first.id.hasPrefix("aki_"), "generates an id when missing")
check(first.status == "pending", "new annotations are pending")
check(first["created_at"] != nil && first["updated_at"] != nil, "sets timestamps")

_ = try await store.upsert(Annotation(["id": "b", "url": "x", "comment": "", "worktree": "/repo/wt"]))
let merged = try await store.upsert(Annotation(["id": "b", "comment": "now with text", "_synced": true]))
check(merged["url"]?.string == "x" && merged["comment"]?.string == "now with text", "merges by id")
check(merged["_synced"] == .bool(true), "keeps fields it doesn't know")

for i in 0..<60 { _ = try await store.upsert(Annotation(["id": .string("bulk\(i)"), "url": "y"])) }
check(await store.list().annotations.count == 62, "lists everything by default (no silent limit of 50)")
check(await store.list(.init(limit: 5)).annotations.count == 5, "honors an explicit limit")
check(await store.list(.init(worktree: "/repo/wt")).annotations.map(\.id) == ["b"], "filters by worktree")

let updated = try await store.update("b", with: ["status": "completed", "id": "hijack"])
check(updated?.status == "completed" && updated?.id == "b", "update merges but never changes the id")
check(try await store.update("nope", with: [:]) == nil, "update of a missing id returns nil")
check(try await store.delete("b")?.id == "b", "delete returns the removed annotation")
check(await store.get("b") == nil, "deleted annotation is gone")

let snapshot = await store.list().annotations
check(try await store.replaceAll(snapshot.reversed()).skipped, "sync with the same content is skipped")
check(try await store.replaceAll([Annotation(["id": "only"])]).count == 1, "sync replaces everything")

let reopened = AnnotationStore(directory: temp)
check(await reopened.list().annotations.map(\.id) == ["only"], "persists to disk")
let permissions = try FileManager.default.attributesOfItem(atPath: reopened.fileURL.path)[.posixPermissions]
check((permissions as? Int) == 0o600, "annotations file is private (600)")

let brokenDir = temp.appending(path: "broken")
try FileManager.default.createDirectory(at: brokenDir, withIntermediateDirectories: true)
try Data("{not json".utf8).write(to: brokenDir.appending(path: "annotations.json"))
let broken = AnnotationStore(directory: brokenDir)
check(await broken.list().annotations.isEmpty, "a corrupted file starts empty")
let backups = try FileManager.default.contentsOfDirectory(atPath: brokenDir.path)
check(backups.contains { $0.contains("corrupted") }, "and keeps the corrupted file aside")

// MARK: API (called directly)

print("api")
let apiStore = AnnotationStore(directory: temp.appending(path: "api"))
let extensionOrigin = "chrome-extension://abcdefghijklmnop"
let api = AkiAPI(store: apiStore, token: String(repeating: "t", count: 64), allowedOrigins: [extensionOrigin])
let auth = ["host": "127.0.0.1:3850", "authorization": "Bearer " + String(repeating: "t", count: 64)]

func json(_ response: HTTPResponse) -> [String: JSONValue] {
    (try? JSONDecoder().decode(JSONValue.self, from: response.body))?.object ?? [:]
}

var response = await api.handle(HTTPRequest(method: "GET", path: "/health", headers: ["host": "localhost:3850"]))
check(response.status == 200 && json(response)["app"]?.string == "aki", "health is public")

response = await api.handle(HTTPRequest(method: "GET", path: "/api/annotations", headers: ["host": "127.0.0.1:3850"]))
check(response.status == 401, "no token → 401")

response = await api.handle(
    HTTPRequest(
        method: "GET", path: "/api/annotations",
        headers: ["host": "127.0.0.1:3850", "authorization": "Bearer wrong"]))
check(response.status == 401, "wrong token → 401")

response = await api.handle(
    HTTPRequest(
        method: "DELETE", path: "/api/annotations/x",
        headers: ["host": "127.0.0.1:3850", "origin": "https://evil.example"]))
check(response.status == 401 && response.headers["Access-Control-Allow-Origin"] == nil, "random website can't call it")

response = await api.handle(
    HTTPRequest(method: "GET", path: "/api/annotations", headers: auth.merging(["host": "evil.example:3850"]) { $1 }))
check(response.status == 403, "foreign Host header → 403 (DNS rebinding)")

response = await api.handle(
    HTTPRequest(
        method: "GET", path: "/api/annotations",
        headers: ["host": "127.0.0.1:3850", "origin": extensionOrigin]))
check(
    response.status == 200 && response.headers["Access-Control-Allow-Origin"] == extensionOrigin,
    "allowed extension works without token, with CORS")

response = await api.handle(
    HTTPRequest(method: "POST", path: "/api/annotations", headers: auth, body: Data(#"{"id":"p1","url":"u","comment":"hi"}"#.utf8)))
check(response.status == 200 && json(response)["success"] == .bool(true), "POST creates")

response = await api.handle(
    HTTPRequest(method: "POST", path: "/api/annotations", headers: auth, body: Data("[1,2]".utf8)))
check(response.status == 400, "POST with a non-object body → 400")

response = await api.handle(HTTPRequest(method: "GET", path: "/api/annotations/p1", headers: auth))
check(json(response)["annotation"]?.object?["comment"]?.string == "hi", "GET by id")

response = await api.handle(
    HTTPRequest(method: "PUT", path: "/api/annotations/p1", headers: auth, body: Data(#"{"status":"completed"}"#.utf8)))
check(json(response)["annotation"]?.object?["status"]?.string == "completed", "PUT merges")

response = await api.handle(
    HTTPRequest(method: "GET", path: "/api/annotations", query: ["status": "pending"], headers: auth))
check(json(response)["count"] == .number(0) && json(response)["total"] == .number(1), "list filters by status")

response = await api.handle(
    HTTPRequest(
        method: "POST", path: "/api/annotations/sync", headers: auth,
        body: Data(#"{"annotations":[{"id":"s1"},{"id":"s2"}]}"#.utf8)))
check(json(response)["count"] == .number(2), "sync replaces")

response = await api.handle(
    HTTPRequest(method: "POST", path: "/api/annotations/sync", headers: auth, body: Data(#"{"annotations":[{}]}"#.utf8)))
check(response.status == 400, "sync rejects annotations without id")

response = await api.handle(HTTPRequest(method: "DELETE", path: "/api/annotations/s1", headers: auth))
check(json(response)["deleted"] == .bool(true), "DELETE")
response = await api.handle(HTTPRequest(method: "DELETE", path: "/api/annotations/s1", headers: auth))
check(response.status == 404, "DELETE twice → 404")

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

// MARK: Worktrees, text, images

print("worktree")
check(Worktree.localPort(of: "http://localhost:3000/a?b") == 3000, "port of a localhost URL")
check(Worktree.localPort(of: "http://127.0.0.1/") == 80, "default port")
check(Worktree.localPort(of: "https://example.com/") == nil, "external sites have no local port")
let filter = WorktreeFilter(worktree: "/repo/wt")
check(filter.matches(Annotation(["worktree": "/repo/wt"])), "tagged annotation matches its worktree")
check(!filter.matches(Annotation(["worktree": "/repo/other", "url": "http://localhost:1/"])), "tag wins over the URL")
check(!filter.matches(Annotation(["url": "https://example.com/"])), "external page isn't in any worktree")

let tagging = AkiAPI(
    store: AnnotationStore(directory: temp.appending(path: "tag")), token: String(repeating: "t", count: 64),
    worktreeForPort: { port, _ in port == 3000 ? "/repo/front" : nil })
response = await tagging.handle(
    HTTPRequest(method: "POST", path: "/api/annotations", headers: auth, body: Data(#"{"url":"http://localhost:3000/x"}"#.utf8)))
check(json(response)["annotation"]?.object?["worktree"]?.string == "/repo/front", "localhost page gets the worktree serving it")
response = await tagging.handle(
    HTTPRequest(method: "POST", path: "/api/annotations", headers: auth, body: Data(#"{"url":"http://localhost:4000/"}"#.utf8)))
check(json(response)["annotation"]?.object?["worktree"] == nil, "unknown port stays untagged")

print("sessions")
func processArguments(_ argv: [String], environment: [String]) -> Data {
    var argc = Int32(argv.count)
    var data = withUnsafeBytes(of: &argc) { Data($0) }
    data.append(Data("/bin/agent\0\0\0".utf8))
    for value in argv + environment { data.append(Data((value + "\0").utf8)) }
    data.append(0)
    return data
}
check(AgentSessions.terminalHandle(inProcessArguments: processArguments(
    ["codex", "ORCA_TERMINAL_HANDLE=wrong"], environment: ["PATH=/bin", "ORCA_TERMINAL_HANDLE=term_right"])) == "term_right",
    "Orca identity comes from the environment, never from the user's prompt")
check(AgentSessions.terminalHandle(inProcessArguments: processArguments(
    ["codex", "ORCA_TERMINAL_HANDLE=wrong"], environment: ["PATH=/bin"])) == nil,
    "a prompt cannot impersonate an Orca tab when no identity was injected")
check(AgentSessions.terminalHandle(inProcessArguments: Data([1, 2, 3])) == nil,
    "truncated process arguments have no terminal identity")
check(Annotation(["agent": "grok", "session_id": "codex:12"]).destinationAgent == .grok,
    "a moved mark's saved agent takes precedence over its legacy session id")
check(Annotation(["session_id": "codex:12"]).destinationAgent == .codex,
    "old Codex marks retain their agent after the process closes")
check(Annotation(["session_id": "unknown:12"]).destinationAgent == nil,
    "an unknown session id never invents an agent")
let identityMark = try await store.upsert(Annotation([
    "id": "identity", "agent": "codex", "session_name": "App session",
    "terminal_app": ["name": "Orca", "bundle_id": "com.stablyai.orca"],
]))
let identityReopened = AnnotationStore(directory: temp)
let persistedIdentity = await identityReopened.get(identityMark.id)
check(persistedIdentity?.destinationAgent == .codex
      && persistedIdentity?["session_name"]?.string == "App session"
      && persistedIdentity?["terminal_app"]?.object?["bundle_id"]?.string == "com.stablyai.orca",
      "history preserves the agent, session name and terminal app after reopening")
let registry = temp.appending(path: "sessions")
try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
try Data(#"{"pid":\#(getpid()),"sessionId":"s-1","cwd":"/repo/wt","name":"PHOTO EDITOR","nameSource":"user","status":"waiting","kind":"interactive","updatedAt":1791065231403}"#.utf8)
    .write(to: registry.appending(path: "\(getpid()).json"))
try Data(#"{"pid":999999,"sessionId":"dead","cwd":"/x","kind":"interactive"}"#.utf8).write(to: registry.appending(path: "999999.json"))
let live = ClaudeSessions.live(in: registry)
check(live.map(\.sessionId) == ["s-1"], "only sessions whose process is alive")
check(live.first?.status == .waiting && live.first?.name == "PHOTO EDITOR", "status and name read")
check(ClaudeSessions.session(ofAncestorsOf: getpid(), in: registry)?.sessionId == "s-1", "finds the session it runs under")
let sessionFilter = WorktreeFilter(worktree: "/repo/wt", sessionId: "s-1")
check(sessionFilter.matches(Annotation(["session_id": "s-1", "worktree": "/repo/wt"])), "mark aimed at this session")
check(!sessionFilter.matches(Annotation(["session_id": "s-2", "worktree": "/repo/wt"])), "not one aimed at a sibling session")
check(sessionFilter.matches(Annotation(["worktree": "/repo/wt"])), "untargeted marks in the worktree still arrive")

print("text and images")
let home = AkiHome(url: temp.appending(path: "home"))
let pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
let rich = Annotation([
    "id": "r1", "url": "http://localhost:3000/", "comment": "", "created_at": "2026-10-03T10:20:30.000Z",
    "element_context": ["tag": "button", "text": "Save"], "selector": "#save",
    "pending_changes": ["color": ["original": "red", "value": "blue"]],
    "screenshot": ["data_url": .string("data:image/png;base64," + pixel)],
])
let rendered = AnnotationText.render(rich, home: home)
check(rendered.contains("## #r1 · r1  (2026-10-03 10:20)"), "header with code, id and date")
// Short codes: the same everywhere, found from any terminal.
check(MarkFolder.code("aki_1791339895884_df9f68ee") == "df9f68", "short code of a mark")
// SHA-256 of "note_1" (from `shasum -a 256`): the same folder whichever crypto library makes it.
check(MarkFolder.folderName("note_1") == "x85e3ec00075af87", "a foreign id's folder is a fingerprint of it")
check(markCode("aki_1791339895884_df9f68ee") == "#df9f68", "short code as people read it")
let coded = [Annotation(["id": "aki_1_df9f68ee"]), Annotation(["id": "aki_2_e8a1b2c3"]), Annotation(["id": "aki_3_e8a1ffff"])]
check(MarkFolder.resolve(["#df9f68"], in: coded).found.map(\.id) == ["aki_1_df9f68ee"], "finds a mark by #code")
check(MarkFolder.resolve(["e8a1b2"], in: coded).found.map(\.id) == ["aki_2_e8a1b2c3"], "finds a mark by bare code")
check(MarkFolder.resolve(["e8a1"], in: coded).problems.count == 1, "an ambiguous code says so")
check(MarkFolder.resolve(["e8a1b2c3"], in: coded).found.map(\.id) == ["aki_2_e8a1b2c3"], "finds a mark by its 8-letter code (the message's commands)")
check(MarkFolder.resolve(["zzzzzz"], in: coded).problems.count == 1, "an unknown code says so")
check(MarkFolder.url(for: "aki_1_df9f68ee", created: Date(timeIntervalSince1970: 1_791_374_400), home: home).path
        .hasSuffix("/marks/2026-10-07/df9f68ee"), "a mark's folder is its day and its id's random part")
check(rendered.contains("comment:  (no text)") && rendered.contains("<button> #save"), "comment and element")
check(rendered.contains("change:   color: red → blue"), "pending style change")
let imageFile = AnnotationImage.file(for: rich, home: home)
check(imageFile?.pathExtension == "png" && FileManager.default.fileExists(atPath: imageFile?.path ?? ""), "inline screenshot saved as a file")
check(rendered.contains("image:    \(imageFile?.path ?? "-")"), "image path in the text")

print("wait")
try FileManager.default.createDirectory(at: home.url, withIntermediateDirectories: true)
let waitToken = try home.token()
let waitAPI = AkiAPI(
    store: AnnotationStore(directory: home.url), token: waitToken, worktreeForPort: { _, _ in nil })
let waitServer = HTTPServer(port: 0) { await waitAPI.handle($0) }
let waitPort = try await waitServer.start()
let client = try AkiClient(home: home, port: waitPort)
_ = try await waitAPI.store.upsert(Annotation(["id": "unread", "worktree": "/repo/wt"]))
let leftOver = try await Waiter.waitForNew(
    client: client, worktree: "/repo/wt", idle: .milliseconds(600), timeout: .seconds(3), poll: .milliseconds(150))
check(leftOver.map(\.id) == ["unread"], "a mark pending but never read comes back at once")
try await client.update("unread", ["status": "completed"])
_ = try await waitAPI.store.upsert(Annotation(["id": "old", "worktree": "/repo/wt", "read_at": "2026-10-16T00:00:00Z"]))
async let waited = Waiter.waitForNew(
    client: client, worktree: "/repo/wt", idle: .milliseconds(600), timeout: .seconds(10), poll: .milliseconds(150))
try await Task.sleep(for: .milliseconds(400))
_ = try await waitAPI.store.upsert(Annotation(["id": "new1", "worktree": "/repo/wt"]))
_ = try await waitAPI.store.upsert(Annotation(["id": "other", "worktree": "/repo/elsewhere"]))
try await Task.sleep(for: .milliseconds(300))
_ = try await waitAPI.store.upsert(Annotation(["id": "new2", "worktree": "/repo/wt"]))
let started = ContinuousClock.now
let batch = try await waited
check(Set(batch.map(\.id)) == ["new1", "new2"], "wait returns only new marks of this worktree, together")
check(ContinuousClock.now - started >= .milliseconds(400), "and only after the user pauses")
try await client.update("new1", ["status": "completed"])
check(await waitAPI.store.get("new1")?.status == "completed", "client resolves")
waitServer.stop()

// Which processes count as agent sessions.
// The Claude app's Code tab: its own Claude Code, under "Application Support", run as a program.
let desktopClaude = "/Users/x/Library/Application Support/Claude/claude-code/2.1.299/4fa9/claude.app/Contents/MacOS/claude --output-format stream-json --verbose --input-format stream-json"
check(AgentSessions.classify(desktopClaude) == .agent(.claude), "the Claude app's Code session is a session")
check(AgentSessions.headless(desktopClaude) == nil, "and not a headless run")
check(AgentSessions.isClaudeAppSession(desktopClaude), "found as a Claude app session by its process")
check(AgentSessions.sessionID(in: desktopClaude + " --resume=2b1c-44 --model=x") == "2b1c-44", "its session id from --resume=")
check(AgentSessions.sessionID(in: desktopClaude + " --session-id 9f9f") == "9f9f", "or from --session-id")
check(!AgentSessions.isClaudeAppSession("/Users/x/.local/bin/claude --resume=1"), "a terminal's claude isn't the app's")
check(ClaudeSessions.parse(Data(#"{"pid":1,"sessionId":"s","cwd":"/p","kind":"sdk","entrypoint":"claude-desktop"}"#.utf8)) != nil, "a Code session of the Claude app is listed")
check(ClaudeSessions.parse(Data(#"{"pid":1,"sessionId":"s","cwd":"/p","kind":"bg","entrypoint":"cli"}"#.utf8)) == nil, "a background run from a terminal isn't")
check(AgentSessions.classify("/opt/homebrew/bin/codex") == .agent(.codex), "codex alone is a session")
check(AgentSessions.classify("codex --no-daemon resume 01a1") == .agent(.codex), "codex resume is a session")
check(AgentSessions.classify("codex -c model=x review") == nil, "codex review with options isn't")
check(AgentSessions.classify("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex -c features.code_mode_host=true app-server --analytics-default-enabled") == nil,
      "the ChatGPT app's codex app-server isn't")
check(AgentSessions.classify(#"/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex -c forced_login_method="chatgpt" exec-server --remote https://x"#) == nil,
      "nor its exec-server")
check(AgentSessions.headless("/opt/homebrew/bin/codex -c model=x review --base main") == .codex, "a codex review spends Codex")
check(AgentSessions.headless("/opt/homebrew/bin/codex exec hi") == .codex, "so does codex exec")
check(AgentSessions.headless("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex app-server") == nil, "the app's server isn't a run")
check(AgentSessions.headless("/Users/x/.local/bin/claude -p hi") == .claude, "claude -p spends Claude")
check(AgentSessions.headless("/opt/homebrew/bin/node /opt/homebrew/bin/claude -p hi") == .claude, "also run by node")
check(AgentSessions.classify("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex sandbox -c shell_environment_policy.inherit=all") == nil,
      "the ChatGPT app's codex sandbox isn't")
check(AgentSessions.classify("claude -p hi") == nil && AgentSessions.classify("claude") == .agent(.claude), "claude -p isn't, claude is")

// A tab's status sign goes, a name's own first character stays.
check(tabNameWithoutStatus("✳ SEO AKI") == "SEO AKI", "status sign taken off a name")
check(tabNameWithoutStatus("⠂ MENU") == "MENU", "spinner taken off a name")
check(tabNameWithoutStatus("🐛 Login") == "🐛 Login", "an emoji in a name stays")
check(tabNameWithoutStatus("[API] auth") == "[API] auth", "brackets in a name stay")

// Codex's limits, from one of its log lines: the week goes by the window's length.
let codexLine = #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":17.0,"window_minutes":10080,"resets_at":4102444800},"secondary":{"used_percent":42.4,"window_minutes":300,"resets_at":4102444800}}}}"#
let codexLimits = UsageLimits.parseCodex(line: Data(codexLine.utf8), updated: Date())
check(codexLimits?.week?.percent == 17, "Codex week read from the 7-day window")
check(codexLimits?.fiveHour?.percent == 42, "Codex 5-hour window read")
let monthly = UsageLimits.parseCodex(line: Data(#"{"payload":{"rate_limits":{"primary":{"used_percent":3.0,"window_minutes":43200,"resets_at":4102444800},"secondary":null}}}"#.utf8), updated: Date())
check(monthly?.month?.percent == 3 && monthly?.week == nil, "Codex 30-day window read as the month")
check(UsageLimits.parseCodex(line: Data(#"{"payload":{"rate_limits":{"primary":null,"secondary":null}}}"#.utf8), updated: Date()) == nil,
      "no windows, no limits")
// What OpenAI says of a Codex account: resets saved, all-time numbers, weeks in order.
var codexAccount = CodexAccount()
codexAccount.addUsage(Data(#"{"plan_type":"prolite","rate_limit_reset_credits":{"available_count":3,"applicable_available_count":0}}"#.utf8))
codexAccount.addProfile(Data(#"{"stats":{"lifetime_tokens":2701713581,"total_threads":4133,"longest_running_turn_sec":15359,"most_used_reasoning_effort":"medium","top_invocations":[{"type":"plugin","plugin_name":"github","skill_name":null,"usage_count":299},{"type":"skill","plugin_name":null,"skill_name":"orca-cli","usage_count":6}],"weekly_usage_buckets":[{"start_date":"2026-03-09","tokens":5},{"start_date":"2026-03-02","tokens":9}]}}"#.utf8))
check(codexAccount.resetsSaved == 3 && codexAccount.resetsUsable == 0, "Codex resets saved read")
check(codexAccount.lifetimeTokens == 2701713581 && codexAccount.threads == 4133, "Codex all-time numbers read")
check(codexAccount.invocations.map(\.name) == ["github", "orca-cli"], "Codex calls named by plugin or skill")
check(codexAccount.weeks.map(\.tokens) == [9, 5], "Codex weeks oldest first")

// Codex's older logs come zstd-compressed: unpacked whole, and a cut file refused.
let packedLog = FileManager.default.temporaryDirectory.appending(path: "aki-check-\(UUID().uuidString).jsonl.zst")
let unpackedLog = FileManager.default.temporaryDirectory.appending(path: "aki-check-\(UUID().uuidString).jsonl")
let packedBytes = Data(base64Encoded: "KLUv/QRYkQAAbGluZSBvbmUKbGluZSB0d28KK4y37g==")!
try? packedBytes.write(to: packedLog)
check(TokenLedger.unpack(packedLog, to: unpackedLog) && (try? String(contentsOf: unpackedLog, encoding: .utf8)) == "line one\nline two\n",
      "a zstd log unpacked")
try? packedBytes.prefix(packedBytes.count - 4).write(to: packedLog)
check(!TokenLedger.unpack(packedLog, to: unpackedLog), "a cut zstd log refused")
try? FileManager.default.removeItem(at: packedLog)
try? FileManager.default.removeItem(at: unpackedLog)
// A real one, on demand: AKI_ZST_SAMPLE=<log.jsonl.zst> AKI_ZST_EXPECT=<same, unpacked by zstd -d>.
if let sample = ProcessInfo.processInfo.environment["AKI_ZST_SAMPLE"], let expect = ProcessInfo.processInfo.environment["AKI_ZST_EXPECT"] {
    check(TokenLedger.unpack(URL(fileURLWithPath: sample), to: unpackedLog)
          && (try? Data(contentsOf: unpackedLog)) == (try? Data(contentsOf: URL(fileURLWithPath: expect))), "a real Codex log unpacked as zstd does")
    try? FileManager.default.removeItem(at: unpackedLog)
}

// The history counts each request once: a first pass, the reading of older logs, then
// a session resumed after more than a week (read again from its start).
let ledgerRoot = FileManager.default.temporaryDirectory.appending(path: "aki-ledger-\(UUID().uuidString)")
let claudeLogs = ledgerRoot.appending(path: "claude/project")
try? FileManager.default.createDirectory(at: claudeLogs, withIntermediateDirectories: true)
let ledgerLog = claudeLogs.appending(path: "session.jsonl")
func claudeTurn(_ id: String, _ at: Date, _ tokens: Int) -> String {
    #"{"type":"assistant","timestamp":"\#(ISO8601DateFormatter().string(from: at))","requestId":"\#(id)","cwd":"/tmp","message":{"model":"claude-opus-4-5","usage":{"input_tokens":\#(tokens),"output_tokens":0}}}"# + "\n"
}
let ledgerNow = Date()
try? (claudeTurn("r1", ledgerNow.addingTimeInterval(-20 * 86400), 100) + claudeTurn("r2", ledgerNow.addingTimeInterval(-3 * 86400), 10)
      + claudeTurn("r3", ledgerNow.addingTimeInterval(-3600), 1)).write(to: ledgerLog, atomically: true, encoding: .utf8)
let ledger = TokenLedger(home: AkiHome(url: ledgerRoot.appending(path: "home")), claudeRoot: ledgerRoot.appending(path: "claude"),
                         codexRoot: ledgerRoot.appending(path: "codex/sessions"))
ledger.update(now: ledgerNow)
if ledger.needsBackfill { ledger.backfill() }
check(ledger.daily(agent: "claude").values.reduce(0, +) == 111, "old and new requests counted once")
// Ten days on, the session resumed: one new request, the file read again from its start.
let later = ledgerNow.addingTimeInterval(10 * 86400)
if let handle = try? FileHandle(forWritingTo: ledgerLog) {
    handle.seekToEndOfFile()
    handle.write(Data(claudeTurn("r4", later.addingTimeInterval(-3600), 1000).utf8))
    try? handle.close()
}
try? FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: ledgerLog.path)
ledger.update(now: later)
check(ledger.daily(agent: "claude").values.reduce(0, +) == 1111, "a resumed session's old requests not counted again")
// Aki closed for twelve days; a session that ran and ended three days into them still counts.
let ended = claudeLogs.appending(path: "ended.jsonl")
try? claudeTurn("r5", later.addingTimeInterval(3 * 86400), 5).write(to: ended, atomically: true, encoding: .utf8)
try? FileManager.default.setAttributes([.modificationDate: later.addingTimeInterval(3 * 86400)], ofItemAtPath: ended.path)
ledger.update(now: later.addingTimeInterval(12 * 86400))
check(ledger.daily(agent: "claude").values.reduce(0, +) == 1116, "a session that ended while Aki was closed counted")
try? FileManager.default.removeItem(at: ledgerRoot)

// The real logs' first reading, timed, with its peak memory: AKI_BACKFILL_BENCH=1 (never in CI).
if ProcessInfo.processInfo.environment["AKI_BACKFILL_BENCH"] == "1" {
    let benchHome = FileManager.default.temporaryDirectory.appending(path: "aki-bench-\(UUID().uuidString)")
    let bench = TokenLedger(home: AkiHome(url: benchHome))
    let started = Date()
    bench.update()
    let firstPass = Date().timeIntervalSince(started)
    bench.backfill()
    var usage = rusage()
    #if os(macOS)
    getrusage(RUSAGE_SELF, &usage)
    let peak = usage.ru_maxrss / 1_048_576
    #else
    // Linux counts it in kB.
    getrusage(RUSAGE_SELF.rawValue, &usage)
    let peak = usage.ru_maxrss / 1024
    #endif
    print(String(format: "  bench: first pass %.1f s, backfill %.1f s, peak %d MB, codex days %d",
                 firstPass, Date().timeIntervalSince(started) - firstPass, peak, bench.daily(agent: "codex").count))
    try? FileManager.default.removeItem(at: benchHome)
}

// Days in a row up to today (or yesterday), the longest run, the busiest day.
let streakNow = ISO8601DateFormatter().date(from: "2026-10-18T15:00:00Z")!
var utc = Calendar(identifier: .gregorian)
utc.timeZone = TimeZone(identifier: "UTC")!
let streakSpend = TokenSpend.of([], weekStart: nil, daily: ["2026-10-17": 5, "2026-10-16": 9, "2026-10-14": 1, "2026-10-01": 2,
                                                             "2026-10-02": 2, "2026-10-03": 2, "2026-10-04": 2],
                                now: streakNow, calendar: utc)
check(streakSpend.streak == 2, "streak counts back from yesterday when today is empty")
check(streakSpend.longestStreak == 4, "longest run found")
check(streakSpend.busiest?.total.tokens == 9, "busiest day found")
check(TokenSpend.modelName("claude-opus-4-1-20250805") == "Opus 4.1" && TokenSpend.modelName("gpt-6.1-sol") == "gpt-6.1-sol",
      "model names shortened")
let renewed = UsageLimits.parseCodex(line: Data(codexLine.replacingOccurrences(of: "4102444800", with: "1000").utf8), updated: Date())?.current()
check(renewed?.week?.percent == 0, "a window that already renewed reads 0%")
check((renewed?.week?.resets ?? .distantPast) > Date(), "a renewed week keeps a start (its next renewal)")
check(UsageLimits.parseCodex(line: Data(codexLine.replacingOccurrences(of: #"{"type":"event_msg""#, with: #"{"timestamp":"2026-10-10T20:57:25.894Z","type":"event_msg""#).utf8),
                              updated: .distantPast)?.updated == Date(timeIntervalSince1970: 1791665845.894),
      "a Codex report dated by its own time")

#if os(macOS)
// The Mac's screenshots: found by their name (any language) or macOS's own mark, nothing else.
let shots = FileManager.default.temporaryDirectory.appending(path: "aki-shots-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: shots.appending(path: "inside"), withIntermediateDirectories: true)
let oldName = "Screenshot 2026-10-10 at 15.30.00 \(UUID().uuidString).png"
for name in [oldName, "Captura de Tela 2026-01-02 às 09.10.11.png", "inside/截屏2026-10-10 15.30.00.png",
             "screenshot of the logo.png", "Screenshot 1.png", "Screen Recording 2.mov", "report.pdf", "notes.txt"] {
    FileManager.default.createFile(atPath: shots.appending(path: name).path, contents: Data(repeating: 1, count: 1000))
}
let marked = shots.appending(path: "foto.png")
FileManager.default.createFile(atPath: marked.path, contents: Data(repeating: 1, count: 500))
_ = "1".withCString { setxattr(marked.path, "com.apple.metadata:kMDItemIsScreenCapture", $0, 1, 0, 0) }
let old = shots.appending(path: oldName)
try? FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-40 * 24 * 3600)], ofItemAtPath: old.path)
let found = Screenshots.scan([shots])
check(found.files.count == 4, "screenshots found by name in any language and by macOS's mark (\(found.files.count))")
check(found.bytes == 3500, "their size added up")
check(found.older(than: 30).map(\.url.lastPathComponent) == [old.lastPathComponent], "only the old one is old")
let oldOnes = found.older(than: 30)
check(Screenshots.trash(oldOnes).count == 1 && !FileManager.default.fileExists(atPath: old.path), "the old one goes to the Trash")
// Out of the Trash again: the check leaves nothing behind.
for item in oldOnes { try? FileManager.default.removeItem(at: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash/\(item.url.lastPathComponent)")) }
try? FileManager.default.removeItem(at: shots)
#endif

// Codex is working while its log has a turn open.
check(CodexSessions.turnOpen(#"{"payload":{"type":"task_complete"}}\n{"payload":{"type":"task_started"}}"#) == true, "a turn just started is open")
check(CodexSessions.turnOpen(#"{"payload":{"type":"task_started"}}\n{"payload":{"type":"task_complete"}}"#) == false, "a finished turn is closed")
check(CodexSessions.turnOpen(#"{"payload":{"type":"task_started"}}\n{"payload":{"type":"turn_aborted"}}"#) == false, "an interrupted turn is closed")
check(CodexSessions.turnOpen(#"{"type":"session_meta"}"#) == nil, "no turn event in it: look further")

// The agents' desktop apps: the app itself, never one of its helpers.
check(DesktopApps.bundleID(of: "app:com.openai.codex") == "com.openai.codex", "an app destination's id names its app")
check(DesktopApps.bundleID(of: "codex:123") == nil, "a terminal session isn't an app")
let appMessage = AnnotationText.forApp([
    Annotation(["id": "aki_1_aaaaaaaa", "created_at": "2026-10-13T10:00:00Z", "comment": "botão torto", "url": "http://localhost:3000/x"]),
    Annotation(["id": "aki_2_bbbbbbbb", "created_at": "2026-10-13T10:01:00Z"]),
])
check(appMessage.contains("2 marcas") && appMessage.contains("1. botão torto") && appMessage.contains("localhost:3000")
      && appMessage.contains("2. (sem comentário)") && !appMessage.contains("aki show"), "an app's message carries the marks themselves")
check(appMessage.hasPrefix("📍 Aki: 2 marcas na tela (#aaaaaa, #bbbbbb)."), "an app's message names its marks in its first line")

// A Codex conversation's name comes from its index, by the id ending its log's name.
let codexHome = FileManager.default.temporaryDirectory.appending(path: "aki-codex-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
try? """
{"id":"01a1372a-7a31-78a2-a61a-aa7a4582e215","thread_name":"Primeiro nome","updated_at":"x"}
{"id":"01a1372a-7a31-78a2-a61a-aa7a4582e215","thread_name":"Revisar NFs no Drive","updated_at":"y"}
""".write(to: codexHome.appending(path: "session_index.jsonl"), atomically: true, encoding: .utf8)
let codexLog = URL(filePath: "/x/rollout-2026-10-13T18-28-13-01a1372a-7a31-78a2-a61a-aa7a4582e215.jsonl")
check(CodexSessions.threadName(of: codexLog, home: codexHome) == "Revisar NFs no Drive", "a Codex conversation is named as Codex named it last")
try? FileManager.default.removeItem(at: codexHome)

// The Claude app's cached usage: only its own usage request, and its two windows.
check(ClaudeAppUsage.isUsage("1/0/https://claude.ai/api/organizations/abc/usage"), "claude app usage key")
check(ClaudeAppUsage.isUsage("1/0/https://claude.ai/api/organizations/abc/usage?x=1"), "claude app usage key with query")
check(!ClaudeAppUsage.isUsage("1/0/https://claude.ai/api/organizations/abc/chat_conversations"), "other claude requests are not read")
let appUsage = ClaudeAppUsage.parse(Data(#"{"five_hour":{"utilization":12.4,"resets_at":"2026-10-15T22:00:00.123+00:00"},"seven_day":{"utilization":29,"resets_at":"2026-10-19T12:00:00Z"}}"#.utf8), updated: Date())
check(appUsage?.week?.percent == 29 && appUsage?.fiveHour?.percent == 12 && appUsage?.week?.resets != nil && appUsage?.fiveHour?.resets != nil, "claude app usage parsed")
check(ClaudeAppUsage.parse(Data(#"{"other":1}"#.utf8), updated: Date()) == nil, "no windows, no reading")
#if os(Linux)
// Where the Claude app keeps its cache on Linux: XDG_CONFIG_HOME only when it is an absolute path.
let xdgHome = URL(filePath: "/home/someone")
check(ClaudeAppUsage.configHome(environment: ["XDG_CONFIG_HOME": "/opt/cfg"], home: xdgHome).path == "/opt/cfg", "an absolute XDG_CONFIG_HOME is used")
check(ClaudeAppUsage.configHome(environment: ["XDG_CONFIG_HOME": "cfg"], home: xdgHome).path == "/home/someone/.config", "a relative XDG_CONFIG_HOME is ignored")
check(ClaudeAppUsage.configHome(environment: ["XDG_CONFIG_HOME": ""], home: xdgHome).path == "/home/someone/.config", "an empty XDG_CONFIG_HOME is ignored")
check(ClaudeAppUsage.configHome(environment: [:], home: xdgHome).path == "/home/someone/.config", "no XDG_CONFIG_HOME falls back to ~/.config")
#endif

// A message pasted into a Claude app's Code session: found in that session's transcript.
do {
    let base = FileManager.default.temporaryDirectory.appending(path: "aki-received-\(UUID().uuidString)")
    let registry = base.appending(path: "sessions"), projects = base.appending(path: "projects")
    let cwd = "/tmp/proj x"
    let slug = cwd.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
    try? FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: projects.appending(path: slug), withIntermediateDirectories: true)
    try? Data(#"{"pid":\#(getpid()),"sessionId":"s1","cwd":"/tmp/proj x","kind":"sdk","entrypoint":"claude-desktop"}"#.utf8)
        .write(to: registry.appending(path: "1.json"))
    let line = #"{"type":"user","message":{"content":"📍 Aki: 2 marcas na tela (#ab12cd, #ef34aa).\n\"x\""}}"# + "\n"
    try? Data(line.utf8)
        .write(to: projects.appending(path: slug).appending(path: "s1.jsonl"))
    check(ClaudeSessions.received("📍 Aki: 2 marcas na tela (#ab12cd, #ef34aa).", sessionId: "s1", in: registry, projects: projects), "a message sent to a Code session is found in its transcript")
    check(!ClaudeSessions.received("📍 Aki: 1 marca na tela (#999999).", sessionId: "s1", in: registry, projects: projects), "another message isn't")
    try? FileManager.default.removeItem(at: registry.appending(path: "1.json"))
    check(ClaudeSessions.received("📍 Aki: 2 marcas na tela (#ab12cd, #ef34aa).", sessionId: "s1", in: registry, projects: projects), "found without a registry entry too")
    try? FileManager.default.removeItem(at: base)
}

// The week's conversations: a folder with quotes, also in a line cut short.
check(SessionHistory.firstValue(of: "cwd", in: #"{"cwd":"/tmp/projeto \"A\"","type":"user"}"#) == #"/tmp/projeto "A""#, "a folder with quotes is read whole")
check(SessionHistory.firstValue(of: "cwd", in: #"{"type":"session_meta","payload":{"id":"x","cwd":"/a \"b\"","base_instructions":"cut"#) == #"/a "b""#, "also from a line cut short")

// The apps' own conversations, each a destination.
check(DesktopApps.bundleID(of: "app:com.openai.codex#01a0-ab") == "com.openai.codex", "a conversation's app")
check(DesktopApps.conversation(of: "app:com.openai.codex#01a0-ab") == "01a0-ab", "a conversation's id")
check(DesktopApps.conversation(of: "app:com.openai.codex") == nil, "the app itself is no conversation")
check(DesktopApps.link(to: "01a0-ab", in: "com.openai.codex")?.absoluteString == "codex://threads/01a0-ab", "codex thread link")
check(DesktopApps.link(to: "abc-1", in: "com.anthropic.claudefordesktop")?.absoluteString == "claude://claude.ai/chat/abc-1", "claude chat link")
check(DesktopApps.link(to: "a/../b?x", in: "com.openai.codex") == nil, "only an id goes in a link")
check(ClaudeAppUsage.isConversationList("1/0/https://claude.ai/api/organizations/o/chat_conversations_v2?limit=30&offset=0"), "the chats list")
check(!ClaudeAppUsage.isConversationList("1/0/https://claude.ai/api/organizations/o/chat_conversations_v2?starred=true"), "not the starred ones")
let chats = ClaudeAppUsage.parseConversations(Data(#"{"data":[{"uuid":"a","name":"Old","updated_at":"2026-10-01T10:00:00Z"},{"uuid":"b","name":"New","updated_at":"2026-10-02T10:00:00Z"},{"uuid":"c","name":"","updated_at":"2026-10-03T10:00:00Z"}]}"#.utf8))
check(chats?.map(\.id) == ["b", "a"], "chats newest first, unnamed ones left out")

// A localhost page goes to the agent working on it, Claude or Codex alike.
let doubled = Worktree.listeningPorts(lsof: "p49823\nn*:5173\nn*:1337\np27690\nn[::1]:5173\np3512\nn127.0.0.1:3014\np9\nn*:3014")
check(doubled[5173] == 27690 && doubled[1337] == 49823, "two servers on a port: the one on ::1, where the browser goes")
check(doubled[3014] == 3512, "then the one on 127.0.0.1")
check(Worktree.listeningPorts(lsof: "p1\nn[::1]:5173\np2\nn127.0.0.1:5173", host: "127.0.0.1")[5173] == 2, "a page at 127.0.0.1: never the one on ::1")
check(Worktree.listeningPorts(lsof: "p1\nn[::1]:5173\np2\nn*:5173", host: "127.0.0.1")[5173] == 2, "nor over one on all addresses")
let families = "p1\nf10\ntIPv6\nn*:5173\np2\nf11\ntIPv4\nn127.0.0.1:5173"
check(Worktree.listeningPorts(lsof: families)[5173] == 1, "localhost: an IPv6 wildcard before 127.0.0.1 (the browser tries ::1 first)")
check(Worktree.listeningPorts(lsof: families, host: "127.0.0.1")[5173] == 2, "127.0.0.1: never an IPv6-only wildcard")
check(AgentSessions.starter(of: getpid(), among: [1, getppid()]) == getppid(), "the agent that started a server is found up its parents")
check(AgentSessions.starter(of: getpid(), among: [1]) == nil, "no agent above it: none")
let talk = FileManager.default.temporaryDirectory.appending(path: "aki-talk-\(getpid()).jsonl")
try? Data(#"{"text":"open http://localhost:5173/menu"}"#.utf8).write(to: talk)
check(AgentSessions.mentions(port: 5173, log: talk), "a log that talks about the port")
check(!AgentSessions.mentions(port: 517, log: talk) && !AgentSessions.mentions(port: 3000, log: talk), "not another port, nor part of one")
try? FileManager.default.removeItem(at: talk)

// The last prompt sent to each conversation, from the end of the histories.
let nowMS = Date().timeIntervalSince1970 * 1000
let claudeHistory = FileManager.default.temporaryDirectory.appending(path: "aki-history-\(getpid()).jsonl")
let codexHistory = FileManager.default.temporaryDirectory.appending(path: "aki-codex-history-\(getpid()).jsonl")
try? Data((
    [#"{"display":"old","timestamp":\#(Int(nowMS - 9 * 3600_000)),"sessionId":"a"}"#,
     #"{"display":"x","timestamp":\#(Int(nowMS - 2 * 3600_000)),"sessionId":"b"}"#,
     #"{"display":"y","timestamp":\#(Int(nowMS - 3600_000)),"sessionId":"b"}"#].joined(separator: "\n") + "\n").utf8).write(to: claudeHistory)
try? Data(#"{"session_id":"c","ts":\#(Int(nowMS / 1000) - 600),"text":"z"}"#.utf8).write(to: codexHistory)
let sentAt = PromptHistory.lastSent(since: Date().addingTimeInterval(-6 * 3600), files: [claudeHistory, codexHistory])
check(sentAt["a"] == nil, "a prompt older than the window isn't looked for")
check(abs((sentAt["b"]?.timeIntervalSince1970 ?? 0) * 1000 - (nowMS - 3600_000)) < 1000, "the last prompt to a Claude session")
check(sentAt["c"] != nil, "and to a Codex conversation")
check(PromptHistory.started(getpid()).map { Date().timeIntervalSince($0) < 3600 } == true, "when a process started")
check(CodexSessions.conversationID(of: URL(filePath: "/x/rollout-2026-10-20T10-00-00-01a155b7-0c44-7672-b0ed-01b3b43af09b.jsonl")) == "01a155b7-0c44-7672-b0ed-01b3b43af09b", "a Codex conversation's id from its log")
check(PromptHistory.switched(999_001, to: "a") == nil, "a conversation first seen is no switch")
check(PromptHistory.switched(999_001, to: "a") == nil, "nor is it seen again")
let moved = Date()
check(PromptHistory.switched(999_001, to: "b", now: moved) == moved, "/clear: the new conversation counts from then")
check(PromptHistory.switched(999_001, to: "b") == moved, "and keeps that time")
check(PromptHistory.historyOff("model = \"x\"\n[history]\npersistence = \"none\"\n"), "Codex's history turned off")
check(PromptHistory.historyOff("history.persistence = 'none'"), "turned off in one line")
check(!PromptHistory.historyOff("[history]\npersistence = \"save-all\"\n[other]\npersistence = \"none\""), "kept, whatever other sections say")
let night = (0..<5).map { (id: "s\($0)", used: Date().addingTimeInterval(-Double(8 + $0) * 3600)) }
check(AgentTerminal.keptInSight(resting: night, shown: 0, minimum: 3) == ["s0", "s1", "s2"], "after a night, the last used stay in sight")
check(AgentTerminal.keptInSight(resting: night, shown: 2, minimum: 3) == ["s0"], "only enough to reach the minimum")
check(AgentTerminal.keptInSight(resting: night, shown: 4, minimum: 3).isEmpty, "none once enough are awake")
check(AgentTerminal.keptInSight(resting: night, shown: 0, minimum: 0).isEmpty, "a minimum of 0 keeps none")
try? FileManager.default.removeItem(at: claudeHistory)
try? FileManager.default.removeItem(at: codexHistory)

// MARK: Processes on Linux (/proc, read from a folder laid out like it)

print("proc")
let proc = temp.appending(path: "proc")
func fakeProcess(_ pid: Int32, comm: String, parent: Int32, startTicks: Int = 0) throws {
    let folder = proc.appending(path: "\(pid)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("\(pid) (\(comm)) S \(parent) 1 1 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 \(startTicks) 1000 100\n".utf8)
        .write(to: folder.appending(path: "stat"))
}
try fakeProcess(4242, comm: "node", parent: 77)
try fakeProcess(4243, comm: "tmux: a) (b", parent: 4242)
let procFS = ProcFS(root: proc)
check(procFS.parent(of: 4242) == 77, "a process's parent")
check(procFS.parent(of: 4243) == 4242, "a name with spaces and parentheses doesn't shift the fields")
check(procFS.parent(of: 9999) == nil, "no parent for a process that's gone")
try Data("cpu  1 2 3\nbtime 1794527844\nprocesses 9\n".utf8).write(to: proc.appending(path: "stat"))
try fakeProcess(4244, comm: "claude", parent: 1, startTicks: 94_203)
check(ProcFS(root: proc, ticksPerSecond: 100).started(4244).map { abs($0.timeIntervalSince1970 - 1_794_528_786.03) < 0.001 } == true,
      "when a process started: boot time plus its start in clock ticks")
check(procFS.started(9999) == nil, "no start for a process that's gone")
try FileManager.default.createSymbolicLink(atPath: proc.appending(path: "4242/cwd").path, withDestinationPath: "/repo/wt")
check(procFS.cwd(of: 4242) == "/repo/wt", "a process's folder")
check(procFS.cwd(of: 4243) == nil, "none when it can't be read")
try Data("PATH=/bin\0ORCA_TERMINAL_HANDLE=term_1\0QUERY=a=b\0".utf8).write(to: proc.appending(path: "4242/environ"))
check(procFS.environment(of: 4242)?["ORCA_TERMINAL_HANDLE"] == "term_1", "a process's environment")
check(procFS.environment(of: 4242)?["QUERY"] == "a=b", "a value keeps its own =")
check(procFS.environment(of: 4243) == nil, "none when it can't be read")
try fakeProcess(4245, comm: "deleted folder", parent: 1)
try FileManager.default.createSymbolicLink(atPath: proc.appending(path: "4245/cwd").path, withDestinationPath: "/repo/wt (deleted)")
check(procFS.cwd(of: 4245) == "/repo/wt", "a deleted working folder keeps its original path")
try FileManager.default.removeItem(at: proc.appending(path: "4245/cwd"))
try FileManager.default.createSymbolicLink(atPath: proc.appending(path: "4245/cwd").path, withDestinationPath: "/repo/deleted files/wt")
check(procFS.cwd(of: 4245) == "/repo/deleted files/wt", "deleted within a legitimate folder name stays intact")
let existingDeletedFolder = temp.appending(path: "wt (deleted)")
try FileManager.default.createDirectory(at: existingDeletedFolder, withIntermediateDirectories: true)
try fakeProcess(4246, comm: "existing folder", parent: 1)
try FileManager.default.createSymbolicLink(atPath: proc.appending(path: "4246/cwd").path, withDestinationPath: existingDeletedFolder.path)
check(procFS.cwd(of: 4246) == existingDeletedFolder.path, "an existing working folder preserves its literal deleted suffix")
try Data("KEY=first\0KEY=second\0EMPTY=\0".utf8).write(to: proc.appending(path: "4245/environ"))
check(procFS.environment(of: 4245)?["KEY"] == "first", "the first duplicate environment key wins, as on macOS")
check(procFS.environment(of: 4245)?["EMPTY"] == "", "an empty environment value is preserved")
check(AgentSessions.terminalHandle(inEnvironment: ["ORCA_TERMINAL_HANDLE": "term_linux"]) == "term_linux", "Linux Orca identity uses the injected environment")
check(AgentSessions.terminalHandle(inEnvironment: ["ORCA_TERMINAL_HANDLE": ""]) == nil, "an empty Linux Orca handle is absent")
check(AgentSessions.terminalHandle(inEnvironment: [:]) == nil, "a missing Linux Orca handle is absent")
// Listening sockets and descriptors from a proc fixture, without invoking lsof.
let net = proc.appending(path: "net")
try FileManager.default.createDirectory(at: net, withIntermediateDirectories: true)
try Data("  sl local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n 0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000 1000 0 800 1\n 1: 00000000:1F91 00000000:0000 0A 0 0 0 1000 0 801\n 2: 0100007F:1F92 00000000:0000 01 0 0 0 1000 0 802\n 3: 0100007F:1F93 00000000:0000 0A 0 0 0 1001 0 803\n".utf8).write(to: net.appending(path: "tcp"))
try Data("  sl local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode\n 0: 00000000000000000000000001000000:1F94 0 0A 0 0 0 1000 0 804\n 1: 00000000000000000000000000000000:1F95 0 0A 0 0 0 1000 0 805\n".utf8).write(to: net.appending(path: "tcp6"))
let descriptors = proc.appending(path: "4242/fd")
try FileManager.default.createDirectory(at: descriptors, withIntermediateDirectories: true)
for inode in [800, 801, 802, 804, 805] {
    try FileManager.default.createSymbolicLink(atPath: descriptors.appending(path: "\(inode)").path, withDestinationPath: "socket:[\(inode)]")
}
try FileManager.default.createSymbolicLink(atPath: descriptors.appending(path: "9").path, withDestinationPath: "/logs/rollout-fixture.jsonl")
let fixturePorts = Worktree.listeningPorts(lsof: procFS.listeningSockets(), host: "localhost")
check(fixturePorts[8080] == 4242 && fixturePorts[8081] == 4242 && fixturePorts[8084] == 4242 && fixturePorts[8085] == 4242,
      "procfs discovers IPv4/IPv6 loopback and wildcard listeners")
check(fixturePorts[8082] == nil && fixturePorts[8083] == nil, "non-listening sockets and unreadable owners stay out")
check(procFS.openFiles(of: 4242).contains("/logs/rollout-fixture.jsonl"), "procfs reads open file links")
check(procFS.openFiles(of: 9999).isEmpty, "unreadable descriptor directories are empty")
// CPU snapshots use the same stat fixture as parent/start-time discovery.
let cpuProc = ProcFS(root: proc, ticksPerSecond: 100)
let cpuBefore = cpuProc.cpuSample(of: 4244, at: 10)!
var cpuStat = try String(contentsOf: proc.appending(path: "4244/stat"), encoding: .utf8)
cpuStat = cpuStat.replacingOccurrences(of: "0 0 0 0 0 0 0 0 20", with: "0 0 0 0 20 5 0 0 20")
try Data(cpuStat.utf8).write(to: proc.appending(path: "4244/stat"))
let cpuAfter = cpuProc.cpuSample(of: 4244, at: 10.25)!
#if os(Linux)
var cpuTracker = AgentSessions.CPUTracker()
check(AgentSessions.readsCPU("codex") && AgentSessions.readsCPU("claude") &&
      AgentSessions.readsCPU("/Application Support/Claude/claude-code/1/MacOS/claude --input-format stream-json"),
      "CPU sampling includes interactive agents and Claude app sessions")
check(!AgentSessions.readsCPU("sleep 1") && !AgentSessions.readsCPU("aki wait") && !AgentSessions.readsCPU("codex exec"),
      "CPU sampling excludes non-agents, wait listeners and headless commands")
check(cpuTracker.needsBaseline([4244: cpuBefore]), "first readable agent needs a baseline")
check(!cpuTracker.needsBaseline([:]), "unreadable agents do not trigger a sampling delay")
_ = cpuTracker.update([4244: cpuBefore], using: cpuProc)
check(!cpuTracker.needsBaseline([4244: cpuAfter]), "existing agent samples need no extra interval when unrelated processes appear")
check(cpuTracker.update([4244: cpuAfter], using: cpuProc)[4244] == 100, "first pair of samples reports a working agent")
let cpuIdle = cpuProc.cpuSample(of: 4244, at: 10.5)!
check(cpuTracker.update([4244: cpuIdle], using: cpuProc)[4244] == 0, "each scan renews the sample even when an agent is idle")
check(cpuTracker.update([4244: cpuIdle], using: cpuProc)[4244] == 0, "zero elapsed time stays idle")
let cpuResumedStat = cpuStat.replacingOccurrences(of: "0 0 0 0 20 5 0 0 20", with: "0 0 0 0 45 5 0 0 20")
try Data(cpuResumedStat.utf8).write(to: proc.appending(path: "4244/stat"))
let cpuResumed = cpuProc.cpuSample(of: 4244, at: 10.75)!
check(cpuTracker.update([4244: cpuResumed], using: cpuProc)[4244] == 100, "a resumed agent uses the latest idle sample, not a long-term average")
try Data(cpuStat.utf8).write(to: proc.appending(path: "4244/stat"))
_ = cpuTracker.update([:], using: cpuProc)
check(cpuTracker.needsBaseline([4244: cpuIdle]), "vanished agents are removed from the sampling cache")
_ = cpuTracker.update([4244: cpuIdle], using: cpuProc)
#endif
check(cpuProc.cpuPercent(from: cpuBefore, to: cpuAfter) == 100, "recent CPU counts user and system ticks, even for a long-lived process")
check(cpuProc.cpuPercent(from: cpuAfter, to: cpuProc.cpuSample(of: 4244, at: 10.5)!) == 0, "a previous CPU burst becomes idle when ticks stop")
try fakeProcess(4244, comm: "replacement", parent: 1, startTicks: 95_000)
check(cpuProc.cpuPercent(from: cpuBefore, to: cpuProc.cpuSample(of: 4244, at: 11)!) == nil, "a reused PID never inherits CPU")
#if os(Linux)
let cpuReplacement = cpuProc.cpuSample(of: 4244, at: 11)!
check(cpuTracker.needsBaseline([4244: cpuReplacement]), "reused agent PID needs a new baseline")
check(cpuTracker.update([4244: cpuReplacement], using: cpuProc)[4244] == 0, "reused PID cannot inherit the previous agent's CPU")
#endif
check(cpuProc.cpuPercent(from: cpuBefore, to: cpuBefore) == nil, "zero sample interval has no CPU percentage")
check(cpuProc.cpuSample(of: 9999, at: 12) == nil, "a vanished process has no CPU sample")
#if os(Linux)
check(ProcFS().parent(of: getpid()) == getppid(), "this process's parent, from the real /proc")
check(ProcFS().cwd(of: getpid()) == FileManager.default.currentDirectoryPath, "and its folder")
check(ProcFS().environment(of: getpid())?["PATH"] == ProcessInfo.processInfo.environment["PATH"], "and its environment")
#endif

// MARK: Linux marking (no interface)

print("linux marking: fields")
final class RandomParts: @unchecked Sendable {
    private var left: [String]
    private let lock = NSLock()
    init(_ parts: [String]) { left = parts }
    func next() -> String { lock.withLock { left.isEmpty ? "zzzzzzzz" : left.removeFirst() } }
}
let markRandom = RandomParts(["df9f68ee", "0a1b2c3d"])
let markClock = LinuxMarking.Clock(now: { Date(timeIntervalSince1970: 1_791_339_895.5) }, random: { markRandom.next() })
check(LinuxMarking.markID(at: Date(timeIntervalSince1970: 1_791_339_895.5), random: "df9f68ee") == "aki_1791339895500_df9f68ee", "a mark's id is aki_<ms>_<8 chars>, as on the Mac")
check(LinuxMarking.batchID(at: markClock.now()) == "batch_1791339895500", "the batch id is batch_<ms>")
let orcaSession = LinuxMarking.terminal(id: "s1", name: "SITE", worktree: "/repo/site", orcaHandle: "term_1")
let plainSession = LinuxMarking.terminal(id: "codex:42", agent: .codex, name: "api", worktree: "/repo/api")
check(LinuxMarking.sessionFields(of: orcaSession) == [
    "session_id": "s1", "worktree": "/repo/site", "agent": "claude", "session_name": "SITE", "terminal_app": ["name": "Orca"],
], "a session in an Orca tab: its identity, terminal_app Orca")
check(LinuxMarking.sessionFields(of: plainSession)["terminal_app"] == .null, "no Orca handle: terminal_app null, as the Mac without an owner app")
let areaMark = LinuxMarking.PortableMark(screen: 1, rect: .init(x: 10, y: 20, width: 300, height: 40), comment: "bigger", number: 2,
                                         app: .init(name: "firefox", window: "Docs — Mozilla Firefox"))
check(LinuxMarking.fields(of: areaMark, id: "aki_1_a", batch: "batch_1", terminal: orcaSession, imagePath: "/h/crop.jpg") == [
    "id": "aki_1_a", "comment": "bigger", "status": "pending", "kind": "area", "batch_id": "batch_1", "number": 2, "source": "linux",
    "rect": ["x": 10, "y": 20, "width": 300, "height": 40, "screen": 1],
    "app": ["name": "firefox", "window": "Docs — Mozilla Firefox"],
    "session_id": "s1", "worktree": "/repo/site", "agent": "claude", "session_name": "SITE", "terminal_app": ["name": "Orca"],
    "image_path": "/h/crop.jpg",
], "an area's fields: as the Mac's save, source linux, image always")
let pointMark = LinuxMarking.PortableMark(screen: 0, rect: .init(x: 5, y: 6, width: 0, height: 0), number: 1, app: .init(name: nil, window: ""))
let pointFields = LinuxMarking.fields(of: pointMark, id: "aki_1_b", batch: "batch_1", terminal: plainSession, imagePath: "/h/c.jpg")
check(pointFields["kind"] == "point" && pointFields["app"] == nil && pointFields["comment"] == "", "a click is a point; no app name nor title: no app")

let markHome = AkiHome(url: temp.appending(path: "mark-home"))
let markStore = AnnotationStore(directory: markHome.url)
let savedRound = await LinuxMarking.save([areaMark, pointMark], to: orcaSession, jpeg: { $0.number == 1 ? nil : Data([0xFF, 0xD8, 0xFF]) },
                                         store: markStore, home: markHome, clock: markClock)
check(savedRound.saved.map(\.id) == ["aki_1791339895500_df9f68ee"] && savedRound.failed == [pointMark.id], "a mark whose JPEG is missing fails and stays; the other is saved")
let savedMark = await markStore.get("aki_1791339895500_df9f68ee")
let savedFolder = MarkFolder.url(for: "aki_1791339895500_df9f68ee", created: markClock.now(), home: markHome)
check(savedMark?["image_path"]?.string == savedFolder.appending(path: "crop.jpg").path
      && (try? Data(contentsOf: savedFolder.appending(path: "crop.jpg"))) == Data([0xFF, 0xD8, 0xFF]), "the JPEG goes to the mark's folder as crop.jpg")
check(FileManager.default.fileExists(atPath: savedFolder.appending(path: "mark.json").path), "and its record, mark.json, beside it")
check(savedMark?["batch_id"] == "batch_1791339895500" && savedMark?["session_id"] == "s1", "saved with its batch and session")
let dayFolder = savedFolder.deletingLastPathComponent()
check((try? FileManager.default.contentsOfDirectory(atPath: dayFolder.path)) == ["df9f68ee"], "the failed mark leaves no folder behind")

print("linux marking: crop")
let monitor = LinuxMarking.PixelSize(width: 1920, height: 1080)
check(LinuxMarking.cropRect(for: .init(x: 100, y: 200, width: 300, height: 40), screen: monitor) == .init(x: 88, y: 188, width: 324, height: 64),
      "an area's crop: 12 px of room around it")
check(LinuxMarking.cropRect(for: .init(x: 960, y: 540, width: 0, height: 0), screen: monitor) == .init(x: 740, y: 390, width: 440, height: 300),
      "a point's crop: 440×300 around it")
check(LinuxMarking.cropRect(for: .init(x: 10, y: 1070, width: 0, height: 0), screen: monitor) == .init(x: 0, y: 920, width: 230, height: 160),
      "held to the screen's edges")
check(LinuxMarking.cropRect(for: .init(x: 1900.5, y: 3.25, width: 30, height: 10), screen: monitor) == .init(x: 1888, y: 0, width: 32, height: 26),
      "fractions widen to whole pixels (CGRect.integral), then the edge")
check(LinuxMarking.cropRect(for: .init(x: 3000, y: 3000, width: 0, height: 0), screen: monitor) == nil, "a mark off the screen has no crop")
check(LinuxMarking.encodedSize(of: .init(width: 2400, height: 600)) == .init(width: 1200, height: 300), "the JPEG's long side is at most 1200 px")
check(LinuxMarking.encodedSize(of: .init(width: 333, height: 2000)) == .init(width: 199, height: 1200), "a tall crop too, rounded down as on the Mac")
check(LinuxMarking.encodedSize(of: .init(width: 440, height: 300)) == .init(width: 440, height: 300), "a small crop keeps its size")
check(LinuxMarking.encodedSize(of: .init(width: 5000, height: 1)) == nil && LinuxMarking.encodedSize(of: .init(width: 0, height: 0)) == nil,
      "a crop that would shrink to nothing has no size")

print("linux marking: X11 pixels")
// 3×2 pixels, BGRx little-endian (the usual 24-bit depth), 4 bytes of padding per row.
let bgrx: [UInt8] = [
    0x03, 0x02, 0x01, 0, 0x06, 0x05, 0x04, 0, 0x09, 0x08, 0x07, 0, 0xEE, 0xEE, 0xEE, 0xEE,
    0x13, 0x12, 0x11, 0, 0x16, 0x15, 0x14, 0, 0x19, 0x18, 0x17, 0, 0xEE, 0xEE, 0xEE, 0xEE,
]
let bgrxLayout = LinuxMarking.XImageLayout(width: 3, height: 2, bytesPerLine: 16, bitsPerPixel: 32, byteOrder: .lsbFirst,
                                           redMask: 0xFF0000, greenMask: 0x00FF00, blueMask: 0x0000FF)
check(LinuxMarking.rgb(of: bgrx, layout: bgrxLayout, crop: .init(x: 0, y: 0, width: 3, height: 2))
      == [1, 2, 3, 4, 5, 6, 7, 8, 9, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19],
      "BGRx little-endian to packed RGB, the row padding skipped")
check(LinuxMarking.rgb(of: bgrx, layout: bgrxLayout, crop: .init(x: 1, y: 1, width: 2, height: 1)) == [0x14, 0x15, 0x16, 0x17, 0x18, 0x19],
      "a crop from the middle")
let xrgbBig: [UInt8] = [0, 0x01, 0x02, 0x03, 0, 0x04, 0x05, 0x06]
let msbLayout = LinuxMarking.XImageLayout(width: 2, height: 1, bytesPerLine: 8, bitsPerPixel: 32, byteOrder: .msbFirst,
                                          redMask: 0xFF0000, greenMask: 0x00FF00, blueMask: 0x0000FF)
check(LinuxMarking.rgb(of: xrgbBig, layout: msbLayout, crop: .init(x: 0, y: 0, width: 2, height: 1)) == [1, 2, 3, 4, 5, 6], "MSBFirst (xRGB in memory)")
let rgb24: [UInt8] = [0x03, 0x02, 0x01, 0x06, 0x05, 0x04, 0xEE, 0xEE]
let layout24 = LinuxMarking.XImageLayout(width: 2, height: 1, bytesPerLine: 8, bitsPerPixel: 24, byteOrder: .lsbFirst,
                                         redMask: 0xFF0000, greenMask: 0x00FF00, blueMask: 0x0000FF)
check(LinuxMarking.rgb(of: rgb24, layout: layout24, crop: .init(x: 0, y: 0, width: 2, height: 1)) == [1, 2, 3, 4, 5, 6], "24 bits per pixel")
var rgbxLayout = bgrxLayout
(rgbxLayout.redMask, rgbxLayout.blueMask) = (0x0000FF, 0xFF0000)
check(LinuxMarking.rgb(of: bgrx, layout: rgbxLayout, crop: .init(x: 0, y: 0, width: 1, height: 1)) == [3, 2, 1], "other masks: red where its mask says")
var bpp16 = bgrxLayout
bpp16.bitsPerPixel = 16
var oddMask = bgrxLayout
oddMask.greenMask = 0x00F0F0
check(LinuxMarking.rgb(of: bgrx, layout: bpp16, crop: .init(x: 0, y: 0, width: 1, height: 1)) == nil
      && LinuxMarking.rgb(of: bgrx, layout: oddMask, crop: .init(x: 0, y: 0, width: 1, height: 1)) == nil,
      "nil for 16 bits per pixel or a mask that isn't 8 bits in a row")
check(LinuxMarking.rgb(of: bgrx, layout: bgrxLayout, crop: .init(x: 2, y: 1, width: 2, height: 1)) == nil
      && LinuxMarking.rgb(of: Array(bgrx.prefix(20)), layout: bgrxLayout, crop: .init(x: 0, y: 0, width: 3, height: 2)) == nil
      && LinuxMarking.rgb(of: bgrx, layout: bgrxLayout, crop: .init(x: 0, y: 0, width: 0, height: 1)) == nil,
      "nil for a crop outside the image, a short buffer or an empty crop")

print("linux marking: delivery text")
var promptSession = LinuxMarking.terminal(id: "s1", name: "SITE `x`", worktree: "/repo/site")
promptSession.pendingIDs = ["aki_1_df9f68ee", "aki_2_0a1b2c3d"]
promptSession.pendingComments = ["(no text)", "make the `button` bigger and blue, with a softer shadow too please"]
promptSession.pending = 2
promptSession.undelivered = 2
promptSession.pendingPlaces = ["firefox", "Orca", "code"]
check(LinuxMarking.deliveryPrompt(for: promptSession, aki: "aki")
      == "📍 Aki → SITE 'x': 2 marcas novas (de firefox, Orca) — #0a1b2c · #df9f68 “make the 'button' bigger and blue, with a softer s…”."
      + " Leia com `aki show df9f68ee 0a1b2c3d` (abra a foto só se o pedido for visual), resolva e feche com `aki done df9f68ee 0a1b2c3d`."
      + " Se não forem para esta sessão, avise antes de mexer.",
      "the message typed to the agent: the Mac's own words, codes newest first beside their comments")
var oneMark = LinuxMarking.terminal(id: "s1", name: "api", worktree: "/repo/api")
oneMark.pendingIDs = ["note_1"]
oneMark.pendingComments = ["fix\nthis"]
check(LinuxMarking.deliveryPrompt(for: oneMark, aki: "'/opt/my aki/aki'")
      == "📍 Aki → api: 1 marca nova — #1 “fix this”. Leia com `'/opt/my aki/aki' list` (abra a foto só se o pedido for visual), resolva e feche com `'/opt/my aki/aki' done <códigos>`."
      + " Se não forem para esta sessão, avise antes de mexer.",
      "a mark from elsewhere: the session's list, never a code")
check(LinuxMarking.akiInvocation(executable: "/home/u/.local/bin/aki", akiOnPath: "/home/u/.local/bin/aki") == "aki",
      "the aki on PATH is this one: plain aki")
check(LinuxMarking.akiInvocation(executable: "/home/u/it's here/aki", akiOnPath: "/usr/bin/aki") == "'/home/u/it'\\''s here/aki'"
      && LinuxMarking.akiInvocation(executable: "/b/aki", akiOnPath: nil) == "'/b/aki'",
      "another aki on PATH, or none: this one's path, quoted for the shell")
check(LinuxMarking.executablePath(fromProcLink: "/repo/.build/debug/aki (deleted)") == "/repo/.build/debug/aki"
      && LinuxMarking.executablePath(fromProcLink: "/usr/bin/aki") == "/usr/bin/aki",
      "/proc/self/exe of a binary rebuilt meanwhile: without \" (deleted)\"")

print("linux marking: Orca")
check(Command.outcome("/bin/sleep", ["3"], timeout: 0.3) == .timedOut, "a program that doesn't end in time: timed out, not failed")
check(Command.outcome("/bin/sh", ["-c", "echo hi; exit 3"]) == .exited(status: 3, output: Data("hi\n".utf8)), "its status and output however it ended")
check(Command.outcome("/nonexistent/orca-ide", []) == .couldNotStart, "a missing program couldn't start")
check(LinuxMarking.sendArguments(handle: "term_1", prompt: "📍 hi") == ["terminal", "send", "--terminal", "term_1", "--text", "📍 hi", "--enter", "--json"],
      "one send with Enter, no --retry-request")
let orcaHome = temp.appending(path: "orca-home")
let orcaBin = orcaHome.appending(path: ".local/bin")
try FileManager.default.createDirectory(at: orcaBin, withIntermediateDirectories: true)
let fakeOrcaIDE = orcaBin.appending(path: "orca-ide"), fakeOrca = orcaHome.appending(path: "orca")
for file in [fakeOrcaIDE, fakeOrca] {
    _ = FileManager.default.createFile(atPath: file.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
}
check(LinuxMarking.orcaExecutable(path: orcaHome.path, home: temp.appending(path: "nobody")) == nil,
      "never `orca` (outside Orca that's GNOME's screen reader)")
check(LinuxMarking.orcaExecutable(path: "/nonexistent:" + orcaBin.path, home: temp) == fakeOrcaIDE.path, "orca-ide on PATH")
check(LinuxMarking.orcaExecutable(path: "/nonexistent", home: orcaHome) == fakeOrcaIDE.path, "else in ~/.local/bin")
let dryHome = AkiHome(url: temp.appending(path: "dry-home"))
let dry = LinuxMarking.orcaRunner(environment: ["AKI_DRY_DELIVER": "1", "PATH": orcaBin.path], akiHome: dryHome, home: orcaHome)
check(dry is LinuxMarking.DryOrcaRunner, "AKI_DRY_DELIVER=1: the runner only writes down what it would run")
check(LinuxMarking.orcaRunner(environment: ["PATH": orcaBin.path], akiHome: dryHome, home: orcaHome).map { ($0 as? LinuxMarking.ProcessOrcaRunner)?.executable } == fakeOrcaIDE.path,
      "else the real orca-ide")
check(LinuxMarking.orcaRunner(environment: ["PATH": "/nonexistent"], akiHome: dryHome, home: temp) == nil, "no orca-ide: no runner")
let drySent = dry?.run(["terminal", "send", "--text", "a \"b\""])
_ = dry?.run(["terminal", "list", "--json"])
let dryLines = ((try? String(contentsOf: dryHome.url.appending(path: "dry-deliver.log"), encoding: .utf8)) ?? "").split(separator: "\n")
check(dryLines.count == 2 && (try? JSONSerialization.jsonObject(with: Data(dryLines[0].utf8)) as? [String]) == ["terminal", "send", "--text", "a \"b\""],
      "each run a JSON array on its own line in $AKI_HOME/dry-deliver.log")
check(drySent.flatMap { if case .exited(0, let data) = $0 { return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["ok"] as? Bool } else { return nil } } == true,
      "and answers as a send that went")
try FileManager.default.createDirectory(at: dryHome.url, withIntermediateDirectories: true)
try Data(#"{"ok":true,"result":{"terminals":[{"handle":"term_9","worktreePath":"/repo"}]}}"#.utf8)
    .write(to: dryHome.url.appending(path: "dry-terminals.json"))
check(dry?.run(["terminal", "list", "--json", "--limit", "200"]) == .exited(status: 0, output: Data(#"{"ok":true,"result":{"terminals":[{"handle":"term_9","worktreePath":"/repo"}]}}"#.utf8)),
      "its tab list: $AKI_HOME/dry-terminals.json when there is one")
check(LinuxMarking.ProcessOrcaRunner(executable: "/bin/echo").run(["terminal", "list"]) == .exited(status: 0, output: Data("terminal list\n".utf8)),
      "the real runner runs the program it was given")
#if os(Linux)
let akiLink = orcaBin.appending(path: "aki")
try FileManager.default.createSymbolicLink(at: akiLink, withDestinationURL: fakeOrcaIDE)
check(LinuxMarking.akiOnPath("/nonexistent:" + orcaBin.path) == fakeOrcaIDE.path && LinuxMarking.akiOnPath("/nonexistent") == nil,
      "the aki on PATH, its link followed; none: nil")
#endif

print("linux marking: delivery")
final class FakeOrca: OrcaRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    let tabs: Command.Outcome, send: Command.Outcome
    init(tabs: Command.Outcome, send: Command.Outcome = .exited(status: 0, output: Data(#"{"ok":true}"#.utf8))) {
        self.tabs = tabs
        self.send = send
    }
    var ran: [[String]] { lock.withLock { calls } }
    var sends: [[String]] { ran.filter { $0.starts(with: ["terminal", "send"]) } }
    func run(_ arguments: [String]) -> Command.Outcome {
        lock.withLock { calls.append(arguments) }
        return arguments.starts(with: ["terminal", "list"]) ? tabs : send
    }
}
let siteTab = Command.Outcome.exited(status: 0, output: Data(#"{"ok":true,"result":{"terminals":[{"handle":"term_1","worktreePath":"/repo"}]}}"#.utf8))
let jpegBytes: (LinuxMarking.PortableMark) -> Data? = { _ in Data([0xFF, 0xD8]) }
func deliveryWorld(_ name: String) -> (AkiHome, AnnotationStore) {
    let home = AkiHome(url: temp.appending(path: "deliver-\(name)"))
    return (home, AnnotationStore(directory: home.url))
}
let siteSession = LinuxMarking.terminal(id: "s1", name: "SITE", worktree: "/repo/site", orcaHandle: "term_1")
let otherSession = LinuxMarking.terminal(id: "s2", name: "API", worktree: "/repo/api", orcaHandle: "term_2")
let firstMark = LinuxMarking.PortableMark(screen: 0, rect: .init(x: 1, y: 1, width: 50, height: 50), comment: "first", number: 1, app: .init(name: "firefox"))
let secondMark = LinuxMarking.PortableMark(screen: 0, rect: .init(x: 9, y: 9, width: 0, height: 0), comment: "", number: 2)

let (sentHome, sentStore) = deliveryWorld("sent")
_ = try await sentStore.upsert(Annotation(["id": "aki_1_00000001", "session_id": "s1", "worktree": "/repo/site", "comment": "old",
                                           "created_at": "2026-01-01T00:00:00Z", "delivered_at": "2026-01-01T00:00:01Z"]))
_ = try await sentStore.upsert(Annotation(["id": "aki_1_00000002", "session_id": "s2", "worktree": "/repo/site", "comment": "theirs",
                                           "created_at": "2026-01-01T00:00:00Z"]))
_ = try await sentStore.upsert(Annotation(["id": "aki_1_00000003", "worktree": "/repo/site", "comment": "by folder",
                                           "created_at": "2026-01-01T00:00:00Z"]))
let sentOrca = FakeOrca(tabs: siteTab)
let sentClock = LinuxMarking.Clock(now: { Date(timeIntervalSince1970: 1_791_339_895.5) }, random: RandomParts(["aaaaaaa1", "aaaaaaa2"]).next)
let sent = await LinuxMarking.deliver([firstMark, secondMark], to: "s1", sessions: [otherSession, siteSession], jpeg: jpegBytes,
                                      store: sentStore, home: sentHome, orca: sentOrca, aki: "aki", clock: sentClock)
check(sent.outcome == .sent && sent.saved.count == 2 && sent.failed.isEmpty, "saved and typed")
check(sentOrca.ran.first.map { Array($0.prefix(2)) } == ["terminal", "list"] && sentOrca.sends.count == 1, "the tab checked first, then one send")
let typed = sentOrca.sends.first ?? []
check(typed.count == 8 && Array(typed.prefix(5)) == ["terminal", "send", "--terminal", "term_1", "--text"] && Array(typed.suffix(2)) == ["--enter", "--json"],
      "typed into the session's own tab")
check(typed.count > 5 && typed[5] == "📍 Aki → SITE: 3 marcas novas (de firefox) — #aaaaaa · #aaaaaa “first” · #000000 “by folder”."
      + " Leia com `aki show 00000003 aaaaaaa1 aaaaaaa2` (abra a foto só se o pedido for visual), resolva e feche com `aki done 00000003 aaaaaaa1 aaaaaaa2`."
      + " Se não forem para esta sessão, avise antes de mexer.",
      "naming the session's marks not delivered yet, oldest first (one sent earlier left out, another session's too)")
check(sent.prompt == typed.last.flatMap { _ in typed.count > 5 ? typed[5] : nil }, "the report keeps the message typed")
let afterSend = await sentStore.list().annotations
func deliveredAt(_ id: String) -> String? { afterSend.first { $0.id == id }?["delivered_at"]?.string }
check(deliveredAt("aki_1791339895500_aaaaaaa1") == "2026-10-07T02:24:55Z" && deliveredAt("aki_1791339895500_aaaaaaa2") == "2026-10-07T02:24:55Z"
      && deliveredAt("aki_1_00000003") == "2026-10-07T02:24:55Z", "each mark sent recorded as delivered (ISO 8601)")
check(deliveredAt("aki_1_00000002") == nil && deliveredAt("aki_1_00000001") == "2026-01-01T00:00:01Z", "another session's mark untouched, an earlier delivery kept")

let (heldHome, heldStore) = deliveryWorld("held")
var askingSession = siteSession
askingSession.state = .waiting
let heldOrca = FakeOrca(tabs: siteTab)
let held = await LinuxMarking.deliver([firstMark], to: "s1", sessions: [askingSession], jpeg: jpegBytes, store: heldStore, home: heldHome,
                                      orca: heldOrca, aki: "aki")
check(held.outcome == .held("SITE is asking you something: the mark is saved and goes with your next send."), "asking something: held, with why")
check(heldOrca.ran.isEmpty && held.saved.count == 1 && held.saved.first?["delivered_at"] == nil, "nothing typed, the mark saved and not delivered")

let (noTabHome, noTabStore) = deliveryWorld("notab")
let noTabOrca = FakeOrca(tabs: siteTab)
let noTab = await LinuxMarking.deliver([firstMark, secondMark], to: "codex:42", sessions: [plainSession], jpeg: jpegBytes, store: noTabStore,
                                       home: noTabHome, orca: noTabOrca, aki: "aki")
check(noTab.outcome == .notTyped("Saved for api, not typed: it isn't in an Orca tab. Its agent finds them with `aki list`.") && noTabOrca.ran.isEmpty
      && noTab.saved.count == 2, "no Orca handle: saved, not typed")
let noOrca = await LinuxMarking.deliver([firstMark], to: "s1", sessions: [siteSession], jpeg: jpegBytes, store: noTabStore,
                                        home: noTabHome, orca: nil, aki: "aki")
check(noOrca.outcome == .notTyped("Saved for SITE, not typed: orca-ide wasn't found."), "no orca-ide: saved, not typed")

let (wrongTabHome, wrongTabStore) = deliveryWorld("wrongtab")
let wrongTabOrca = FakeOrca(tabs: .exited(status: 0, output: Data(#"{"ok":true,"result":{"terminals":[{"handle":"term_1","worktreePath":"/elsewhere"}]}}"#.utf8)))
let wrongTab = await LinuxMarking.deliver([firstMark], to: "s1", sessions: [siteSession], jpeg: jpegBytes, store: wrongTabStore,
                                          home: wrongTabHome, orca: wrongTabOrca, aki: "aki")
check(wrongTab.outcome == .notTyped("Saved for SITE, not typed: Orca has no tab term_1 in its folder.") && wrongTabOrca.sends.isEmpty,
      "a handle Orca lists in another folder: saved, not typed")
let listTimeout = FakeOrca(tabs: .timedOut)
let unlisted = await LinuxMarking.deliver([firstMark], to: "s1", sessions: [siteSession], jpeg: jpegBytes, store: wrongTabStore,
                                          home: wrongTabHome, orca: listTimeout, aki: "aki")
check(unlisted.outcome == .notTyped("Saved for SITE, not typed: Orca didn't list its tabs.") && listTimeout.sends.isEmpty,
      "Orca's list not answering: saved, not typed")

let (zeroHome, zeroStore) = deliveryWorld("zero")
let zero = await LinuxMarking.deliver([firstMark], to: nil, sessions: [], jpeg: jpegBytes, store: zeroStore, home: zeroHome, orca: FakeOrca(tabs: siteTab), aki: "aki")
check(zero.outcome == .notSaved("No agent session to send to: nothing was saved.") && zero.failed == [firstMark.id], "zero sessions: nothing saved, why")
let gone = await LinuxMarking.deliver([firstMark], to: "s9", sessions: [siteSession], jpeg: jpegBytes, store: zeroStore, home: zeroHome, orca: FakeOrca(tabs: siteTab), aki: "aki")
check(gone.outcome == .notSaved("That session closed: choose another. Nothing was saved."), "the destination gone: nothing saved")
let noJPEGOrca = FakeOrca(tabs: siteTab)
let noJPEG = await LinuxMarking.deliver([firstMark], to: "s1", sessions: [siteSession], jpeg: { _ in nil }, store: zeroStore, home: zeroHome, orca: noJPEGOrca, aki: "aki")
check(noJPEG.outcome == .notSaved("The mark couldn't be saved: nothing was sent.") && noJPEGOrca.ran.isEmpty && noJPEG.failed == [firstMark.id],
      "nothing saved: nothing typed")
check(await zeroStore.list().annotations.isEmpty, "and the store stays empty")

let (slowHome, slowStore) = deliveryWorld("slow")
let slowOrca = FakeOrca(tabs: siteTab, send: .timedOut)
let slow = await LinuxMarking.deliver([firstMark], to: "s1", sessions: [siteSession], jpeg: jpegBytes, store: slowStore, home: slowHome, orca: slowOrca, aki: "aki")
check(slow.outcome == .uncertain("Saved for SITE. Orca didn't answer in time: the message may have been typed, so it isn't sent again.")
      && slowOrca.sends.count == 1, "a send with no answer in time: uncertain, never sent again")
check(await slowStore.list().annotations.allSatisfy { $0["delivered_at"] == nil }, "and not recorded as delivered (the next send names it)")
let refusedOrca = FakeOrca(tabs: siteTab, send: .exited(status: 0, output: Data(#"{"ok":false,"error":{"message":"no such terminal"}}"#.utf8)))
let refused = await LinuxMarking.deliver([firstMark], to: "s1", sessions: [siteSession], jpeg: jpegBytes, store: slowStore, home: slowHome, orca: refusedOrca, aki: "aki")
check(refused.outcome == .typingFailed("Saved for SITE, but Orca didn't type the message.") && refusedOrca.sends.count == 1,
      "ok:false with exit 0 is a failure")
let crashedOrca = FakeOrca(tabs: siteTab, send: .exited(status: 1, output: Data()))
let crashed = await LinuxMarking.deliver([firstMark], to: "s1", sessions: [siteSession], jpeg: jpegBytes, store: slowStore, home: slowHome, orca: crashedOrca, aki: "aki")
check(crashed.outcome == .typingFailed("Saved for SITE, but Orca didn't type the message."), "so is a non-zero exit")
check(await slowStore.list().annotations.allSatisfy { $0["delivered_at"] == nil }, "none of those recorded as delivered")

print("linux marking: overlay")
typealias Overlay = LinuxMarking.OverlayState
extension Array { func at(_ i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
func at(_ x: Double, _ y: Double) -> LinuxMarking.Point { .init(x: x, y: y) }
let sessionA = LinuxMarking.terminal(id: "a", name: "A", worktree: "/a", lastSent: Date(timeIntervalSince1970: 10))
let sessionB = LinuxMarking.terminal(id: "b", name: "B", worktree: "/b", lastSent: Date(timeIntervalSince1970: 20))
let sessionC = LinuxMarking.terminal(id: "c", name: "C", worktree: "/c")
check(Overlay(sessions: [sessionA, sessionB, sessionC]).destination == "b", "the destination starts on the session used last")
check(Overlay(sessions: [sessionC, LinuxMarking.terminal(id: "d", name: "D", worktree: "/d")]).destination == "c", "none used yet: the first")
check(Overlay(sessions: []).destination == nil, "no sessions: no destination")

var overlay = Overlay(sessions: [sessionA, sessionB, sessionC])
var edge = Overlay(sessions: [sessionA])
_ = edge.handle(.pointer(screen: 0, from: at(100, 100), to: at(103, 104), app: nil))
check(edge.marks.first?.rect == .init(x: 100, y: 100, width: 3, height: 4), "moved 5 px: already a drag")
_ = overlay.handle(.pointer(screen: 1, from: at(100, 100), to: at(102, 103), app: .init(name: "firefox")))
check(overlay.marks.count == 1 && overlay.marks.at(0)?.rect == .init(x: 100, y: 100, width: 0, height: 0) && overlay.marks.at(0)?.rect.isPoint == true
      && overlay.marks.at(0)?.screen == 1 && overlay.marks.at(0)?.app == .init(name: "firefox"), "moved under 5 px: a point where it was pressed")
check(overlay.editing == overlay.marks.at(0)?.id && overlay.justMade && overlay.marks.at(0)?.number == 1, "and its card opens")
_ = overlay.handle(.draft("  first note "))
check(overlay.draft == "  first note " && !overlay.justMade, "typing edits the draft")
_ = overlay.handle(.pointer(screen: 0, from: at(200, 90), to: at(20, 10), app: nil))
check(overlay.marks.count == 2 && overlay.marks.at(0)?.comment == "first note" && overlay.marks.at(1)?.rect == .init(x: 20, y: 10, width: 180, height: 80),
      "a drag is an area; the card before it closes with its note kept (trimmed)")
check(overlay.editing == overlay.marks.at(1)?.id && overlay.draft == "" && overlay.marks.at(1)?.number == 2, "the new one's card opens empty")
check(overlay.handle(.undo) == nil && overlay.marks.count == 1 && overlay.editing == nil, "Ctrl+Z on a mark just made, nothing typed: it goes")
_ = overlay.handle(.pointer(screen: 0, from: at(5, 5), to: at(5, 5), app: nil))
_ = overlay.handle(.draft("words"))
_ = overlay.handle(.undo)
check(overlay.marks.count == 2 && overlay.draft == "words", "Ctrl+Z with words in the card: the mark stays")
check(overlay.handle(.escape) == nil && overlay.marks.count == 2 && overlay.draft == "" && overlay.editing != nil, "Esc with words: clears them")
check(overlay.handle(.escape) == nil && overlay.marks.count == 1 && overlay.editing == nil, "Esc on an empty card: drops its mark")
_ = overlay.handle(.pointer(screen: 0, from: at(1, 1), to: at(1, 1), app: nil))
_ = overlay.handle(.draft("second"))
_ = overlay.handle(.pointer(screen: 0, from: at(2, 2), to: at(2, 2), app: nil))
_ = overlay.handle(.draft("third"))
_ = overlay.handle(.escape)
_ = overlay.handle(.escape)
check(overlay.editing == nil && overlay.marks.map(\.number) == [1, 2], "numbers stay in a row")
_ = overlay.handle(.undo)
check(overlay.marks.map(\.comment) == ["first note"], "Ctrl+Z with no card: the last mark goes")

_ = overlay.handle(.nextDestination)
check(overlay.destination == "c", "Tab: the next session")
_ = overlay.handle(.nextDestination)
check(overlay.destination == "a", "and round again")
_ = overlay.handle(.previousDestination)
check(overlay.destination == "c", "Shift+Tab: the one before")
_ = overlay.handle(.destination(4))
check(overlay.destination == "c", "Ctrl+4 with three sessions: nothing")
_ = overlay.handle(.destination(1))
check(overlay.destination == "a", "Ctrl+1: the first")

_ = overlay.handle(.pointer(screen: 0, from: at(7, 7), to: at(7, 7), app: nil))
_ = overlay.handle(.draft(" last "))
let sendEffect = overlay.handle(.send)
check(sendEffect == .send(overlay.marks, destination: "a") && overlay.marks.map(\.comment) == ["first note", "last"],
      "Ctrl+Enter closes the card and sends the queue to the destination")
check(overlay.sending && overlay.editing == nil, "sending")
check(overlay.handle(.send) == nil, "Ctrl+Enter twice: sent once")
check(overlay.handle(.escape) == nil && overlay.sending, "Esc mid-send: ignored")
_ = overlay.handle(.pointer(screen: 0, from: at(9, 9), to: at(9, 9), app: nil))
_ = overlay.handle(.undo)
check(overlay.marks.count == 2, "no mark made nor undone mid-send")
let keptMark = overlay.marks.at(1)?.id ?? UUID()
check(overlay.handle(.sendFinished(failed: [keptMark], warning: nil)) == nil && overlay.marks.map(\.id) == [keptMark]
      && overlay.marks.at(0)?.number == 1 && !overlay.sending, "a mark that couldn't be saved stays in the queue, numbered again")
check(overlay.warning == "1 mark couldn't be saved: it's still here to send again.", "and the overlay says so")
_ = overlay.handle(.send)
check(overlay.handle(.sendFinished(failed: [], warning: nil)) == .close, "all sent: the overlay closes")

var heldOverlay = Overlay(sessions: [sessionA])
_ = heldOverlay.handle(.pointer(screen: 0, from: at(1, 1), to: at(1, 1), app: nil))
_ = heldOverlay.handle(.send)
check(heldOverlay.handle(.sendFinished(failed: [], warning: "A is asking you something")) == nil && heldOverlay.marks.isEmpty
      && heldOverlay.warning == "A is asking you something", "held: saved marks leave the queue, the overlay stays to say why")
check(heldOverlay.handle(.escape) == .close, "Esc with no card: leaves")

var emptyOverlay = Overlay(sessions: [sessionA])
check(emptyOverlay.handle(.send) == .close, "Ctrl+Enter with an empty queue closes, as on the Mac")
var lonely = Overlay(sessions: [])
_ = lonely.handle(.pointer(screen: 0, from: at(1, 1), to: at(1, 1), app: nil))
check(lonely.handle(.send) == nil && !lonely.sending && lonely.warning == "No agent session to send to: open one and mark again.",
      "zero sessions: not sent, and why")
var late = Overlay(sessions: [])
_ = late.handle(.sessionsChanged([sessionA, sessionB]))
check(late.destination == "a", "the first sessions arriving with nothing marked: the first is the destination (as updateTerminals)")
var lateMarked = Overlay(sessions: [])
_ = lateMarked.handle(.pointer(screen: 0, from: at(1, 1), to: at(1, 1), app: nil))
_ = lateMarked.handle(.sessionsChanged([sessionA]))
check(lateMarked.destination == nil && lateMarked.handle(.send) == nil && lateMarked.warning == "Choose a session with Tab.",
      "marks made with no session and none chosen: not sent, and why")
var orphan = Overlay(sessions: [sessionA, sessionB])
_ = orphan.handle(.pointer(screen: 0, from: at(1, 1), to: at(1, 1), app: nil))
_ = orphan.handle(.sessionsChanged([sessionA]))
check(orphan.destination == "b" && orphan.handle(.send) == nil && !orphan.sending
      && orphan.warning == "B closed: choose another session with Tab.", "the destination gone from the list: not sent, and why")
_ = orphan.handle(.nextDestination)
check(orphan.destination == "a" && orphan.warning == nil, "choosing again clears the warning")

print("linux marking: GNOME shortcut")
struct FakeGSettingsTimeout: GSettingsRunner {
    func run(_ arguments: [String]) -> Command.Outcome { .timedOut }
}
final class FakeGSettings: GSettingsRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    let list: String
    let failing: String?
    init(list: String, failing: String? = nil) {
        self.list = list
        self.failing = failing
    }
    var ran: [[String]] { lock.withLock { calls } }
    var writes: [[String]] { ran.filter { $0.first != "get" } }
    func run(_ arguments: [String]) -> Command.Outcome {
        lock.withLock { calls.append(arguments) }
        if let failing, arguments.contains(failing) { return .exited(status: 1, output: Data()) }
        return .exited(status: 0, output: Data((arguments.first == "get" ? list + "\n" : "").utf8))
    }
}
let mediaKeys = "org.gnome.settings-daemon.plugins.media-keys"
let akiKey = "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/aki/"
let custom0 = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
let custom1 = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1/"
// Expected values worked out with GLib itself (python3-gi: g_shell_parse_argv, GVariant.parse).
let oddAki = #"/home/u/my dir/it's "q"/aki"#
check(GnomeShortcut.command(executable: oddAki) == #"'/home/u/my dir/it'\''s "q"/aki' mark"#, "the command: the path quoted for g_shell_parse_argv, then mark")
check(GnomeShortcut.gvariantString(GnomeShortcut.command(executable: oddAki)) == #"'\'/home/u/my dir/it\'\\\'\'s "q"/aki\' mark'"#,
      "then as a GVariant string")
check(GnomeShortcut.parseList("@as []") == [] && GnomeShortcut.parseList("[]") == [], "an empty list, typed or not")
check(GnomeShortcut.parseList("['\(custom0)', '\(custom1)']") == [custom0, custom1], "a list with others")
check(GnomeShortcut.parseList(#"['/a/', "/b'/", '/c\'d/']"#) == ["/a/", "/b'/", "/c'd/"], "quoted either way, escapes read")
check(GnomeShortcut.parseList("['/a/'") == nil && GnomeShortcut.parseList("nonsense") == nil && GnomeShortcut.parseList("['/a/' '/b/']") == nil,
      "anything strange: nil")
check(GnomeShortcut.formatList([]) == "@as []" && GnomeShortcut.formatList(["/a/", "/b'/"]) == #"['/a/', '/b\'/']"#, "the list written back")

let freshGS = FakeGSettings(list: "@as []")
let freshInstall = GnomeShortcut.install(executable: "/usr/local/bin/aki", runner: freshGS)
check(freshInstall.ok && freshInstall.warning == nil && freshGS.writes == [
    ["set", akiKey, "name", "'Aki'"],
    ["set", akiKey, "command", "'\\'/usr/local/bin/aki\\' mark'"],
    ["set", akiKey, "binding", "'<Shift><Super>a'"],
    ["set", mediaKeys, "custom-keybindings", "['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/aki/']"],
], "install on an empty list: the three keys, then the path in the list")
check(freshGS.ran.first == ["get", mediaKeys, "custom-keybindings"], "the list read first")
let othersGS = FakeGSettings(list: "['\(custom0)', '\(custom1)']")
_ = GnomeShortcut.install(executable: "/usr/local/bin/aki", runner: othersGS)
check(othersGS.writes.last == ["set", mediaKeys, "custom-keybindings", "['\(custom0)', '\(custom1)', '\(GnomeShortcut.path)']"],
      "the shortcuts already there stay")
let againGS = FakeGSettings(list: "['\(custom0)', '\(GnomeShortcut.path)']")
let again = GnomeShortcut.install(executable: "/usr/local/bin/aki", runner: againGS)
check(again.ok && againGS.writes.count == 3 && !againGS.writes.contains { $0.contains("custom-keybindings") }, "installed already: the keys renewed, the list untouched")
let buildGS = FakeGSettings(list: "@as []")
let fromBuild = GnomeShortcut.install(executable: "/home/u/aki/.build/debug/aki", runner: buildGS)
check(fromBuild.ok && fromBuild.warning == "This aki is inside .build: the shortcut breaks if that build goes away.", "from a build folder: installed, with a warning")
let strangeGS = FakeGSettings(list: "{'what': 1}")
check(!GnomeShortcut.install(executable: "/usr/local/bin/aki", runner: strangeGS).ok && strangeGS.writes.isEmpty, "a list it can't read: nothing written")
let failingGS = FakeGSettings(list: "@as []", failing: "binding")
let failedInstall = GnomeShortcut.install(executable: "/usr/local/bin/aki", runner: failingGS)
check(!failedInstall.ok && !failingGS.writes.contains { $0.contains("custom-keybindings") }, "a key that can't be written: the list isn't touched")

let removeGS = FakeGSettings(list: "['\(custom0)', '\(GnomeShortcut.path)', '\(custom1)']")
let removed = GnomeShortcut.remove(runner: removeGS)
check(removed.ok && removeGS.writes == [
    ["set", mediaKeys, "custom-keybindings", "['\(custom0)', '\(custom1)']"],
    ["reset", akiKey, "name"], ["reset", akiKey, "command"], ["reset", akiKey, "binding"],
], "remove: out of the list first, then its keys reset; the others stay")
let removeLastGS = FakeGSettings(list: "['\(GnomeShortcut.path)']")
_ = GnomeShortcut.remove(runner: removeLastGS)
check(removeLastGS.writes.first == ["set", mediaKeys, "custom-keybindings", "@as []"], "the last one out: an empty list")
let notThereGS = FakeGSettings(list: "['\(custom0)']")
let notThere = GnomeShortcut.remove(runner: notThereGS)
check(notThere.ok && notThereGS.writes.count == 3 && notThereGS.writes.allSatisfy { $0.first == "reset" }, "remove when it isn't there: only the keys reset")
let slowGS = FakeGSettingsTimeout()
check(!GnomeShortcut.install(executable: "/usr/local/bin/aki", runner: slowGS).ok
      && GnomeShortcut.install(executable: "/usr/local/bin/aki", runner: slowGS).message == "gsettings didn't answer in time.", "gsettings not answering: fails, says so")
_ = FileManager.default.createFile(atPath: orcaBin.appending(path: "gsettings").path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
check(GnomeShortcut.gsettings(path: "/nonexistent") == nil && GnomeShortcut.gsettings(path: "/nonexistent:" + orcaBin.path) == orcaBin.appending(path: "gsettings").path,
      "gsettings found on PATH")

print("linux marking: Enter, root and monitors, window names, dry sessions")
var entering = Overlay(sessions: [sessionA])
_ = entering.handle(.pointer(screen: 0, from: at(10, 10), to: at(80, 60), app: nil))
_ = entering.handle(.draft("  queue me "))
check(entering.handle(.commit) == nil && entering.editing == nil && entering.marks.at(0)?.comment == "queue me" && !entering.sending,
      "Enter with a note: it goes to the queue, nothing sent")
let enterSends = entering.handle(.commit)
check(enterSends == .send(entering.marks, destination: "a") && entering.sending, "Enter with no card open: sends the queue")
var enterEmpty = Overlay(sessions: [sessionA])
_ = enterEmpty.handle(.pointer(screen: 0, from: at(10, 10), to: at(10, 10), app: nil))
_ = enterEmpty.handle(.draft("   "))
check(enterEmpty.handle(.commit) == .send(enterEmpty.marks, destination: "a") && enterEmpty.marks.at(0)?.comment == "",
      "Enter on a card with an empty (blank) note: sends, the mark with it")

// This machine's monitors, in GDK's order (not left to right): eDP-1 on the right, HDMI-1-0 on the left.
let eDP = LinuxMarking.Monitor(x: 1920, y: 0, width: 1920, height: 1080)
let hdmi = LinuxMarking.Monitor(x: 0, y: 0, width: 1920, height: 1080)
let monitors = [eDP, hdmi]
check(LinuxMarking.monitor(containing: at(2500, 300), in: monitors) == 0 && LinuxMarking.monitor(containing: at(100, 900), in: monitors) == 1,
      "a root point's monitor is its place in GDK's list, not left to right")
check(LinuxMarking.monitor(containing: at(1920, 0), in: monitors) == 0 && LinuxMarking.monitor(containing: at(1919.5, 0), in: monitors) == 1,
      "on the edge between them: the one it starts (right edge excluded)")
check(LinuxMarking.monitor(containing: at(4000, 10), in: monitors) == nil && LinuxMarking.monitor(containing: at(10, 1080), in: monitors) == nil,
      "outside every monitor: none")
check(LinuxMarking.rootRect(of: .init(x: 100, y: 50, width: 300, height: 200), on: eDP) == .init(x: 2020, y: 50, width: 300, height: 200)
      && LinuxMarking.rootRect(of: .init(x: 100, y: 50, width: 0, height: 0), on: hdmi) == .init(x: 100, y: 50, width: 0, height: 0),
      "a mark's local rect back in root pixels, for the crop")
let hidpi = LinuxMarking.Monitor(x: 1280, y: 0, width: 1280, height: 720, scale: 2)
check(LinuxMarking.devicePoint(at(10, 20.5), on: hidpi) == at(20, 41) && LinuxMarking.devicePoint(at(10, 20), on: eDP) == at(10, 20),
      "a window point in device pixels: times the scale")
check(LinuxMarking.rootRect(of: .init(x: 20, y: 40, width: 100, height: 60), on: hidpi) == .init(x: 2580, y: 40, width: 100, height: 60),
      "scale 2: the monitor's origin in device pixels too")
check(LinuxMarking.devicePoint(at(-30, 1200), on: eDP) == at(0, 1079) && LinuxMarking.devicePoint(at(5000, -1), on: hidpi) == at(2559, 0),
      "a drag that leaves its monitor stops at its edge (a mark never spans two)")
check(LinuxMarking.devicePixels(of: hidpi) == .init(width: 2560, height: 1440) && LinuxMarking.devicePixels(of: hdmi) == .init(width: 1920, height: 1080),
      "a monitor's size in the capture's pixels")

check(LinuxMarking.windowClass(fromWMClass: Array("google-chrome\0Google-chrome\0".utf8)) == "Google-chrome", "WM_CLASS: the class, not the instance")
check(LinuxMarking.windowClass(fromWMClass: Array("xterm\0XTerm".utf8)) == "XTerm", "WM_CLASS without its last NUL")
check(LinuxMarking.windowClass(fromWMClass: Array("solo\0".utf8)) == "solo" && LinuxMarking.windowClass(fromWMClass: []) == nil
      && LinuxMarking.windowClass(fromWMClass: Array("\0\0".utf8)) == nil, "only an instance: that; nothing: none")
check(LinuxMarking.windowTitle(fromProperty: Array("Inbox — Mozilla Firefox".utf8)) == "Inbox — Mozilla Firefox", "_NET_WM_NAME is UTF-8")
check(LinuxMarking.windowTitle(fromProperty: Array("title\0".utf8)) == "title" && LinuxMarking.windowTitle(fromProperty: []) == nil
      && LinuxMarking.windowTitle(fromProperty: [0x61, 0xFF, 0x62]) == "a\u{FFFD}b", "a trailing NUL dropped, empty is none, bad bytes replaced")

let fakeSessionsHome = AkiHome(url: temp.appending(path: "dry-sessions-home"))
try FileManager.default.createDirectory(at: fakeSessionsHome.url, withIntermediateDirectories: true)
try Data(#"[{"id":"s1","name":"SITE","worktree":"/w/site","orcaHandle":"term_x","state":"waiting","agent":"codex","lastSent":20},{"id":"s2","name":"API","worktree":"/w/api"}]"#.utf8)
    .write(to: fakeSessionsHome.url.appending(path: "dry-sessions.json"))
let realOne = [LinuxMarking.terminal(id: "real", name: "REAL", worktree: "/real")]
let fakeSessions = LinuxMarking.sessions(environment: ["AKI_DRY_DELIVER": "1"], home: fakeSessionsHome) { realOne }
check(fakeSessions == [
    LinuxMarking.terminal(id: "s1", agent: .codex, name: "SITE", worktree: "/w/site", state: .waiting, orcaHandle: "term_x", lastSent: Date(timeIntervalSince1970: 20)),
    LinuxMarking.terminal(id: "s2", name: "API", worktree: "/w/api"),
], "dry: the sessions come from $AKI_HOME/dry-sessions.json, never the real ones")
check(LinuxMarking.sessions(environment: [:], home: fakeSessionsHome) { realOne } == realOne, "not dry: that file is ignored, the real listing")
try Data("[]".utf8).write(to: fakeSessionsHome.url.appending(path: "dry-sessions.json"))
check(LinuxMarking.sessions(environment: ["AKI_DRY_DELIVER": "1"], home: fakeSessionsHome) { realOne }.isEmpty, "dry with an empty list: zero sessions")
try Data("{nope".utf8).write(to: fakeSessionsHome.url.appending(path: "dry-sessions.json"))
check(LinuxMarking.sessions(environment: ["AKI_DRY_DELIVER": "1"], home: fakeSessionsHome) { realOne }.isEmpty
      && LinuxMarking.sessions(environment: ["AKI_DRY_DELIVER": "1"], home: AkiHome(url: temp.appending(path: "none"))) { realOne }.isEmpty,
      "dry with no file or a broken one: zero sessions, still not the real ones")

check(LinuxMarking.sibling("aki-mark", of: "/home/u/.local/bin/aki") == "/home/u/.local/bin/aki-mark"
      && LinuxMarking.sibling("aki", of: "/opt/aki dir/aki-mark") == "/opt/aki dir/aki", "aki and aki-mark find each other in the same folder")

print("linux marking: text read under an area (OCR)")
var textMark = LinuxMarking.PortableMark(screen: 0, rect: .init(x: 10, y: 20, width: 300, height: 40), number: 1, selectedText: "Save changes\nCancel")
check(LinuxMarking.fields(of: textMark, id: "aki_1_t", batch: "batch_1", terminal: plainSession, imagePath: "/h/t.jpg")["selected_text"] == "Save changes\nCancel",
      "the text read under an area goes in selected_text")
textMark.selectedText = String(repeating: "é", count: 4100)
check(LinuxMarking.fields(of: textMark, id: "aki_1_t", batch: "batch_1", terminal: plainSession, imagePath: "/h/t.jpg")["selected_text"]
      == .string(String(repeating: "é", count: 4000)), "cut at 4000 characters, as the Mac")
textMark.selectedText = ""
check(LinuxMarking.fields(of: textMark, id: "aki_1_t", batch: "batch_1", terminal: plainSession, imagePath: "/h/t.jpg")["selected_text"] == nil
      && LinuxMarking.fields(of: areaMark, id: "aki_1_a", batch: "batch_1", terminal: orcaSession, imagePath: "/h/crop.jpg")["selected_text"] == nil,
      "no text, or empty: no selected_text")

typealias OCR = LinuxMarking.OCR
let listLangs = "List of available languages in \"/usr/share/tesseract-ocr/5/tessdata/\" (3):\neng\nosd\npor\n"
check(OCR.languages(fromListLangs: listLangs) == ["por", "eng"], "languages: Portuguese and English when installed, never osd")
check(OCR.languages(fromListLangs: "List of available languages in \"/x/\" (2):\neng\nosd\n") == ["eng"], "only English: that")
check(OCR.languages(fromListLangs: "List of available languages in \"/por/eng/\" (1):\nosd\n").isEmpty && OCR.languages(fromListLangs: "").isEmpty,
      "neither (the heading's path doesn't count): none, no OCR")

check(OCR.arguments(image: "/run/a.ppm", outputBase: "/run/a", languages: ["por", "eng"]) == ["/run/a.ppm", "/run/a", "-l", "por+eng", "--dpi", "300", "tsv"]
      && OCR.arguments(image: "i", outputBase: "o", languages: ["eng"]) == ["i", "o", "-l", "eng", "--dpi", "300", "tsv"],
      "tesseract's arguments: the image, the output's base, the languages, 300 dpi, TSV")
check(OCR.scale(for: .init(width: 324, height: 64)) == 3 && OCR.scale(for: .init(width: 500, height: 555)) == 3,
      "a small crop: 3x (500x555 at 3x is 2.497 MP)")
check(OCR.scale(for: .init(width: 500, height: 556)) == 2 && OCR.scale(for: .init(width: 790, height: 790)) == 2, "too big for 3x: 2x")
check(OCR.scale(for: .init(width: 791, height: 791)) == 1 && OCR.scale(for: .init(width: 1944, height: 1104)) == 1, "too big for 2x: as it is")

let twoPixels: [UInt8] = [1, 2, 3, 4, 5, 6]
check(OCR.ppm(rgb: twoPixels, size: .init(width: 2, height: 1), scale: 2) == Data("P6\n4 2\n255\n".utf8) + Data([1, 2, 3, 1, 2, 3, 4, 5, 6, 4, 5, 6, 1, 2, 3, 1, 2, 3, 4, 5, 6, 4, 5, 6]),
      "the crop as a P6 PPM, each pixel a 2x2 block")
check(OCR.ppm(rgb: twoPixels, size: .init(width: 1, height: 2), scale: 1) == Data("P6\n1 2\n255\n".utf8) + Data(twoPixels), "scale 1: as it is")
check(OCR.ppm(rgb: twoPixels, size: .init(width: 3, height: 1), scale: 1) == nil && OCR.ppm(rgb: [], size: .init(width: 0, height: 0), scale: 3) == nil
      && OCR.ppm(rgb: twoPixels, size: .init(width: 2, height: 1), scale: 0) == nil, "bytes that aren't the size's, nothing, or no scale: none")

let rightMonitor = LinuxMarking.Monitor(x: 1920, y: 0, width: 1920, height: 1080)
let cornerMark = LinuxMarking.PortableMark(screen: 0, rect: .init(x: 0, y: 0, width: 100, height: 20), number: 1)
check(OCR.region(for: cornerMark, on: rightMonitor) == .init(local: .init(x: 0, y: 0, width: 112, height: 32), root: .init(x: 1920, y: 0, width: 112, height: 32), scale: 3),
      "an area in the corner of a monitor at x=1920: its crop held to the monitor, moved to the root only for the pixels")
let hidpiMonitor = LinuxMarking.Monitor(x: 1280, y: 0, width: 1280, height: 720, scale: 2)
check(OCR.region(for: .init(screen: 0, rect: .init(x: 100, y: 50, width: 1000, height: 500), number: 1), on: hidpiMonitor)
      == .init(local: .init(x: 88, y: 38, width: 1024, height: 524), root: .init(x: 2648, y: 38, width: 1024, height: 524), scale: 2),
      "scale 2 monitor: the root in device pixels; a big crop: 2x")
check(OCR.region(for: .init(screen: 0, rect: .init(x: 5, y: 5, width: 0, height: 0), number: 1), on: rightMonitor) == nil
      && OCR.region(for: .init(screen: 0, rect: .init(x: 4000, y: 5, width: 50, height: 50), number: 1), on: rightMonitor) == nil,
      "a point reads nothing; an area off its monitor neither")

// tesseract 5.3.4's TSV (levels 1-4 end in a tab, conf -1, no text), for a mark at
// (100, 200) 300x40: its crop starts at (88, 188), read at 3x. Block 1 is the lower line.
let tsvHeader = "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n"
let tsvRegion = OCR.Region(local: .init(x: 88, y: 188, width: 324, height: 64), root: .init(x: 88, y: 188, width: 324, height: 64), scale: 3)
let tsvRect = LinuxMarking.Rect(x: 100, y: 200, width: 300, height: 40)
let tsv = tsvHeader + """
1\t1\t0\t0\t0\t0\t0\t0\t972\t192\t-1\t
2\t1\t1\t0\t0\t0\t60\t90\t400\t30\t-1\t
3\t1\t1\t1\t0\t0\t60\t90\t400\t30\t-1\t
4\t1\t1\t1\t1\t0\t60\t90\t400\t30\t-1\t
5\t1\t1\t1\t1\t1\t60\t90\t110\t30\t96.87\tCancel
5\t1\t1\t1\t1\t2\t180\t90\t30\t30\t-1\t~
5\t1\t1\t1\t1\t3\t220\t90\t60\t30\t95.06\tthe
5\t1\t1\t1\t1\t4\t290\t90\t120\t30\t1.22\torder
2\t1\t2\t0\t0\t0\t60\t45\t230\t30\t-1\t
4\t1\t2\t1\t1\t0\t60\t45\t230\t30\t-1\t
5\t1\t2\t1\t1\t1\t60\t45\t90\t30\t84.6\tSave
5\t1\t2\t1\t1\t2\t160\t45\t130\t30\t69.6\tchanges
4\t1\t3\t1\t1\t0\t60\t150\t200\t30\t-1\t
5\t1\t3\t1\t1\t1\t60\t150\t200\t30\t91.0\tcut
4\t1\t4\t1\t1\t0\t300\t10\t30\t30\t-1\t
5\t1\t4\t1\t1\t1\t300\t10\t30\t30\t-1\t
5\t1\t4\t1\t1\t2\t340\t10
"""
check(OCR.text(fromTSV: tsv, region: tsvRegion, in: tsvRect) == "Save changes\nCancel the order",
      "TSV: words joined per line, lines top to bottom whatever the block order; conf -1 dropped; the line cut at the edge (its middle outside) left out")
let sideBySide = tsvHeader + """
5\t1\t1\t1\t1\t1\t200\t66\t60\t30\t90\tRight
5\t1\t2\t1\t1\t1\t60\t60\t60\t30\t90\tLeft
"""
check(OCR.text(fromTSV: sideBySide, region: tsvRegion, in: tsvRect) == "Left\nRight", "lines within 4 px of the same top: left to right, as the Mac")
check(OCR.text(fromTSV: "", region: tsvRegion, in: tsvRect) == nil && OCR.text(fromTSV: tsvHeader, region: tsvRegion, in: tsvRect) == nil
      && OCR.text(fromTSV: tsvHeader + "5\t1\t1\t1\t1\t1\t60\t45\t90\t30\t80\t   \n", region: tsvRegion, in: tsvRect) == nil,
      "nothing read, only the header, or only blanks: no text")
check(OCR.text(fromTSV: tsvHeader + "5\t1\t1\t1\t1\t1\t60\t45\t90\t30\t80\t\(String(repeating: "x", count: 5000))\n", region: tsvRegion, in: tsvRect)?.count == 4000,
      "a huge read: cut at 4000")
let cornerRegion = OCR.region(for: cornerMark, on: rightMonitor)!
check(OCR.text(fromTSV: tsvHeader + "5\t1\t1\t1\t1\t1\t6\t6\t120\t30\t90\tFile\n5\t1\t2\t1\t1\t1\t310\t6\t30\t30\t90\tEdge\n", region: cornerRegion, in: cornerMark.rect) == "File",
      "a mark at (0, 0) on the monitor at x=1920: lines placed in the monitor's own pixels (one past the mark's right edge out)")

// A stand-in tesseract (the CI has none): it says how it was called and writes its TSV.
let ocrHome = temp.appending(path: "ocr")
let ocrRun = ocrHome.appending(path: "run")
try FileManager.default.createDirectory(at: ocrRun, withIntermediateDirectories: true)
func fakeTesseract(_ name: String, _ body: String) -> String {
    let path = ocrHome.appending(path: name).path
    _ = FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n\(body)\n".utf8), attributes: [.posixPermissions: 0o755])
    return path
}
let calls = ocrHome.appending(path: "calls").path
try Data((tsvHeader + "5\t1\t1\t1\t1\t1\t60\t45\t90\t30\t84.6\tSave\n").utf8).write(to: ocrHome.appending(path: "canned.tsv"))
let goodTesseract = fakeTesseract("good", "echo \"$@\" > '\(calls)'; stat -c %a \"$1\" >> '\(calls)'; head -c 2 \"$1\" >> '\(calls)'; cp '\(ocrHome.appending(path: "canned.tsv").path)' \"$2.tsv\"")
let tsvRGB = [UInt8](repeating: 255, count: 324 * 64 * 3)
let readOK = OCR.read(rgb: tsvRGB, region: tsvRegion, in: tsvRect, tesseract: goodTesseract, languages: ["por", "eng"], directory: ocrRun)
check(readOK == .success("Save"), "a read: tesseract's TSV, the text under the mark")
let called = (try? String(contentsOfFile: calls, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
check(called.at(0)?.hasSuffix(" -l por+eng --dpi 300 tsv") == true && called.at(0)?.hasPrefix(ocrRun.path + "/aki-ocr-\(getpid())-") == true
      && called.at(1) == "600" && called.at(2) == "P6", "the crop goes as a private (0600) PPM named aki-ocr-<pid>-…, in the folder given")
check((try? FileManager.default.contentsOfDirectory(atPath: ocrRun.path))?.isEmpty == true, "and neither it nor the TSV is left")
let failingTesseract = fakeTesseract("failing", "echo boom > \"$2.tsv\"; exit 1")
check(OCR.read(rgb: tsvRGB, region: tsvRegion, in: tsvRect, tesseract: failingTesseract, languages: ["eng"], directory: ocrRun) == .failure(.failed)
      && (try? FileManager.default.contentsOfDirectory(atPath: ocrRun.path))?.isEmpty == true, "tesseract failing: no text, nothing left")
let slowTesseract = fakeTesseract("slow", "exec sleep 10")
let slowStart = Date()
check(OCR.read(rgb: tsvRGB, region: tsvRegion, in: tsvRect, tesseract: slowTesseract, languages: ["eng"], directory: ocrRun, timeout: 0.5) == .failure(.failed)
      && Date().timeIntervalSince(slowStart) < 3 && (try? FileManager.default.contentsOfDirectory(atPath: ocrRun.path))?.isEmpty == true,
      "tesseract not ending in time: stopped, no text, nothing left")
let silentTesseract = fakeTesseract("silent", "rm -f \"$2.tsv\"; exit 0")
check(OCR.read(rgb: tsvRGB, region: tsvRegion, in: tsvRect, tesseract: silentTesseract, languages: ["eng"], directory: ocrRun) == .failure(.noOutput),
      "tesseract writing nothing: no text")
let emptyTesseract = fakeTesseract("empty", "printf '' > \"$2.tsv\"")
check(OCR.read(rgb: tsvRGB, region: tsvRegion, in: tsvRect, tesseract: emptyTesseract, languages: ["eng"], directory: ocrRun) == .success(nil),
      "an area with no words: read, no text")
check(OCR.read(rgb: tsvRGB, region: tsvRegion, in: tsvRect, tesseract: goodTesseract, languages: [], directory: ocrRun) == .failure(.noLanguages)
      && OCR.read(rgb: [1, 2], region: tsvRegion, in: tsvRect, tesseract: goodTesseract, languages: ["eng"], directory: ocrRun) == .failure(.badImage)
      && OCR.read(rgb: tsvRGB, region: tsvRegion, in: tsvRect, tesseract: goodTesseract, languages: ["eng"], directory: ocrHome.appending(path: "nope")) == .failure(.couldNotWrite),
      "no language, pixels that don't fit, or a folder that isn't there: no text, tesseract not run")
check(OCR.temporaryDirectory(environment: ["XDG_RUNTIME_DIR": ocrRun.path]).path == ocrRun.path
      && OCR.temporaryDirectory(environment: ["XDG_RUNTIME_DIR": "/nonexistent-aki"]).path == FileManager.default.temporaryDirectory.path
      && OCR.temporaryDirectory(environment: [:]).path == FileManager.default.temporaryDirectory.path, "crops go to XDG_RUNTIME_DIR when it's there, else the temporary folder")
for (name, age) in [("aki-ocr-1-a.ppm", 3600.0), ("aki-ocr-1-a.tsv", 3600), ("aki-ocr-2-b.ppm", 0), ("other.ppm", 3600)] {
    let path = ocrRun.appending(path: name).path
    _ = FileManager.default.createFile(atPath: path, contents: Data())
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path)
}
OCR.removeStale(in: ocrRun, before: Date().addingTimeInterval(-60))
check(Set((try? FileManager.default.contentsOfDirectory(atPath: ocrRun.path)) ?? []) == ["aki-ocr-2-b.ppm", "other.ppm"],
      "at start, old crops of ours are removed; a fresh one (another read) and anything else stay")

print("linux marking: overlay waiting for the text")
var reading = Overlay(sessions: [sessionA], readsText: true)
let readArea = reading.handle(.pointer(screen: 0, from: at(10, 10), to: at(80, 60), app: nil))
check(readArea == .enrich(reading.marks[0]) && reading.isPending(reading.marks[0].id), "reading text: an area drawn asks for its words, and waits for them")
check(reading.handle(.pointer(screen: 0, from: at(5, 5), to: at(5, 5), app: nil)) == nil && !reading.isPending(reading.marks[1].id),
      "a point reads nothing (as on the Mac)")
var notReading = Overlay(sessions: [sessionA])
check(notReading.handle(.pointer(screen: 0, from: at(10, 10), to: at(80, 60), app: nil)) == nil && !notReading.isPending(notReading.marks[0].id),
      "no tesseract: nothing asked, nothing waited for")

let readID = reading.marks[0].id
check(reading.handle(.enriched(id: readID, .init(text: "Save changes"))) == nil && reading.marks[0].selectedText == "Save changes" && !reading.isPending(readID),
      "the words arrive: on the mark, no longer waited for")
check(reading.handle(.enriched(id: readID, .init(text: "again"))) == nil && reading.marks[0].selectedText == "Save changes",
      "a second answer for a mark not waited for: ignored")
var undone = Overlay(sessions: [sessionA], readsText: true)
_ = undone.handle(.pointer(screen: 0, from: at(10, 10), to: at(80, 60), app: nil))
let undoneID = undone.marks[0].id
_ = undone.handle(.undo)
_ = undone.handle(.pointer(screen: 0, from: at(10, 10), to: at(80, 60), app: nil))
check(undone.handle(.enriched(id: undoneID, .init(text: "late"))) == nil && !undone.isPending(undoneID) && undone.marks.allSatisfy { $0.selectedText == nil },
      "the words of a mark undone arrive late: ignored")
let escapedID = undone.marks[0].id
_ = undone.handle(.escape)
check(undone.marks.isEmpty && !undone.isPending(escapedID) && undone.handle(.enriched(id: escapedID, .init(text: "x"))) == nil && undone.marks.isEmpty,
      "Esc on its card: the same")

func waitToken(_ effect: Overlay.Effect?) -> Int? {
    if case let .wait(token)? = effect { return token }
    return nil
}
var waiting = Overlay(sessions: [sessionA, sessionB], readsText: true)
_ = waiting.handle(.pointer(screen: 0, from: at(10, 10), to: at(80, 60), app: nil))
_ = waiting.handle(.draft("rename it"))
let waitingID = waiting.marks[0].id
let firstToken = waitToken(waiting.handle(.send))
check(firstToken != nil && waiting.sending && waiting.waitingForReads && waiting.marks[0].comment == "rename it" && waiting.destination == "b",
      "Ctrl+Enter with a read going: the card closes, the send waits for it")
check(waiting.handle(.send) == nil && waiting.handle(.commit) == nil && waiting.handle(.escape) == nil && waiting.sending, "Ctrl+Enter twice, Enter and Esc while waiting: ignored")
_ = waiting.handle(.nextDestination)
_ = waiting.handle(.previousDestination)
_ = waiting.handle(.destination(1))
check(waiting.destination == "b", "Tab, Shift+Tab and Ctrl+1 while waiting: ignored, it goes where Ctrl+Enter said")
let waitSend = waiting.handle(.enriched(id: waitingID, .init(text: "Old name")))
check(waitSend == .send(waiting.marks, destination: "b") && waiting.marks[0].selectedText == "Old name" && !waiting.waitingForReads && waiting.sending,
      "the last read arrives: sent at once, with its words")
check(waiting.handle(.deadline(firstToken ?? -1)) == nil, "the wait's time then up: nothing sent twice")
check(waiting.handle(.sendFinished(failed: [], warning: nil)) == .close, "and it closes once saved")

var slowRead = Overlay(sessions: [sessionA], readsText: true)
_ = slowRead.handle(.pointer(screen: 0, from: at(10, 10), to: at(80, 60), app: nil))
_ = slowRead.handle(.pointer(screen: 0, from: at(100, 100), to: at(180, 160), app: nil))
let slowIDs = slowRead.marks.map(\.id)
_ = slowRead.handle(.enriched(id: slowIDs[1], .init(text: "second")))
let slowToken = waitToken(slowRead.handle(.send)) ?? -1
check(slowToken >= 0 && slowRead.handle(.deadline(slowToken + 1)) == nil && slowRead.waitingForReads, "another wait's time: ignored")
let deadlineSend = slowRead.handle(.deadline(slowToken))
check(deadlineSend == .send(slowRead.marks, destination: "a") && slowRead.marks.map(\.selectedText) == [nil, "second"],
      "the time up with a read still going: sent with what was read")
check(slowRead.handle(.enriched(id: slowIDs[0], .init(text: "too late"))) == nil, "its words arriving mid-send: nothing more sent")
_ = slowRead.handle(.sendFinished(failed: [slowIDs[0]], warning: nil))
check(slowRead.marks.map(\.id) == [slowIDs[0]] && !slowRead.isPending(slowIDs[0]), "a mark that couldn't be saved stays, no longer waited for")
check(slowRead.handle(.send) == .send(slowRead.marks, destination: "a"), "sent again: nothing to wait for, at once")

var oldTimer = Overlay(sessions: [sessionA], readsText: true)
_ = oldTimer.handle(.pointer(screen: 0, from: at(10, 10), to: at(80, 60), app: nil))
let oldToken = waitToken(oldTimer.handle(.send))
let failedRead = oldTimer.handle(.enriched(id: oldTimer.marks[0].id, .init(text: nil)))
check(failedRead == .send(oldTimer.marks, destination: "a") && oldTimer.marks[0].selectedText == nil, "a read that failed (no text) frees the wait: sent without words")
_ = oldTimer.handle(.sendFinished(failed: [oldTimer.marks[0].id], warning: nil))
_ = oldTimer.handle(.pointer(screen: 0, from: at(100, 100), to: at(180, 160), app: nil))
let newToken = waitToken(oldTimer.handle(.send))
check(newToken != nil && newToken != oldToken && oldTimer.handle(.deadline(oldToken ?? -1)) == nil && oldTimer.waitingForReads,
      "an old wait's timer never sends a new one")

var warned = Overlay(sessions: [], readsText: true)
_ = warned.handle(.pointer(screen: 0, from: at(10, 10), to: at(80, 60), app: nil))
_ = warned.handle(.send)
_ = warned.handle(.enriched(id: warned.marks[0].id, .init(text: "words")))
check(warned.warning == "No agent session to send to: open one and mark again." && warned.marks[0].selectedText == "words",
      "words arriving while a warning shows: the warning stays")
var heldRead = Overlay(sessions: [sessionA], readsText: true)
_ = heldRead.handle(.pointer(screen: 0, from: at(10, 10), to: at(80, 60), app: nil))
let heldToken = waitToken(heldRead.handle(.send))
_ = heldRead.handle(.enriched(id: heldRead.marks[0].id, .init(text: "words")))
_ = heldRead.handle(.sendFinished(failed: [], warning: "A is asking you something"))
check(heldRead.handle(.deadline(heldToken ?? -1)) == nil && heldRead.warning == "A is asking you something", "the wait's timer firing after: the warning stays")

print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
