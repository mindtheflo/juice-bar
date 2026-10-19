import AppKit
import SwiftUI
import QuotaCore

@MainActor
final class QuotaStore: ObservableObject {
    @Published var snapshot: QuotaSnapshot?
    @Published var forecasts: [Provider: PaceForecast] = [:]
    private var paceHistory = PaceHistory()
    private var forecastMinute: Int?
    @Published var busy = false
    @Published var error: String?
    @Published var accountUpdating: String?
    @Published var accountUpdateError: String?
    @Published var now = Date()
    @Published var configuration: Configuration
    @Published var iconPreferences = IconPreferences.load() {
        didSet { iconPreferences.save() }
    }
    var iconMetrics: [IconMetric] {
        IconMetrics.bars(snapshot: snapshot, preferences: iconPreferences, at: now, offline: error != nil, forecasts: currentForecasts)
    }
    var currentForecasts: [Provider: PaceForecast] {
        guard error == nil, let snapshot else { return [:] }
        return forecasts.filter { provider, _ in
            snapshot.accounts.filter { !$0.disabled && $0.provider == provider }.allSatisfy { $0.freshLeft(at: now) != nil }
        }
    }
    var iconDescription: String {
        guard error == nil else { return Copy.text("tooltipOffline") }
        return Copy.menuBarForecast(snapshot: snapshot, forecasts: currentForecasts, now: now)
    }
    let demo: Bool
    private var client: ProxyClient
    private var loop: Task<Void, Never>?
    private var clock: Task<Void, Never>?

    init(demo: Bool = false) {
        self.demo = demo
        let initial = demo ? Configuration() : Configuration.load()
        configuration = initial
        client = ProxyClient(configuration: initial)
        if !demo { paceHistory = PaceHistory.load() }
        if paceHistory.source != initial.paceHistorySource { paceHistory = PaceHistory(source: initial.paceHistorySource) }
        if demo { snapshot = Demo.snapshot(at: now) }
    }
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        clock = Task { [weak self] in
            while !Task.isCancelled {
                self?.now = Date()
                self?.updateForecasts()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }
    func refresh(force: Bool = false) async {
        guard !busy else { return }
        now = Date()
        if demo { return }
        busy = true
        defer { busy = false }
        do {
            snapshot = try await client.fetch(previous: snapshot, force: force)
            error = nil
            if let snapshot {
                recordHistory(snapshot)
            }
            updateForecasts(force: true)
        } catch {
            self.error = (error as? ProxyError)?.localizedDescription ?? ProxyError.unavailable.localizedDescription
        }
    }
    func setAccountEnabled(_ account: SubscriptionAccount, enabled: Bool) async {
        guard !busy, accountUpdating == nil else { return }
        busy = true; accountUpdating = account.id; accountUpdateError = nil
        defer { busy = false; accountUpdating = nil }
        do {
            let updated: SubscriptionAccount
            if demo {
                var preview = account; preview.disabled = !enabled; updated = preview
            } else {
                updated = try await client.setAccountEnabled(account, enabled: enabled)
            }
            if let index = snapshot?.accounts.firstIndex(where: { $0.id == account.id }) {
                snapshot?.accounts[index] = updated
                if var current = snapshot {
                    current.fetchedAt = Date()
                    recordHistory(current)
                }
                updateForecasts(force: true)
            }
        } catch {
            accountUpdateError = Copy.text("accountUpdateFailed")
            // Recover the current display from a read, without replaying the mutation.
            if !demo, let current = try? await client.fetch(previous: snapshot) {
                snapshot = current
                recordHistory(current)
                updateForecasts(force: true)
            }
        }
    }
    func configure(_ new: Configuration) throws {
        guard !busy else { return }
        try new.save()
        configuration = new
        client = ProxyClient(configuration: new)
        if paceHistory.source != new.paceHistorySource {
            paceHistory = PaceHistory(source: new.paceHistorySource)
            try? paceHistory.save()
        }
        forecasts = [:]
        snapshot = nil
        error = nil
        Task { await refresh(force: true) }
    }
    private func recordHistory(_ snapshot: QuotaSnapshot) {
        guard !demo else { return }
        let last = paceHistory.frames.last?.date
        paceHistory.record(snapshot)
        if paceHistory.frames.last?.date != last { try? paceHistory.save() }
    }
    private func updateForecasts(force: Bool = false) {
        let minute = Int(now.timeIntervalSince1970 / 60)
        guard force || minute != forecastMinute else { return }
        forecastMinute = minute
        guard let snapshot else { forecasts = [:]; return }
        forecasts = Dictionary(uniqueKeysWithValues: Provider.allCases.map { provider in
            (provider, PaceForecaster.forecast(snapshot: snapshot, history: paceHistory, provider: provider, at: now))
        })
    }
    func openDashboard() {
        if let url = configuration.dashboardURL { NSWorkspace.shared.open(url) }
    }
}
