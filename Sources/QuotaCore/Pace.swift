import Foundation

/// Global predictions only. Individual licences expose measurements, never a pace.
public enum Pace: String, Codable, Sendable { case over, steady, under }

extension QuotaWindow {
    public var duration: TimeInterval? {
        id == "five_hour" ? 5 * 3600 : id == "seven_day" ? 7 * 86400 : nil
    }
}

/// Local, bounded history. No names, credentials, credit balances or provider responses.
public struct PaceHistory: Codable, Sendable {
    public struct Account: Codable, Sendable {
        public let id: String
        public let provider: Provider
        public let plan: String?
        public let windows: [QuotaWindow]
        public let blocked: Bool
    }
    public struct Frame: Codable, Sendable {
        public let date: Date
        public let accounts: [Account]
    }
    public private(set) var frames: [Frame] = []
    public let source: String?
    public init(source: String? = nil) { self.source = source }

    public mutating func record(_ snapshot: QuotaSnapshot) {
        let now = snapshot.fetchedAt
        guard frames.last.map({ now > $0.date }) ?? true else { return }
        let accounts = snapshot.accounts.filter { !$0.disabled }.map { account in
            Account(id: account.id, provider: account.provider, plan: account.plan,
                    windows: account.windows.filter { !$0.modelScoped },
                    blocked: account.unavailable || account.cooldownUntil.map { $0 > now } == true)
        }.sorted { $0.id < $1.id }
        if let last = frames.last, Self.signature(accounts) == Self.signature(last.accounts),
           zip(accounts, last.accounts).allSatisfy({ a, b in a.windows == b.windows && a.blocked == b.blocked }) { return }
        // Keep the first observation of each five-minute interval. Cached reads cannot create samples.
        if let last = frames.last, now.timeIntervalSince(last.date) < 300,
           Self.signature(accounts) == Self.signature(last.accounts) { return }
        frames.append(Frame(date: now, accounts: accounts))
        frames.removeAll { $0.date < now.addingTimeInterval(-21 * 86400) }
        if frames.count > 6500 { frames.removeFirst(frames.count - 6500) }
    }

    static func signature(_ accounts: [Account]) -> [String] {
        accounts.map { "\($0.provider.rawValue):\($0.id):\($0.plan ?? "?"):\($0.windows.map(\.id).sorted().joined(separator: ","))" }.sorted()
    }

