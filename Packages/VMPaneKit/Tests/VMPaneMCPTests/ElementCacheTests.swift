import CoreGraphics
import Testing

@testable import VMPaneMCP

private let start = ContinuousClock.now

@Test func idsAreNeverReusedWhileTheyLive() throws {
    var cache = ElementCache()
    let first = cache.add([CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 20, y: 0, width: 10, height: 10)], prefix: "t", now: start)
    let second = cache.add([CGRect(x: 100, y: 100, width: 10, height: 10)], prefix: "t", now: start)
    #expect(first == ["t1", "t2"] && second == ["t3"], "a later read numbers on")
    #expect(
        try cache.rect("t2", now: start).get() == CGRect(x: 20, y: 0, width: 10, height: 10),
        "an earlier read's id still clicks what it saw")
    #expect(throws: ToolFailure.self) { try cache.rect("t4", now: start).get() }
}

@Test func idsExpireAfterAMinute() {
    var cache = ElementCache()
    _ = cache.add([CGRect(x: 0, y: 0, width: 10, height: 10)], prefix: "e", now: start)
    #expect((try? cache.rect("e1", now: start + .seconds(59)).get()) != nil)
    #expect((try? cache.rect("e1", now: start + .seconds(61)).get()) == nil)
}

@Test func aChangeMakesTheIdsThereStale() {
    var cache = ElementCache()
    _ = cache.add([CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 500, y: 500, width: 10, height: 10)], prefix: "t", now: start)
    cache.changed(CGRect(x: 0, y: 0, width: 50, height: 50), ratio: 0.01)  // a small dialog over the first
    #expect((try? cache.rect("t1", now: start).get()) == nil)
    #expect((try? cache.rect("t2", now: start).get()) != nil)
    cache.changed(CGRect(x: 0, y: 0, width: 1, height: 1), ratio: 0.4)  // a new window: all of them
    #expect((try? cache.rect("t2", now: start).get()) == nil)
}
