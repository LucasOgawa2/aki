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

print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
