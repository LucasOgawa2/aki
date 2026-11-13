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

let store = try await storeAndAPIChecks()
try await serverChecks()
try await sessionChecks(store: store)
try await procChecks()
let orcaBin = try await markingChecks()
try await overlayChecks(orcaBin: orcaBin)

webSocketChecks()
cdpChecks()
pageReaderChecks()
pageReadChecks()

print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
