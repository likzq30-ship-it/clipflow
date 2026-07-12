import XCTest
@testable import ClipFlow

final class RepositoryPerformanceTests: XCTestCase {
    func testTenThousandClipSearchP95() async throws {
        let repository = try await makeRepository()
        try await repository.seedSyntheticClips(count: 10_000)

        let durations = try await measureDurations(iterations: 20) {
            _ = try await repository.fetchPage(
                .init(searchText: "needle-9999", scope: .all, limit: 100, offset: 0)
            )
        }

        XCTAssertLessThan(percentile95(durations), 0.100)
    }
}

extension ClipboardRepository {
    func seedSyntheticClips(count: Int) async throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<count {
            _ = try await upsertCapturedText(
                CapturedText(
                    content: "clip-\(index) needle-\(index)",
                    category: .english,
                    capturedAt: base.addingTimeInterval(TimeInterval(index)),
                    sourceBundleID: nil
                )
            )
        }
    }
}

func measureDurations(
    iterations: Int,
    operation: () async throws -> Void
) async rethrows -> [TimeInterval] {
    var values: [TimeInterval] = []
    let clock = ContinuousClock()
    for _ in 0..<iterations {
        let start = clock.now
        try await operation()
        let components = start.duration(to: clock.now).components
        values.append(
            TimeInterval(components.seconds)
                + TimeInterval(components.attoseconds) / 1e18
        )
    }
    return values
}

func percentile95(_ values: [TimeInterval]) -> TimeInterval {
    let sorted = values.sorted()
    let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
    return sorted[max(0, index)]
}

@MainActor
func measureMainActorDurations(
    iterations: Int,
    operation: @MainActor () async throws -> Void
) async rethrows -> [TimeInterval] {
    var values: [TimeInterval] = []
    let clock = ContinuousClock()
    for _ in 0..<iterations {
        let start = clock.now
        try await operation()
        let components = start.duration(to: clock.now).components
        values.append(
            TimeInterval(components.seconds)
                + TimeInterval(components.attoseconds) / 1e18
        )
    }
    return values
}
