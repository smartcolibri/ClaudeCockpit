import XCTest
@testable import OverviewKit

final class RecommendationEngineTests: XCTestCase {
    private typealias Usage = RecommendationInput.Usage
    private let day: TimeInterval = 86_400

    private func run(_ usage: Usage? = nil, sessions: RecommendationInput.Sessions? = nil,
                     rtk: RecommendationInput.RTK = .unknown) -> [Recommendation] {
        RecommendationEngine.recommend(RecommendationInput(usage: usage, sessions: sessions, rtk: rtk))
    }

    private func kinds(_ list: [Recommendation]) -> [Recommendation.Kind] { list.map(\.kind) }

    func testNothingToSayWithoutSources() {
        XCTAssertEqual(run(), [])
        XCTAssertEqual(run(Usage()), [], "an idle account raises nothing")
    }

    // MARK: Cost trend

    func testCostTrendBothWaysPastTheThreshold() {
        let up = run(Usage(costThisWeekToDateUSD: 12.5, costLastWeekToDateUSD: 10, elapsedThisWeek: 2 * day))
        XCTAssertEqual(kinds(up), [.costUp(fraction: 0.25)])
        XCTAssertEqual(up.first?.level, .warning)
        XCTAssertEqual(up.first?.target, .usage)

        let down = run(Usage(costThisWeekToDateUSD: 7, costLastWeekToDateUSD: 10, elapsedThisWeek: 2 * day))
        XCTAssertEqual(kinds(down).count, 1)
        guard case .costDown(let fraction) = down.first?.kind else { return XCTFail("\(down)") }
        XCTAssertEqual(fraction, 0.3, accuracy: 1e-9)
        XCTAssertEqual(down.first?.level, .good)
    }

    func testCostTrendStaysQuietWhenSmallEarlyOrBaseless() {
        XCTAssertEqual(run(Usage(costThisWeekToDateUSD: 11.9, costLastWeekToDateUSD: 10, elapsedThisWeek: 2 * day)), [])
        XCTAssertEqual(run(Usage(costThisWeekToDateUSD: 30, costLastWeekToDateUSD: 10, elapsedThisWeek: day - 1)), [],
                       "Monday morning: last week's stretch is too short to compare")
        XCTAssertEqual(run(Usage(costThisWeekToDateUSD: 30, costLastWeekToDateUSD: 0.99, elapsedThisWeek: 3 * day)), [],
                       "cents last week would turn any spend into thousands of percent")
    }

    // MARK: Opus

    func testOpusHeavyNamesTheProject() {
        let list = run(Usage(cost30DaysUSD: 40, opusShare30Days: 0.62, topOpusProject: "~/DevApps/notes-api"))
        XCTAssertEqual(kinds(list), [.opusHeavy(share: 0.62, project: "~/DevApps/notes-api")])
        XCTAssertEqual(list.first?.level, .info)
        XCTAssertEqual(run(Usage(cost30DaysUSD: 40, opusShare30Days: 0.59)), [])
        XCTAssertEqual(run(Usage(cost30DaysUSD: 4.99, opusShare30Days: 0.9)), [], "too little spend to matter")
    }

    // MARK: Sessions

    func testSessionsWithErrorsEscalateWithTheCount() {
        let two = run(sessions: .init(withErrorsToday: 2))
        XCTAssertEqual(kinds(two), [.sessionsWithErrors(count: 2)])
        XCTAssertEqual(two.first?.level, .warning)
        XCTAssertEqual(two.first?.target, .sessionsWithErrors)
        XCTAssertEqual(run(sessions: .init(withErrorsToday: 3)).first?.level, .critical)
        XCTAssertEqual(run(sessions: .init(withErrorsToday: 0)), [])
    }

    func testLowHealthSessions() {
        let list = run(sessions: .init(lowHealthToday: 1))
        XCTAssertEqual(kinds(list), [.lowHealthSessions(count: 1)])
        XCTAssertEqual(list.first?.level, .warning)
        XCTAssertEqual(list.first?.target, .sessions)
    }

    // MARK: Peak hour

    private func hours(_ values: [Int: Double]) -> [Double] {
        (0..<24).map { values[$0] ?? 0 }
    }

    func testPeakHourWhenOneHourCarriesTheDay() {
        let list = run(Usage(hourlyCostToday: hours([9: 0.5, 10: 2, 14: 1, 16: 0.5])))
        XCTAssertEqual(kinds(list), [.peakHour(hour: 10, share: 0.5)])
        XCTAssertEqual(list.first?.level, .info)
    }

    func testPeakHourNeedsSpendAndSeveralActiveHours() {
        XCTAssertEqual(run(Usage(hourlyCostToday: hours([10: 3, 11: 1]))), [], "two active hours: a share means nothing")
        XCTAssertEqual(run(Usage(hourlyCostToday: hours([9: 0.1, 10: 0.5, 11: 0.2]))), [], "under a dollar today")
        XCTAssertEqual(run(Usage(hourlyCostToday: hours([9: 1, 10: 1.1, 11: 1]))), [], "no hour stands out")
        XCTAssertEqual(run(Usage(hourlyCostToday: [5])), [], "a malformed series is ignored")
    }

    func testPeakHourTieKeepsTheEarliest() {
        let list = run(Usage(hourlyCostToday: hours([8: 2, 9: 0.5, 15: 2])))
        XCTAssertEqual(list.first?.kind, .peakHour(hour: 8, share: 2 / 4.5))
    }

