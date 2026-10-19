import XCTest
@testable import QuotaCore

final class PaceTests: XCTestCase {
    let hour = 3600.0
    var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    var now: Date { ISO8601DateFormatter().date(from: "2026-10-15T12:00:00Z")! }

    struct Spec {
        var id = "a"
        var provider = Provider.claude
        var plan = "Max"
        var weeklyUsed = 20.0
        var weeklyRate = 0.3
        var weeklyReset = 48.0
        var sessionRate: Double? = nil
        var sessionReset = 1.0
        var disabled = false
    }
    func fixture(_ specs: [Spec], hours: Double = 10, ending: Date? = nil,
                 multiplier: (Date) -> Double = { _ in 1 }) -> (QuotaSnapshot, PaceHistory) {
        let end = ending ?? now
        var history = PaceHistory(), latest = QuotaSnapshot(accounts: [], fetchedAt: end)
        for step in 0...Int(hours * 12) {
            let time = end.addingTimeInterval(-hours * hour + Double(step) * 300)
            let ago = end.timeIntervalSince(time) / hour
            let accounts = specs.map { spec -> SubscriptionAccount in
                let reset = end.addingTimeInterval(spec.weeklyReset * hour)
                var windows = [QuotaWindow(id: "seven_day", usedPercent: max(0, spec.weeklyUsed - spec.weeklyRate * ago),
                                           resetsAt: reset, observedAt: time)]
                if let rate = spec.sessionRate {
                    var reset = end.addingTimeInterval(spec.sessionReset * hour)
                    while reset.timeIntervalSince(time) > 5 * hour { reset = reset.addingTimeInterval(-5 * hour) }
                    let elapsed = max(0, 5 - reset.timeIntervalSince(time) / hour)
                    windows.append(.init(id: "five_hour", usedPercent: min(100, elapsed * rate * multiplier(time)), resetsAt: reset, observedAt: time))
                }
                return .init(id: spec.id, provider: spec.provider, label: "private-name", plan: spec.plan,
                             disabled: spec.disabled, windows: windows, checkedAt: time)
            }
            latest = .init(accounts: accounts, fetchedAt: time)
            history.record(latest)
        }
        return (latest, history)
    }
    func forecast(_ fixture: (QuotaSnapshot, PaceHistory), at date: Date? = nil, provider: Provider = .claude) -> PaceForecast {
        PaceForecaster.forecast(snapshot: fixture.0, history: fixture.1, provider: provider, at: date ?? now, calendar: calendar)
    }