    public static var fileURL: URL {
        Configuration.fileURL.deletingLastPathComponent().appendingPathComponent("pace-history-v1.json")
    }
    public static func load(from url: URL = fileURL) -> Self {
        guard let data = try? Data(contentsOf: url), data.count < 20_000_000,
              let history = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return history
    }
    public func save(to url: URL = fileURL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum ForecastGap: String, Sendable {
    case history, readings, capacity, activity, uncertainty
}

/// Sensitivity-scenario agreement, not a calibrated probability of future correctness.
public struct PacePrediction: Sendable, Equatable {
    public let pace: Pace
    public let agreement: Double
    public init(pace: Pace, agreement: Double) {
        self.pace = pace
        self.agreement = agreement.isFinite ? min(1, max(0, agreement)) : 0
    }
}

public struct PaceForecast: Sendable {
    /// Consensus across the demand band. Nil can still have a tentative central prediction.
    public let pace: Pace?
    public let gap: ForecastGap?
    public let horizon: Date
    public let shortageAt: Date?
    /// Peak cumulative demand / optimistic available capacity, checked before every renewal.
    public let pressureRange: ClosedRange<Double>?
    public let observedHours: Double
    /// Valid observation coverage in the latest two actual hours, separate from older evidence.
    public let recentObservedHours: Double
    public let windowPaces: [String: Pace]
    public let baselineDemand: [String: Double]
    public let recentDemand: [String: Double]
    public internal(set) var prediction: PacePrediction? = nil
    public internal(set) var windowPredictions: [String: PacePrediction] = [:]
    /// Deficits in the displayed central scenario, separate from whole-band shortageAt.
    public internal(set) var predictionDeficits: [String: Date] = [:]
    public internal(set) var projectedDemand: [String: Double] = [:]
    public var displayPrediction: PacePrediction? { prediction ?? pace.map { .init(pace: $0, agreement: 1) } }
    public func displayPrediction(for kind: String) -> PacePrediction? {
        windowPredictions[kind] ?? windowPaces[kind].map { .init(pace: $0, agreement: 1) }
    }

    static func unknown(_ gap: ForecastGap, at now: Date, hours: Double = 0, recentHours: Double = 0) -> Self {
        .init(pace: nil, gap: gap, horizon: now, shortageAt: nil, pressureRange: nil, observedHours: hours, recentObservedHours: recentHours, windowPaces: [:], baselineDemand: [:], recentDemand: [:])
    }
}

/// Recency-weighted seasonal demand + coupled, event-aware fluid quota simulation.
/// Bands are sensitivity bounds, not a claimed calibrated probability of success.
public enum PaceForecaster {
    private static let hour = 3600.0
    private struct Sample {
        let start: Date
        let end: Date
        let rates: [String: Double] // pooled percentage points per hour, NOT percent of pooled capacity
        var hours: Double { end.timeIntervalSince(start) / 3600 }
        var midpoint: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }
    }
    private struct Profile {
        let seasonal: [Int: [String: Double]]
        let exposure: [Int: Double]
        let reference: [String: Double]
        let calendar: Calendar

        func scale(kind: String, at date: Date) -> Double {
            let key = calendar.component(.hour, from: date) + (calendar.isDateInWeekend(date) ? 24 : 0)
            let reference = reference[kind] ?? 0
            let shape = reference > 0 ? (seasonal[key]?[kind] ?? reference) / reference : 1
            let trust = min(1, (exposure[key] ?? 0) / 2)
            return 1 - trust + shape * trust
        }
    }
    private struct Demand {
        let base: [String: Double]
        let fast: [String: Double]
        let expectedFast: [String: Double]
        let spread: [String: Double]
        let profile: Profile
        var calendar: Calendar { profile.calendar }
        let now: Date

        func rates(at date: Date, scenario: Double) -> [String: Double] {
            let future = date.timeIntervalSince(now) / 3600
            let burstWeight = exp(-log(2) * future / 6)
            let weekend = calendar.isDateInWeekend(date)
            let localHour = calendar.component(.hour, from: date)
            let key = localHour + (weekend ? 24 : 0)
            let exposure = profile.exposure[key] ?? 0
            let currentWeekend = calendar.isDateInWeekend(now)
            return base.reduce(into: [String: Double]()) { result, entry in
                let (kind, baseline) = entry
                // The hourly curve is learned, not a hard-coded work schedule. Shrink sparse hours to baseline.
                let level = baseline * profile.scale(kind: kind, at: date)
                let recent = fast[kind] ?? baseline
                // A normal busy afternoon is already represented by the hourly profile.
                // Only activity beyond that hour's expected level is a burst.
                let burst = (recent - (expectedFast[kind] ?? baseline)) * burstWeight
                // A weekday burst must not be extrapolated through an observed inactive weekend (or vice versa).
                let center = max(0, level + (weekend == currentWeekend ? burst : 0))
                let margin = max(baseline * 0.25, spread[kind] ?? 0) * (1 + 0.1 * sqrt(future / 24))
                // An unseen day type brackets silence and continued work. Its uncertainty
                // must not redefine the expected level, just like clipping a negative tail.
                let unseenDayType = weekend != currentWeekend && exposure < 2
                let low = unseenDayType ? 0 : max(0, center - margin)
                let high = unseenDayType ? max(center + margin, recent + margin) : center + margin
                result[kind] = scenario <= 0.5
                    ? low + (center - low) * (scenario * 2)
                    : center + (high - center) * ((scenario - 0.5) * 2)
            }
        }
    }

    public static func forecast(snapshot: QuotaSnapshot, history: PaceHistory, provider: Provider,
                                at now: Date, calendar: Calendar = .current) -> PaceForecast {
        let accounts = snapshot.accounts.filter { !$0.disabled && $0.provider == provider }
        guard !accounts.isEmpty, accounts.allSatisfy({ $0.freshLeft(at: now) != nil }) else {
            return .unknown(.readings, at: now)
        }
        // A percentage of Pro cannot be converted into a percentage of Plus from quota payloads alone.
        // Do not invent exchange rates or imply confidence for heterogeneous/unknown plan capacities.
        guard Set(accounts.compactMap(\.plan)).count == 1, accounts.allSatisfy({ $0.plan != nil }) else {
            return .unknown(.capacity, at: now)
        }
        let kinds = Set(accounts[0].windows.filter { !$0.modelScoped }.map(\.id))
        guard !kinds.isEmpty, kinds.isSubset(of: ["five_hour", "seven_day"]), accounts.allSatisfy({ account in
            Set(account.windows.filter { !$0.modelScoped }.map(\.id)) == kinds &&
            account.windows.filter { !$0.modelScoped }.allSatisfy { window in
                guard let duration = window.duration else { return false }
                if let reset = window.resetsAt {
                    return reset > now && reset.timeIntervalSince(now) <= duration + 60
                }
                return window.usedPercent == 0 // idle window: its clock starts on first simulated use
            }
        }) else { return .unknown(.readings, at: now) }
        guard accounts.allSatisfy({ !$0.unavailable || $0.freshLeft(at: now) == 0 || $0.cooldownUntil.map { $0 > now } == true }) else {
            return .unknown(.readings, at: now)
        }
        let signature = accounts.map { PaceHistory.Account(id: $0.id, provider: provider, plan: $0.plan,
            windows: $0.windows.filter { !$0.modelScoped }, blocked: false) }
        let samples = samples(history: history, provider: provider, signature: signature, kinds: kinds, now: now)
        let comparable = samples.filter { calendar.isDateInWeekend($0.midpoint) == calendar.isDateInWeekend(now) &&
            comparableAge(from: $0.start, to: now, calendar: calendar) <= 24 * hour }
        let hours = comparable.reduce(0) { $0 + $1.hours }
        let recent = samples.filter { now.timeIntervalSince($0.start) <= 2 * hour }
        let recentHours = recent.reduce(0) { $0 + $1.hours }
        // At least six observed hours and recent coverage; never confuse asleep/offline with measured zero use.
        guard hours >= 6, recentHours >= 1.5,
              let latest = samples.last, now.timeIntervalSince(latest.end) < 900 else {
            return .unknown(.history, at: now, hours: hours, recentHours: recentHours)
        }
        // Integer-percentage quotas can stay flat for hours between real increments. Summing
        // only positive five-minute intervals measures endpoint precision, not activity duration.
        let hasMeasuredActivity = comparable.contains { $0.rates.values.contains { $0 > 0.01 } }
        // Exhaustion censors demand: all-zero quota changes do not establish an idle workload.
        let weekdaySamples = samples.filter { !calendar.isDateInWeekend($0.midpoint) }
        let learnedIdleWeekend = calendar.isDateInWeekend(now) &&
            samples.filter { calendar.isDateInWeekend($0.midpoint) }.reduce(0, { $0 + $1.hours }) >= 12 &&
            weekdaySamples.contains { $0.rates.values.contains { $0 > 0.01 } }
        guard hasMeasuredActivity || learnedIdleWeekend else { return .unknown(.activity, at: now, hours: hours, recentHours: recentHours) }
        func average(_ items: [Sample], halfLife: Double, anchor: Date? = nil, calendarAdjusted: Bool = true,
                     value: ((Sample, String) -> Double)? = nil) -> [String: Double] {
            var sums: [String: Double] = [:], weight = 0.0
            for sample in items {
                let age = (calendarAdjusted ? comparableAge(from: sample.end, to: anchor ?? now, calendar: calendar)
                           : (anchor ?? now).timeIntervalSince(sample.end)) / hour
                let w = sample.hours * exp(-log(2) * age / halfLife)
                weight += w
                for kind in kinds { sums[kind, default: 0] += (value?(sample, kind) ?? sample.rates[kind] ?? 0) * w }
            }
            return sums.mapValues { $0 / max(0.001, weight) }
        }
        var base = average(comparable, halfLife: 6)
        var baselineSamples = comparable
        var baselineAnchor = now
        let usingWeekdayBaseline = learnedIdleWeekend && base.values.allSatisfy { $0 < 0.001 }
        if usingWeekdayBaseline, let anchor = weekdaySamples.last?.midpoint {
            let recentWorkday = weekdaySamples.filter { comparableAge(from: $0.start, to: anchor, calendar: calendar) <= 24 * hour }
            base = average(recentWorkday, halfLife: 6, anchor: anchor)
            baselineSamples = recentWorkday
            baselineAnchor = anchor
        }
        let fast = average(recent, halfLife: 0.5, calendarAdjusted: false)
        // Dispersion is calculated on hourly blocks, not thousands of correlated polling points.
        let hourly = Dictionary(grouping: comparable) { Int($0.end.timeIntervalSince1970 / hour) }
        var seasonal: [Int: [String: Double]] = [:], exposure: [Int: Double] = [:]
        var reference: [String: Double] = [:], referenceHours = 0.0
        for sample in samples {
            let weekend = calendar.isDateInWeekend(sample.midpoint)
            let key = calendar.component(.hour, from: sample.midpoint) + (weekend ? 24 : 0)
            exposure[key, default: 0] += sample.hours
            for kind in kinds { seasonal[key, default: [:]][kind, default: 0] += (sample.rates[kind] ?? 0) * sample.hours }
            if weekend == (usingWeekdayBaseline ? false : calendar.isDateInWeekend(now)) {
                referenceHours += sample.hours
                for kind in kinds { reference[kind, default: 0] += (sample.rates[kind] ?? 0) * sample.hours }
            }
        }
        for key in seasonal.keys { seasonal[key] = seasonal[key]!.mapValues { $0 / exposure[key]! } }
        reference = reference.mapValues { $0 / max(0.001, referenceHours) }
        let profile = Profile(seasonal: seasonal, exposure: exposure, reference: reference, calendar: calendar)
        // Remove the hourly pattern from the amplitude estimate before applying it to
        // future hours. Otherwise a daytime-heavy baseline counts the workday twice.
        let baselineShape = average(baselineSamples, halfLife: 6, anchor: baselineAnchor) { sample, kind in
            profile.scale(kind: kind, at: sample.midpoint)
        }
        let amplitude = base.reduce(into: [String: Double]()) { values, entry in
            values[entry.key] = entry.value / max(0.001, baselineShape[entry.key] ?? 1)
        }
        let expectedFast = average(recent, halfLife: 0.5, calendarAdjusted: false) { sample, kind in
            (amplitude[kind] ?? 0) * profile.scale(kind: kind, at: sample.midpoint)
        }
        var spread: [String: Double] = [:]
        for kind in kinds {
            let rates = hourly.values.map { block in
                block.reduce(0) { $0 + ($1.rates[kind] ?? 0) * $1.hours } / block.reduce(0) { $0 + $1.hours }
            }.sorted()
            let lo = rates[Int(Double(rates.count - 1) * 0.1)]
            let hi = rates[Int(Double(rates.count - 1) * 0.9)]
            spread[kind] = max((hi - lo) / 2, abs((fast[kind] ?? 0) - (expectedFast[kind] ?? 0)) * 0.25)
        }
        guard base.values.allSatisfy({ $0 > 0.001 }) else { return .unknown(.activity, at: now, hours: hours, recentHours: recentHours) }
        let demand = Demand(base: amplitude, fast: fast, expectedFast: expectedFast, spread: spread, profile: profile, now: now)
        // Look through every current weekly renewal, at least a whole day, at most a week.
        let lastWeekly = accounts.flatMap(\.windows).filter { $0.id == "seven_day" }.map {
            $0.resetsAt ?? now.addingTimeInterval(7 * 86400)
        }.max()
        let horizon = max(now.addingTimeInterval(24 * hour), lastWeekly ?? now)
        // Evaluate five sensitivity levels anchored at the modeled central demand. Check
        // both routing policies; a greedy failure without a deficit certificate stays unclassified.
        let scenarios = (0...4).map { step -> (Simulation, Simulation) in
            let level = Double(step) / 4
            return (simulate(accounts: accounts, demand: demand, now: now, until: horizon, scenario: level, balanced: false),
                    simulate(accounts: accounts, demand: demand, now: now, until: horizon, scenario: level, balanced: true))
        }
        let low = scenarios[0].0, high = scenarios[4].0, fair = scenarios[4].1
        // Orange requires a mathematical pooled-capacity deficit even under LOW demand. A routing heuristic
        // failing is NOT proof of unavoidable exhaustion. Blue/green require both feasible routing policies.
        let pace: Pace?
        if low.unavoidableShortage != nil { pace = .over }
        else if high.shortage == nil && fair.shortage == nil {
            if max(high.pressure, fair.pressure) < 0.5 { pace = .under }
            else if low.pressure >= 0.5 { pace = .steady }
            else { pace = nil } // straddles the blue/green boundary
        } else { pace = nil }
        var windowPaces: [String: Pace] = [:]
        for kind in kinds {
            if low.deficits[kind] != nil { windowPaces[kind] = .over }
            else if high.shortage == nil && fair.shortage == nil {
                if max(high.pressures[kind] ?? 0, fair.pressures[kind] ?? 0) < 0.5 { windowPaces[kind] = .under }
                else if (low.pressures[kind] ?? 0) >= 0.5 { windowPaces[kind] = .steady }
            }
        }
        func classify(_ pair: (Simulation, Simulation), kind: String? = nil) -> Pace? {
            if let kind {
                if pair.0.deficits[kind] != nil { return .over }
            } else if pair.0.unavoidableShortage != nil { return .over }
            guard pair.0.shortage == nil, pair.1.shortage == nil else { return nil }
            let pressure = kind.map { max(pair.0.pressures[$0] ?? 0, pair.1.pressures[$0] ?? 0) }
                ?? max(pair.0.pressure, pair.1.pressure)
            return pressure < 0.5 ? .under : .steady
        }
        func prediction(kind: String? = nil) -> PacePrediction? {
            guard let center = classify(scenarios[2], kind: kind) else { return nil }
            let matches = scenarios.filter { classify($0, kind: kind) == center }.count
            return .init(pace: center, agreement: Double(matches) / Double(scenarios.count))
        }
        var result = PaceForecast(pace: pace, gap: pace == nil ? .uncertainty : nil, horizon: horizon,
                     shortageAt: pace == .over ? low.unavoidableShortage : nil,
                     pressureRange: min(low.pressure, high.pressure)...max(low.pressure, high.pressure, fair.pressure), observedHours: hours, recentObservedHours: recentHours, windowPaces: windowPaces, baselineDemand: base, recentDemand: fast)
        result.prediction = prediction()
        result.windowPredictions = kinds.reduce(into: [:]) { values, kind in values[kind] = prediction(kind: kind) }
        result.predictionDeficits = scenarios[2].0.deficits
        result.projectedDemand = scenarios[2].0.demand
        return result
    }

    private static func comparableAge(from start: Date, to end: Date, calendar: Calendar) -> Double {
        // Count comparable hours: Monday remembers Friday; Saturday remembers the previous weekend.
        let weekend = calendar.isDateInWeekend(end)
        var cursor = start, total = 0.0
        while cursor < end {
            let next = min(end, calendar.startOfDay(for: cursor).addingTimeInterval(36 * hour))
            let boundary = min(end, calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cursor)) ?? next)
            if calendar.isDateInWeekend(cursor) == weekend { total += boundary.timeIntervalSince(cursor) }
            cursor = boundary
        }
        return total
    }

    private static func samples(history: PaceHistory, provider: Provider, signature: [PaceHistory.Account], kinds: Set<String>, now: Date) -> [Sample] {
        var result: [Sample] = []
        // Only the current uninterrupted enabled-fleet epoch. Quota changes can include direct-client use.
        let ids = signature.map(\.id).sorted()
        let plan = signature.first?.plan
        var previous: PaceHistory.Frame?
        for frame in history.frames where frame.date <= now {
            let accounts = frame.accounts.filter { $0.provider == provider }
            guard accounts.map(\.id).sorted() == ids,
                  !accounts.contains(where: { account in
                      (account.plan != nil && account.plan != plan) ||
                      (!account.windows.isEmpty && Set(account.windows.map(\.id)) != kinds)
                  }) else { previous = nil; result = []; continue }
            // Startup and failed probes can lack metadata without changing the enabled fleet.
            // Keep earlier evidence, but never measure across the unreadable interval. This also
            // recovers history already written by older app versions without editing the file.
            guard accounts.allSatisfy({ $0.plan != nil && !$0.windows.isEmpty }) else {
                previous = nil; continue
            }
            defer { previous = frame }
            guard let previous else { continue }
            let interval = frame.date.timeIntervalSince(previous.date)
            guard interval >= 60, interval <= 900 else { continue }
            let old = previous.accounts.filter { $0.provider == provider }
            guard !old.allSatisfy({ $0.blocked || $0.windows.contains { $0.usedPercent == 100 } }),
                  !accounts.allSatisfy({ $0.blocked || $0.windows.contains { $0.usedPercent == 100 } }) else { continue }
            var rates: [String: Double] = [:], valid = true
            for account in accounts {
                guard let before = old.first(where: { $0.id == account.id }) else { valid = false; break }
                for kind in kinds {
                    guard let a = before.windows.first(where: { $0.id == kind }),
                          let b = account.windows.first(where: { $0.id == kind }),
                          let u0 = a.usedPercent, let u1 = b.usedPercent,
                          a.isFresh(at: previous.date), b.isFresh(at: frame.date),
                          b.observedAt > a.observedAt, b.observedAt.timeIntervalSince(a.observedAt) <= 900,
                          u1 >= u0, sameCycle(a, b) else { valid = false; break }
                    rates[kind, default: 0] += (u1 - u0) / (b.observedAt.timeIntervalSince(a.observedAt) / hour)
                }
            }
            if valid { result.append(Sample(start: previous.date, end: frame.date, rates: rates)) }
        }
        return result
    }

    private static func sameCycle(_ a: QuotaWindow, _ b: QuotaWindow) -> Bool {
        // An unused allowance can report a sliding reset until its clock starts. Two fresh,
        // advancing zero readings still measure zero demand; they are not a spent-cycle reset.
        if a.usedPercent == 0 && b.usedPercent == 0 { return true }
        if let x = a.resetsAt, let y = b.resetsAt { return abs(x.timeIntervalSince(y)) < 60 && x > b.observedAt }
        return a.resetsAt == nil && a.usedPercent == 0 // starting a previously idle cycle is observable
    }

    private struct Limit {
        var left: Double
        var reset: Date?
        let duration: Double
    }
    private struct Supply {
        var limits: [String: Limit]
        let cooldown: Date?
    }
    private struct Simulation {
        var pressure = 0.0
        var shortage: Date?
        var unavoidableShortage: Date?
        var pressures: [String: Double] = [:]
        var deficits: [String: Date] = [:]
        var demand: [String: Double] = [:]
    }

    private static func simulate(accounts: [SubscriptionAccount], demand: Demand, now: Date, until end: Date,
                                 scenario: Double, balanced: Bool) -> Simulation {
        var supply = accounts.map { account in
            Supply(limits: Dictionary(uniqueKeysWithValues: account.windows.filter { !$0.modelScoped }.map {
                ($0.id, Limit(left: $0.leftPercent ?? 0, reset: $0.resetsAt, duration: $0.duration ?? 0))
            }), cooldown: account.cooldownUntil)
        }
        // Independent optimistic capacity envelope: bank even unused quota and allow the earliest possible
        // next cycle. A demand deficit against this upper bound proves a shortage regardless of routing.
        var granted: [String: Double] = [:], consumed: [String: Double] = [:]
        var grants: [(date: Date, kind: String)] = []
        for account in accounts {
            for window in account.windows where !window.modelScoped {
                granted[window.id, default: 0] += window.leftPercent ?? 0
                var reset = window.resetsAt ?? now.addingTimeInterval(window.duration!)
                while reset < end {
                    grants.append((reset, window.id))
                    reset = reset.addingTimeInterval(window.duration!)
                }
            }
        }
        grants.sort { $0.date < $1.date }
        var grantIndex = 0
        var time = now, result = Simulation()
        while time < end {
            for i in supply.indices {
                for key in supply[i].limits.keys {
                    if let reset = supply[i].limits[key]?.reset, reset <= time {
                        supply[i].limits[key]?.left = 100
                        supply[i].limits[key]?.reset = nil // idle until used, no banked renewals
                    }
                }
            }
            while grantIndex < grants.count && grants[grantIndex].date <= time {
                granted[grants[grantIndex].kind, default: 0] += 100
                grantIndex += 1
            }
            let events = supply.flatMap { s in s.limits.values.compactMap(\.reset) + [s.cooldown].compactMap { $0 } }.filter { $0 > time }
            let nextGrant = grantIndex < grants.count ? grants[grantIndex].date : end
            let nextHour = demand.calendar.dateInterval(of: .hour, for: time)?.end ?? time.addingTimeInterval(hour)
            let next = min(end, time.addingTimeInterval(300), events.min() ?? end, nextGrant, nextHour)
            let dt = next.timeIntervalSince(time) / hour
            let rates = demand.rates(at: time, scenario: scenario)
            let ready = supply.indices.filter { supply[$0].cooldown.map { $0 <= time } ?? true }
            // Each account can accept only the workload allowed by BOTH its session and its weekly balance.
            func room(_ i: Int) -> Double {
                rates.compactMap { key, rate in rate > 0 ? (supply[i].limits[key]?.left ?? 0) / rate : nil }.min() ?? .infinity
            }
            let totalRoom = ready.reduce(0) { $0 + room($1) }
            for (kind, rate) in rates where rate > 0 {
                consumed[kind, default: 0] += rate * dt
                let available = granted[kind] ?? 0
                let pressure = available > 0 ? consumed[kind, default: 0] / available : 1e6
                result.pressure = max(result.pressure, pressure)
                result.pressures[kind] = max(result.pressures[kind] ?? 0, pressure)
                if pressure > 1 + 1e-8 {
                    result.unavoidableShortage = result.unavoidableShortage ?? time
                    result.deficits[kind] = result.deficits[kind] ?? time
                }
            }
            if totalRoom + 1e-8 < dt {
                result.shortage = result.shortage ?? time
                // Continue to renewals to expose deficits beyond the first blocked interval.
            }
            var remaining = dt
            let order = ready.sorted { a, b in
                if balanced { return room(a) > room(b) }
                let ar = supply[a].limits.values.compactMap(\.reset).min() ?? .distantFuture
                let br = supply[b].limits.values.compactMap(\.reset).min() ?? .distantFuture
                return ar == br ? a < b : ar < br
            }
            // Balanced routing splits demand in proportion to each account's coupled headroom.
            let originalRoom = totalRoom
            for i in order where remaining > 1e-10 {
                let amount = balanced && originalRoom.isFinite && originalRoom > 0
                    ? min(remaining, dt * room(i) / originalRoom, room(i)) : min(remaining, room(i))
                guard amount > 0 else { continue }
                for (kind, rate) in rates where rate > 0 {
                    guard var limit = supply[i].limits[kind] else { continue }
                    if limit.reset == nil { limit.reset = time.addingTimeInterval(limit.duration) }
                    limit.left = max(0, limit.left - amount * rate)
                    supply[i].limits[kind] = limit
                }
                remaining -= amount
            }
            time = next
        }
        result.demand = consumed
        return result
    }
}