    // MARK: Cache

    func testCacheRateLowAndGood() {
        let low = run(Usage(cacheHitRate30Days: 0.2, cacheableTokens30Days: 2_000_000))
        XCTAssertEqual(kinds(low), [.lowCacheRate(0.2)])
        XCTAssertEqual(low.first?.level, .warning)
        let good = run(Usage(cacheHitRate30Days: 0.96, cacheableTokens30Days: 2_000_000))
        XCTAssertEqual(kinds(good), [.goodCacheRate(0.96)])
        XCTAssertEqual(good.first?.level, .good)
        XCTAssertEqual(run(Usage(cacheHitRate30Days: 0.5, cacheableTokens30Days: 2_000_000)), [])
        XCTAssertEqual(run(Usage(cacheHitRate30Days: 0.1, cacheableTokens30Days: 999_999)), [], "too few tokens for a rate")
    }

    // MARK: RTK

    func testRTKMissingOrSavingLittle() {
        let missing = run(rtk: .missing)
        XCTAssertEqual(kinds(missing), [.rtkMissing])
        XCTAssertEqual(missing.first?.target, .rtk)
        XCTAssertEqual(kinds(run(rtk: .active(savedFraction: 0.25, commands: 40))), [.rtkLowSavings(0.25)])
        XCTAssertEqual(run(rtk: .active(savedFraction: 0.25, commands: 19)), [], "too few commands")
        XCTAssertEqual(run(rtk: .active(savedFraction: 0.8, commands: 400)), [])
        XCTAssertEqual(run(rtk: .unknown), [])
    }

    // MARK: Pricing & projection

    func testUnpricedModelsOneEach() {
        let list = run(Usage(unpricedModels: ["mystery-2", "mystery-1"]))
        XCTAssertEqual(kinds(list), [.unpricedModel("mystery-1"), .unpricedModel("mystery-2")])
        XCTAssertTrue(list.allSatisfy { $0.level == .warning })
    }

    func testProjectionAboveLastMonth() {
        let list = run(Usage(monthProjectionUSD: 130, monthElapsedDays: 10, lastMonthCostUSD: 100))
        XCTAssertEqual(kinds(list), [.projectionAboveLastMonth(projectionUSD: 130, lastMonthUSD: 100)])
        XCTAssertEqual(list.first?.level, .warning)
        XCTAssertEqual(run(Usage(monthProjectionUSD: 124, monthElapsedDays: 10, lastMonthCostUSD: 100)), [])
        XCTAssertEqual(run(Usage(monthProjectionUSD: 400, monthElapsedDays: 2.9, lastMonthCostUSD: 100)), [], "too early in the month")
        XCTAssertEqual(run(Usage(monthProjectionUSD: 40, monthElapsedDays: 10, lastMonthCostUSD: 4.99)), [], "no real baseline")
        XCTAssertEqual(run(Usage(monthProjectionUSD: nil, monthElapsedDays: 10, lastMonthCostUSD: 100)), [])
    }

    // MARK: Ranking

    func testRankedBySeverityThenRuleOrderAndCappedAtFive() {
        let usage = Usage(
            costThisWeekToDateUSD: 20, costLastWeekToDateUSD: 10, elapsedThisWeek: 3 * day,  // warning
            cost30DaysUSD: 50, opusShare30Days: 0.7, topOpusProject: "p",  // info
            hourlyCostToday: hours([9: 1, 10: 4, 11: 1]),  // info
            cacheHitRate30Days: 0.9, cacheableTokens30Days: 5_000_000,  // good
            unpricedModels: ["m"],  // warning
            monthProjectionUSD: 300, monthElapsedDays: 12, lastMonthCostUSD: 100)  // warning
        let full = RecommendationEngine.recommend(
            RecommendationInput(usage: usage, sessions: .init(withErrorsToday: 4, lowHealthToday: 2), rtk: .missing),
            limit: .max)
        XCTAssertEqual(full.map(\.level), [.critical, .warning, .warning, .warning, .warning, .info, .info, .info, .good])
        XCTAssertEqual(kinds(full), [
            .sessionsWithErrors(count: 4),
            .costUp(fraction: 1),
            .lowHealthSessions(count: 2),
            .unpricedModel("m"),
            .projectionAboveLastMonth(projectionUSD: 300, lastMonthUSD: 100),
            .opusHeavy(share: 0.7, project: "p"),
            .peakHour(hour: 10, share: 4.0 / 6),
            .rtkMissing,
            .goodCacheRate(0.9),
        ])

        let capped = RecommendationEngine.recommend(
            RecommendationInput(usage: usage, sessions: .init(withErrorsToday: 4, lowHealthToday: 2), rtk: .missing))
        XCTAssertEqual(capped.count, RecommendationEngine.maximumCount)
        XCTAssertEqual(capped, Array(full.prefix(5)))
    }

    func testDeterministic() {
        let input = RecommendationInput(
            usage: Usage(unpricedModels: ["b", "a", "c"], monthProjectionUSD: 300, monthElapsedDays: 12, lastMonthCostUSD: 100),
            sessions: .init(withErrorsToday: 1), rtk: .missing)
        XCTAssertEqual(RecommendationEngine.recommend(input), RecommendationEngine.recommend(input))
        XCTAssertEqual(Set(RecommendationEngine.recommend(input).map(\.id)).count, 5, "ids are unique")
    }
}