    func testIdleWeeklyClockStillGetsAFullWeekHorizon() {
        var f = fixture([Spec()])
        f.0.accounts[0].windows[0].usedPercent = 0
        f.0.accounts[0].windows[0].resetsAt = nil
        let result = forecast(f)
        XCTAssertEqual(result.horizon.timeIntervalSince(now), 7 * 86400, accuracy: 1)
        XCTAssertNotEqual(result.gap, .readings)
    }
    func testColdStartIsNeutralAndNeverInventsIndividualPacing() {
        let f = fixture([Spec()], hours: 0)
        XCTAssertNil(forecast(f).pace)
        XCTAssertEqual(forecast(f).gap, .history)
        XCTAssertNil(forecast(f).displayPrediction)
        XCTAssertEqual(f.0.accounts[0].tone(at: now), .unknown)
        XCTAssertEqual(f.0.accounts[0].windows[0].tone(at: now), .unknown)
        XCTAssertEqual(MeterTone(left: 5, pace: nil), .unknown)
    }
    func testQuietDemandHasConfidentGlobalHeadroom() {
        let result = forecast(fixture([Spec()]))
        XCTAssertEqual(result.pace, .under)
        XCTAssertGreaterThan(result.observedHours, 9)
        XCTAssertLessThan(result.pressureRange!.upperBound, 0.5)
        XCTAssertEqual(result.prediction, .init(pace: .under, agreement: 1))
    }
    func testModerateDemandIsGreenWhenWholeBandIsAboveHalfButFeasible() {
        let result = forecast(fixture([Spec(weeklyUsed: 40, weeklyRate: 1.8, weeklyReset: 24)]))
        XCTAssertEqual(result.pace, .steady)
        XCTAssertGreaterThanOrEqual(result.pressureRange!.lowerBound, 0.5)
        XCTAssertLessThan(result.pressureRange!.upperBound, 1)
        XCTAssertEqual(result.prediction, .init(pace: .steady, agreement: 1))
    }
    func testShortageEvenAtLowDemandIsOrange() {
        let result = forecast(fixture([Spec(weeklyUsed: 90, weeklyRate: 3, weeklyReset: 48)]))
        XCTAssertEqual(result.pace, .over)
        XCTAssertNotNil(result.shortageAt)
        XCTAssertEqual(result.prediction, .init(pace: .over, agreement: 1))
        XCTAssertNotNil(result.predictionDeficits["seven_day"])
        XCTAssertLessThan(result.shortageAt!, now.addingTimeInterval(48 * hour))
    }
    func testBoundaryCrossingAbstainsInsteadOfFallingBackToLevel() {
        let result = forecast(fixture([Spec(weeklyUsed: 40, weeklyRate: 0.6, weeklyReset: 48)]))
        XCTAssertNil(result.pace)
        XCTAssertEqual(result.gap, .uncertainty)
        XCTAssertNotNil(result.prediction)
        XCTAssertLessThan(result.prediction?.agreement ?? 1, 1)
        XCTAssertGreaterThan(result.prediction?.agreement ?? 0, 0)
    }
    func testStaggeredWeeklyRenewalRescuesThePool() {
        let early = Spec(id: "early", weeklyUsed: 98, weeklyRate: 1, weeklyReset: 1)
        let later = Spec(id: "later", weeklyUsed: 40, weeklyRate: 0.1, weeklyReset: 48)
        let result = forecast(fixture([early, later]))
        XCTAssertNotEqual(result.pace, .over)
        XCTAssertNotNil(result.pace)
        XCTAssertNil(result.shortageAt)
        XCTAssertEqual(forecast(fixture([Spec(id: "early", weeklyUsed: 98, weeklyRate: 1, weeklyReset: 48)])).pace, .over)
    }
    func testSessionRenewalIsNotWeeklyRenewalAndConstraintsAreCoupled() {
        let result = forecast(fixture([Spec(weeklyUsed: 98, weeklyRate: 1, weeklyReset: 48, sessionRate: 2)]))
        XCTAssertEqual(result.pace, .over) // Fresh sessions cannot refill the exhausted weekly budget.
        let renewable = forecast(fixture([Spec(weeklyUsed: 20, weeklyRate: 0.3, weeklyReset: 48, sessionRate: 3)]))
        XCTAssertNotEqual(renewable.pace, .over) // Session refills repeat, not a single 100% for the whole horizon.
        XCTAssertNotNil(renewable.pace)
    }
    func testCapacityOnDifferentLicencesCannotBypassTheirOwnOtherLimit() {
        var f = fixture([Spec(id: "a", weeklyUsed: 20, weeklyRate: 0.3, sessionRate: 2),
                         Spec(id: "b", weeklyUsed: 20, weeklyRate: 0.3, sessionRate: 2)])
        // Session room on A, weekly room on B. Neither can serve a request before its reset.
        f.0.accounts[0].windows[0].usedPercent = 100
        f.0.accounts[1].windows[1].usedPercent = 100
        XCTAssertNil(forecast(f).pace) // A marginal pooled average would incorrectly promise capacity.
        XCTAssertNil(forecast(f).prediction) // A failed routing heuristic is not proof of a shortage.
    }
    func testDisabledAccountsDoNotAddCapacityOrDemand() {
        let base = Spec(weeklyUsed: 90, weeklyRate: 3, weeklyReset: 48)
        let result = forecast(fixture([base, Spec(id: "off", weeklyUsed: 0, weeklyRate: 0, disabled: true)]))
        XCTAssertEqual(result.pace, .over)
    }
    func testProvidersCannotSubsidizeEachOther() {
        let f = fixture([Spec(weeklyUsed: 90, weeklyRate: 3, weeklyReset: 48),
                         Spec(id: "codex", provider: .codex, plan: "Pro", weeklyUsed: 20, weeklyRate: 0.3)])
        XCTAssertEqual(forecast(f).pace, .over)
        XCTAssertEqual(forecast(f, provider: .codex).pace, .under)
    }
    func testMissingStaleUnknownAndMixedPlanCapacityAllAbstain() {
        var f = fixture([Spec()])
        f.0.accounts[0].windows[0].observedAt = now.addingTimeInterval(-601)
        XCTAssertEqual(forecast(f).gap, .readings)
        f = fixture([Spec()]); f.0.accounts[0].windows[0].resetsAt = nil
        XCTAssertEqual(forecast(f).gap, .readings)
        f = fixture([Spec()]); f.0.accounts[0].plan = nil
        XCTAssertEqual(forecast(f).gap, .capacity)
        XCTAssertEqual(forecast(fixture([Spec(), Spec(id: "b", plan: "Pro")])).gap, .capacity)
        f = fixture([Spec()]); f.0.accounts[0].readError = "failed"
        XCTAssertEqual(forecast(f).gap, .readings)
    }
    func testPollingCachedReadingsDoesNotManufactureEvidence() {
        let f = fixture([Spec()], hours: 0)
        var history = f.1
        for step in 1...1000 {
            var snapshot = f.0
            snapshot.fetchedAt = now.addingTimeInterval(Double(step) * 30)
            history.record(snapshot)
        }
        XCTAssertEqual(history.frames.count, 1)
    }
    func testSleepGapAndFleetChangesRequireNewEvidence() {
        var f = fixture([Spec()])
        f.0.fetchedAt = now.addingTimeInterval(3 * hour)
        f.0.accounts[0].windows[0].observedAt = f.0.fetchedAt
        f.1.record(f.0)
        XCTAssertEqual(forecast(f, at: f.0.fetchedAt).gap, .history)
        XCTAssertEqual(forecast(f, at: f.0.fetchedAt).recentObservedHours, 0)
        f = fixture([Spec()]); f.0.accounts[0].id = "new"
        XCTAssertEqual(forecast(f).gap, .history)
    }
    func testRestartWithoutQuotaMetadataPreservesEarlierObservedHours() throws {
        let before = fixture([Spec()], ending: now.addingTimeInterval(-2 * hour))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try before.1.save(to: url)
        var history = PaceHistory.load(from: url)
        var startup = before.0
        startup.fetchedAt = now.addingTimeInterval(-2 * hour + 300)
        startup.accounts[0].plan = nil
        startup.accounts[0].windows = []
        history.record(startup)
        let after = fixture([Spec()], hours: 2)
        for frame in after.1.frames {
            var snapshot = after.0
            snapshot.fetchedAt = frame.date
            snapshot.accounts[0].windows = frame.accounts[0].windows
            history.record(snapshot)
        }
        let result = forecast((after.0, history))
        XCTAssertGreaterThan(result.observedHours, 11)
        XCTAssertEqual(result.recentObservedHours, 11.0 / 6, accuracy: 0.001)
        XCTAssertEqual(result.pace, .under)
    }
    func testUnusedCodexAccountWithMovingResetDoesNotBlockFleetLearning() {
        var f = fixture([Spec(id: "active", provider: .codex, plan: "Pro"),
                         Spec(id: "idle", provider: .codex, plan: "Pro", weeklyUsed: 0, weeklyRate: 0)])
        var history = PaceHistory()
        for frame in f.1.frames {
            var snapshot = f.0
            snapshot.fetchedAt = frame.date
            for i in snapshot.accounts.indices { snapshot.accounts[i].windows = frame.accounts[i].windows }
            snapshot.accounts[1].windows[0].resetsAt = frame.date.addingTimeInterval(7 * 86400)
            history.record(snapshot)
            f.0 = snapshot
        }
        let result = forecast((f.0, history), provider: .codex)
        XCTAssertEqual(result.observedHours, 10, accuracy: 0.001)
        XCTAssertEqual(result.baselineDemand["seven_day"] ?? -1, 0.3, accuracy: 0.001)
        XCTAssertEqual(result.pace, .under)
    }
    func testConfirmedFleetChangesStillRequireNewEvidenceAfterReturning() {
        let f = fixture([Spec()])
        let changes: [(inout SubscriptionAccount) -> Void] = [
            { $0.id = "replacement" }, { $0.plan = "Pro" }, { $0.disabled = true },
            { $0.windows[0].id = "five_hour" }
        ]
        for change in changes {
            var history = PaceHistory()
            for frame in f.1.frames {
                var snapshot = f.0
                snapshot.fetchedAt = frame.date
                snapshot.accounts[0].windows = frame.accounts[0].windows
                if frame.date == now.addingTimeInterval(-5 * hour) { change(&snapshot.accounts[0]) }
                history.record(snapshot)
            }
            let result = forecast((f.0, history))
            XCTAssertLessThan(result.observedHours, 5)
            XCTAssertEqual(result.gap, .history)
            XCTAssertNil(result.pace)
        }
    }
    func testSlowIntegerQuotaChangesAreMeasuredActivityNotMissingEvidence() {
        var f = fixture([Spec(provider: .codex, plan: "Pro", weeklyUsed: 5, weeklyRate: 0.2, weeklyReset: 24)])
        var history = PaceHistory()
        for frame in f.1.frames {
            var snapshot = f.0
            snapshot.fetchedAt = frame.date
            snapshot.accounts[0].windows = frame.accounts[0].windows
            snapshot.accounts[0].windows[0].usedPercent = frame.accounts[0].windows[0].usedPercent!.rounded(.down)
            history.record(snapshot)
            f.0 = snapshot
        }
        let result = forecast((f.0, history), provider: .codex)
        XCTAssertEqual(result.observedHours, 10, accuracy: 0.001)
        XCTAssertEqual(result.pace, .under)
        XCTAssertGreaterThan(result.baselineDemand["seven_day"] ?? 0, 0)
    }
    func testUnmeasuredActivityAndCompletelyBlockedFleetStillAbstain() {
        let idle = forecast(fixture([Spec(weeklyUsed: 0, weeklyRate: 0)]))
        XCTAssertEqual(idle.gap, .activity)
        XCTAssertNil(idle.pace)
        let blocked = forecast(fixture([Spec(weeklyUsed: 100, weeklyRate: 0)]))
        XCTAssertEqual(blocked.observedHours, 0)
        XCTAssertNil(blocked.pace)
    }
    func scheduledFixture(ending: Date, days: Int = 14, schedule: (Date) -> Double) -> (QuotaSnapshot, PaceHistory) {
        var history = PaceHistory(), snapshot = QuotaSnapshot(accounts: [], fetchedAt: ending)
        let start = ending.addingTimeInterval(-Double(days) * 24 * hour)
        var used = 0.0, reset = start.addingTimeInterval(6 * 24 * hour)
        for step in 0...(days * 24 * 12) {
            let time = start.addingTimeInterval(Double(step) * 300)
            if time >= reset { used = 0; reset = reset.addingTimeInterval(7 * 24 * hour) }
            if step > 0 { used += schedule(time.addingTimeInterval(-150)) / 12 }
            snapshot = .init(accounts: [.init(id: "a", provider: .claude, label: "private-name", plan: "Max",
                windows: [.init(id: "seven_day", usedPercent: used, resetsAt: reset, observedAt: time)])], fetchedAt: time)
            history.record(snapshot)
        }
        // At a reset, a fresh provider cycle has a future reset, not an elapsed one.
        return (snapshot, history)
    }
    func testRecentAccelerationOutweighsQuietNight() {
        let end = now
        var burst = scheduledFixture(ending: end, days: 2) { date in
            date > end.addingTimeInterval(-2 * self.hour) ? 2 : 0.3
        }
        var quiet = scheduledFixture(ending: end, days: 2) { _ in 0.3 }
        for i in burst.0.accounts[0].windows.indices {
            burst.0.accounts[0].windows[i].usedPercent = 80
            burst.0.accounts[0].windows[i].resetsAt = end.addingTimeInterval(24 * hour)
            quiet.0.accounts[0].windows[i] = burst.0.accounts[0].windows[i]
        }
        let rising = forecast(burst), calm = forecast(quiet)
        XCTAssertEqual(calm.pace, .under)
        XCTAssertGreaterThan(rising.recentDemand["seven_day"]!, rising.baselineDemand["seven_day"]! * 2)
        XCTAssertGreaterThan(rising.pressureRange!.upperBound, calm.pressureRange!.upperBound * 2)
        XCTAssertNotEqual(rising.pace, .under)
    }
    func testMondayUsesFridayNotWeekendZeros() {
        let monday = ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z")!
        let f = scheduledFixture(ending: monday) { date in self.calendar.isDateInWeekend(date) ? 0 : 0.5 }
        let result = forecast(f, at: monday)
        XCTAssertGreaterThan(result.observedHours, 20)
        XCTAssertEqual(result.baselineDemand["seven_day"]!, 0.5, accuracy: 0.001)
        XCTAssertEqual(result.recentDemand["seven_day"]!, 0.5, accuracy: 0.001)
    }
    func testUncertaintyDoesNotInventCentralDemandDuringLearnedQuietHours() {
        let end = ISO8601DateFormatter().date(from: "2026-10-19T18:00:00Z")!
        var f = scheduledFixture(ending: end) { date in
            let h = self.calendar.component(.hour, from: date)
            return (8..<18).contains(h) ? 2 : 0
        }
        // Twenty points per day, thirty left until tomorrow evening. Wide sensitivity
        // bounds may warn, but their clipped lower tail must not shift the forecast up.
        f.0.accounts[0].windows[0].usedPercent = 70
        f.0.accounts[0].windows[0].resetsAt = end.addingTimeInterval(24 * hour)
        let result = forecast(f, at: end)
        XCTAssertEqual(result.prediction?.pace, .steady)
        XCTAssertEqual(result.projectedDemand["seven_day"] ?? -1, 20, accuracy: 0.05)
        XCTAssertNil(result.shortageAt)
        XCTAssertTrue(result.predictionDeficits.isEmpty)
    }
    func testRegularWorkdayIsNotCountedAgainAsAnAfternoonBurst() {
        for clockHour in [6, 12, 18] {
            let end = calendar.startOfDay(for: now).addingTimeInterval(Double(clockHour) * hour)
            var f = scheduledFixture(ending: end) { date in
                (8..<18).contains(self.calendar.component(.hour, from: date)) ? 2 : 0
            }
            f.0.accounts[0].windows[0].usedPercent = 70
            f.0.accounts[0].windows[0].resetsAt = end.addingTimeInterval(24 * hour)
            let result = forecast(f, at: end)
            XCTAssertEqual(result.projectedDemand["seven_day"] ?? -1, 20, accuracy: 0.05, "Forecast hour: \(clockHour)")
            XCTAssertEqual(result.prediction?.pace, .steady)
        }
    }
    func testLearnedInactiveWeekendCanForecastWithoutAssumingWeekdayDemand() {
        let saturday = ISO8601DateFormatter().date(from: "2026-10-17T18:00:00Z")!
        var idle = scheduledFixture(ending: saturday) { date in self.calendar.isDateInWeekend(date) ? 0 : 0.5 }
        var continuous = scheduledFixture(ending: saturday) { _ in 0.5 }
        for f in 0...1 {
            if f == 0 {
                idle.0.accounts[0].windows[0].usedPercent = 80
                idle.0.accounts[0].windows[0].resetsAt = saturday.addingTimeInterval(24 * hour)
            } else { continuous.0.accounts[0].windows[0] = idle.0.accounts[0].windows[0] }
        }
        let off = forecast(idle, at: saturday), on = forecast(continuous, at: saturday)
        XCTAssertEqual(off.pace, .under)
        XCTAssertLessThan(off.pressureRange!.upperBound, on.pressureRange!.upperBound * 0.6)
    }
    func testFastBurstClockDoesNotPauseAtWeekendBoundary() {
        let saturday = ISO8601DateFormatter().date(from: "2026-10-17T01:00:00Z")!
        let burstStart = saturday.addingTimeInterval(-2 * hour)
        let boundary = saturday.addingTimeInterval(-hour)
        let f = scheduledFixture(ending: saturday) { date in
            if date > burstStart && date < boundary { return 2 }
            return self.calendar.isDateInWeekend(date) ? 0 : 0.2
        }
        let result = forecast(f, at: saturday)
        // 30-minute half-life over the actual last two hours: the earlier hour has one fifth of the weight.
        XCTAssertEqual(result.recentDemand["seven_day"]!, 0.4, accuracy: 0.025)
    }
    func testAmbiguousUnavailabilityAndExpiredCooldownDoNotAddUsableSupply() {
        var f = fixture([Spec()])
        f.0.accounts[0].unavailable = true
        f.0.accounts[0].cooldownUntil = now.addingTimeInterval(-60)
        XCTAssertEqual(forecast(f).gap, .readings)
        f.0.accounts[0].cooldownUntil = nil
        XCTAssertEqual(forecast(f).gap, .readings)
    }
    func testResetDecreaseAndUnchangedTimestampAreNotNegativeOrZeroDemand() {
        var f = fixture([Spec()])
        let priorCount = f.1.frames.count
        var reset = f.0
        reset.fetchedAt = now.addingTimeInterval(300)
        reset.accounts[0].windows[0].observedAt = reset.fetchedAt
        reset.accounts[0].windows[0].usedPercent = 0
        reset.accounts[0].windows[0].resetsAt = reset.fetchedAt.addingTimeInterval(7 * 86400)
        f.1.record(reset)
        XCTAssertEqual(f.1.frames.count, priorCount + 1)
        let result = forecast((reset, f.1), at: reset.fetchedAt)
        XCTAssertEqual(result.baselineDemand["seven_day"]!, 0.3, accuracy: 0.001)
    }
    func testHistoryRoundTripKeepsOnlyMinimalLocalFields() throws {
        let f = fixture([Spec()])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.json")
        try f.1.save(to: url)
        XCTAssertEqual(PaceHistory.load(from: url).frames.count, f.1.frames.count)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("private-name"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
    }
}
