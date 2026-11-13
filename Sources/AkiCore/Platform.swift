import Foundation

#if !canImport(ObjectiveC)
/// No Objective-C runtime (Linux): nothing to drain, the work just runs.
@inlinable func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}
#endif
