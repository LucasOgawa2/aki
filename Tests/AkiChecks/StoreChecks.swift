import AkiCore
import Foundation
#if os(Linux)
import Glibc
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

func json(_ response: HTTPResponse) -> [String: JSONValue] {
    (try? JSONDecoder().decode(JSONValue.self, from: response.body))?.object ?? [:]
}

let auth = ["host": "127.0.0.1:3850", "authorization": "Bearer " + String(repeating: "t", count: 64)]

/// Returns the store the session checks go on with.
@MainActor func storeAndAPIChecks() async throws -> AnnotationStore {
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
    return store
}
