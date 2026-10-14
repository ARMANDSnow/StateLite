import Foundation

// Run: swiftc Sources/Metrics.swift Tests/MetricsTests.swift -o /tmp/statelite-metrics-tests
//      /tmp/statelite-metrics-tests
@main
struct MetricsTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        func reading(_ time: Double, _ cpu: [UInt64]? = [100, 50, 850, 0],
                     _ network: [String: NetworkCounter]? = ["en0": .init(received: 1000, sent: 500)]) -> MetricsCounters {
            MetricsCounters(time: time, cpu: cpu, network: network)
        }
        let first = reading(10)
        let second = reading(12.5, [150, 75, 1075, 0], ["en0": .init(received: 1500, sent: 750)])
        let empty = MetricsDelta.compute(previous: nil, current: first)
        check(empty.cpuPercent == nil && empty.received == nil && empty.interval == nil, "first sample must not claim a rate")
        let normal = MetricsDelta.compute(previous: first, current: second)
        check(normal.cpuPercent == 25, "CPU must use tick deltas, including idle")
        check(normal.received == 200 && normal.sent == 100, "network must use actual 2.5-second interval")
        check(normal.interval == 2.5, "snapshot exposes measured interval")
        for time in [10.0, 9.0, Double.nan, 200.0] {
            let invalid = MetricsDelta.compute(previous: first, current: reading(time))
            check(invalid.cpuPercent == nil && invalid.received == nil, "invalid/sleep interval resets rates")
        }
        let decrease = MetricsDelta.compute(previous: first, current: reading(12, [1, 1, 1, 1], ["en0": .init(received: 1, sent: 1)]))
        check(decrease.cpuPercent == nil && decrease.received == nil, "counter reset cannot spike")
        let wrap = MetricsDelta.compute(previous: reading(1, nil, ["en0": .init(received: UInt64(UInt32.max)-10, sent: 100)]),
                                        current: reading(2, nil, ["en0": .init(received: 10, sent: 110)]))
        check(wrap.received == nil && wrap.sent == nil, "32-bit wrap is conservatively discarded")
        let change = MetricsDelta.compute(previous: first, current: reading(12, nil, ["en1": .init(received: 100000, sent: 50000)]))
        check(change.received == nil, "interface changes establish a new baseline")
        let zero = MetricsDelta.compute(previous: first, current: reading(12))
        check(zero.cpuPercent == nil && zero.received == 0, "zero CPU ticks unknown, zero traffic valid")
        let missing = MetricsDelta.compute(previous: first, current: reading(12, nil, nil))
        check(missing.cpuPercent == nil && missing.received == nil, "failed acquisition must remain unknown")
        let beforeTwo = reading(10, nil, ["en0": .init(received: 1000, sent: 100), "en1": .init(received: 100, sent: 100)])
        let afterTwo = reading(12, nil, ["en0": .init(received: 900, sent: 200), "en1": .init(received: 10000, sent: 200)])
        check(MetricsDelta.compute(previous: beforeTwo, current: afterTwo).received == nil, "aggregate growth cannot hide one interface reset")
        check(MetricsDelta.isPhysicalInterfaceName("en0") && MetricsDelta.isPhysicalInterfaceName("en12"), "physical interfaces admitted")
        for name in ["en", "en0.1", "utun0", "lo0", "awdl0", "bridge0", "en٠"] {
            check(!MetricsDelta.isPhysicalInterfaceName(name), "exclude duplicate or unsupported link \(name)")
        }
        check(MetricsDelta.memoryUsed(freePages: 100, speculativePages: 20, externalPages: 300, purgeablePages: 10, pageSize: 4096, total: 10_000_000) == 8_402_560, "subtract free plus cache, counting speculative overlap only once")
        check(MetricsDelta.memoryUsed(freePages: 10, speculativePages: 20, externalPages: 30, purgeablePages: 0, pageSize: 4096, total: 1_000_000) == 877_120, "inconsistent page snapshots cannot underflow free count")
        check(MetricsDelta.memoryUsed(freePages: 100, speculativePages: 0, externalPages: 200, purgeablePages: 0, pageSize: 4096, total: 1000) == 0, "available exceeding physical must clamp to zero")
        check(MetricsDelta.memoryUsed(freePages: UInt64.max, speculativePages: 0, externalPages: 1, purgeablePages: 1, pageSize: 4096, total: 1000) == 0, "page count overflow must not invent used bytes")
        check(MetricsDelta.memoryUsed(freePages: UInt64.max / 2, speculativePages: 0, externalPages: 0, purgeablePages: 0, pageSize: 4096, total: 1000) == 0, "byte multiplication overflow must clamp")
        let physical: UInt64 = 24 * 1024 * 1024 * 1024
        let captured = MetricsDelta.memoryUsed(freePages: 7058, speculativePages: 999, externalPages: 208127, purgeablePages: 829, pageSize: 16384, total: physical)
        check(captured == physical - (6059 + 208127 + 829) * 16384, "real ARM64 sample includes physical remainder without a fixed offset")
        check(MetricsDelta.memoryUsed(freePages: 0, speculativePages: 0, externalPages: 0, purgeablePages: 0, pageSize: 16384, total: physical) == physical, "zero available memory accounts for all physical RAM")
        let sampler = MetricsSampler()
        let live = sampler.sample()
        check(live.cpuPercent == nil && live.receivedBytesPerSecond == nil, "real first sample also unknown")
        check(live.memoryTotalBytes > 0 && live.memoryUsedBytes <= live.memoryTotalBytes, "live memory sane")
        check(live.memoryReadingAvailable && live.memoryDiagnostics?["pageSizeBytes"] != nil, "successful VM read includes same-sample diagnostics")
        sampler.reset()
        let reset = sampler.sample()
        check(reset.cpuPercent == nil && reset.receivedBytesPerSecond == nil, "reset establishes fresh baseline")
        print("MetricsTests: \(checks) checks passed")
    }
}
