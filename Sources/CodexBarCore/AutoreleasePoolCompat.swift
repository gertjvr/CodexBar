import Foundation

#if os(Linux) || os(Windows)
@discardableResult
func autoreleasepool<Result>(_ work: () throws -> Result) rethrows -> Result {
    try work()
}
#endif
