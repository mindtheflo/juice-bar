import AppKit
import SwiftUI
import QuotaCore

/// The highlight under a clickable line while the pointer is over it. The line's text stays as it is.
struct HoverHighlight: ViewModifier {
    var enabled = true
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(hovered && enabled ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 5))
            .onHover { hovered = $0 }
    }
}

extension View {
    func hoverHighlight(_ enabled: Bool = true) -> some View { modifier(HoverHighlight(enabled: enabled)) }
}

struct MenuRow: View {
    let title: String
    /// What the row does, for VoiceOver, when its title says something else.
    var actionTitle: String? = nil
    var shortcut: String? = nil
    var disabled = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 10).frame(height: 23)
            .contentShape(Rectangle())
            .hoverHighlight(!disabled)
        }
        .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.5 : 1)
        .accessibilityLabel(actionTitle ?? title)
        .accessibilityValue(actionTitle == nil ? "" : title)
    }
}

/// A provider's section title. Hovering it shows the switch that shows or hides its disabled accounts.
struct ProviderHeader: View {
    let provider: Provider
    let disabledCount: Int
    @Binding var hidesDisabled: Bool
    @State private var hovered = false
    @State private var buttonHovered = false
    private var toggleTitle: String { Copy.text(hidesDisabled ? "showDisabled" : "hideDisabled") }
    var body: some View {
        HStack {
            Text(provider.title).fontWeight(.medium)
            Spacer()
            if hovered && disabledCount > 0 {
                Button { hidesDisabled.toggle() } label: {
                    Text(toggleTitle).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(buttonHovered ? .primary : .secondary)
                        .padding(.horizontal, 8).frame(height: 19)
                        .background(Color.primary.opacity(buttonHovered ? 0.14 : 0.07), in: Capsule())
                        .contentShape(Capsule())
                }.buttonStyle(.plain).onHover { buttonHovered = $0 }
            }
        }
        .foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 25)
        .contentShape(Rectangle()).onHover { hovered = $0; if !$0 { buttonHovered = false } }
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if disabledCount > 0 { Button(toggleTitle) { hidesDisabled.toggle() } }
        }
    }
}

struct SubscriptionPanel: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var updater: Updater
    @AppStorage("hideAccountNames") private var hideNames = false
    @AppStorage("language") private var language = "auto"
    @AppStorage("hideDisabledCodex") private var hideDisabledCodex = false
    @AppStorage("hideDisabledClaude") private var hideDisabledClaude = false
    @State private var selected: String?
    @State private var settings = false
    @State private var hoveredAccount: String?
    @State private var hoveredLimit: String?
    /// Weekly renewals can switch to dates; five-hour sessions always keep a countdown.
    @State private var renewalDates = false

    var body: some View {
        VStack(spacing: 0) {
            if settings {
                ConnectionSettings(store: store, updater: updater, back: { settings = false })
            } else if let selected, let account = store.snapshot?.accounts.first(where: { $0.id == selected }) {
                detail(account)
            } else { overview }
        }
        .font(.system(size: 13)).frame(width: 350).padding(5)
        .onAppear {
            store.start()
            if store.demo, let index = CommandLine.arguments.firstIndex(of: "--demo-page"),
               CommandLine.arguments.indices.contains(index + 1) {
                switch CommandLine.arguments[index + 1] {
                case "account": selected = "demo-claude-4"
                case "settings": settings = true
                default: break
                }
            }
        }
        .onChange(of: language) { _ in }
    }
    private var separator: some View { Divider().padding(.horizontal, 10).padding(.vertical, 5) }
    private func hidesDisabled(_ provider: Provider) -> Binding<Bool> {
        provider == .codex ? $hideDisabledCodex : $hideDisabledClaude
    }
    private func shown(_ accounts: [SubscriptionAccount]) -> [SubscriptionAccount] {
        accounts.filter { !$0.disabled || !hidesDisabled($0.provider).wrappedValue }
    }
    private func name(_ account: SubscriptionAccount) -> String {
        if !hideNames { return account.label }
        let accounts = store.snapshot?.accounts.filter { $0.provider == account.provider } ?? []
        let ordinal = (accounts.firstIndex(where: { $0.id == account.id }) ?? 0) + 1
        return "\(account.provider.title) \(ordinal)"
    }
    private var overview: some View {
        VStack(spacing: 0) {
            if store.snapshot == nil {
                Text(store.error == nil ? Copy.text("loading") : Copy.text("offline"))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            if let snapshot = store.snapshot {
                if snapshot.accounts.isEmpty { Text(Copy.text("empty")).padding(10).foregroundStyle(.secondary) }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Provider.allCases, id: \.self) { provider in
                            let accounts = snapshot.accounts.filter { $0.provider == provider }
                            if !accounts.isEmpty {
                                ProviderHeader(provider: provider, disabledCount: accounts.filter(\.disabled).count,
                                               hidesDisabled: hidesDisabled(provider))
                                    .help(Copy.forecast(store.currentForecasts[provider], now: store.now))
                                ForEach(shown(accounts)) { account in accountRow(account) }
                                if provider == .codex { separator }
                            }
                        }
                    }
                }.frame(height: min(330, CGFloat(shown(snapshot.accounts).count) * 25 + 70))
            }
            if let error = store.error {
                Text(Copy.isFrench ? Copy.text("unknownError") : error)
                    .font(.system(size: 11)).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            footer
        }
    }
    private func accountPercentages(_ account: SubscriptionAccount) -> String {
        let shared = account.windows.filter { !$0.modelScoped }
        func percent(_ window: QuotaWindow) -> String {
            let current = store.error == nil && account.readError == nil && window.isFresh(at: store.now)
            let label = window.id == "five_hour" ? "session" : window.id == "seven_day" ? "weekly" : window.id
            let value = window.leftPercent.map { "\(Int($0.rounded()))%" } ?? Copy.text("noReading")
            return Copy.text(label) + " " + (current ? "" : Copy.text("lastKnown") + " · ") + value
        }
        return shared.isEmpty ? Copy.text("noReading") : shared.sorted { $0.id < $1.id }.map(percent).joined(separator: " · ")
    }

    private func accountRow(_ account: SubscriptionAccount) -> some View {
        let window = account.tightestWindow
        let left = account.freshLeft(at: store.now)
        let tone = store.error == nil ? account.tone(at: store.now) : .unknown
        let reset = account.cooldownUntil.flatMap { $0 > store.now ? $0 : nil } ?? window?.resetsAt
        return HStack(spacing: 8) {
            Button { store.accountUpdateError = nil; selected = account.id } label: {
                HStack(spacing: 10) {
                    if account.provider == .claude {
                        HStack(spacing: 3) {
                            quotaBar(account.claudeRowWindows[0], account: account, label: Copy.text("session"))
                            quotaBar(account.claudeRowWindows[1], account: account, label: Copy.text("weekly"))
                        }
                    } else {
                        LevelCapsule(left: store.error == nil ? left : nil, tone: account.disabled ? .unknown : tone)
                    }
                    Text(hoveredAccount == account.id ? accountPercentages(account) : name(account))
                        .font(.system(size: hoveredAccount == account.id ? 11 : 13))
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 25)
                    .contentShape(Rectangle()).hoverHighlight()
            }
            .buttonStyle(.plain)
            .onHover { hoveredAccount = $0 ? account.id : nil }
            .help(account.readError ?? Copy.text("percentageHint"))
            .accessibilityLabel(name(account) + (account.disabled ? ", " + Copy.text("disabled") : ""))
            .accessibilityValue(accountPercentages(account))
            .accessibilityHint(Copy.text("accountDetails"))
            if let reset, reset > store.now { renewal(reset, relativeOnly: window?.id == "five_hour") }
        }
        .padding(.horizontal, 10).frame(height: 25)
        .foregroundStyle(account.disabled ? .secondary : .primary)
    }
    private func quotaBar(_ window: QuotaWindow?, account: SubscriptionAccount, label: String) -> some View {
        let current = account.readError == nil && store.error == nil && window?.isFresh(at: store.now) == true
        let tone = current ? window?.tone(at: store.now) ?? .unknown : .unknown
        return LevelCapsule(left: current ? window?.leftPercent : nil, tone: account.disabled ? .unknown : tone)
            .help(label + ": " + Copy.percent(window?.leftPercent))
    }
    /// Session renewals always show elapsed-relative time; longer windows can switch to a date.
    private func renewal(_ reset: Date, relativeOnly: Bool = false) -> some View {
        let relative = Copy.duration(reset, now: store.now) ?? ""
        let absolute = renewalDates && !relativeOnly
        let text = absolute ? Copy.text("on") + " " + Copy.moment(reset, now: store.now)
                            : Copy.text("in") + " " + relative
        let label = Text(text).font(.system(size: 11)).monospacedDigit().lineLimit(1)
            .foregroundStyle(.secondary).padding(.vertical, 4)
        return Group {
            if relativeOnly { label }
            else {
                Button { renewalDates.toggle() } label: {
                    label.contentShape(Rectangle()).hoverHighlight()
                }.buttonStyle(.plain)
            }
        }
        .layoutPriority(1)
        .help((relativeOnly ? "" : Copy.text("timeHint") + " ") + Copy.text("on") + " " + Copy.timestamp(reset, now: store.now, includeDate: true))
        .accessibilityLabel(absolute ? Copy.text("renews") + " " + text : Copy.text("renewsIn", relative))
    }
    private func detail(_ account: SubscriptionAccount) -> some View {
        VStack(spacing: 0) {
            Button { selected = nil } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text(name(account)).fontWeight(.medium).lineLimit(1)
                    Spacer()
                    if let plan = account.plan { Text(plan).foregroundStyle(.secondary) }
                }.frame(height: 29).padding(.horizontal, 10).contentShape(Rectangle()).hoverHighlight()
            }.buttonStyle(.plain).accessibilityLabel(Copy.text("back"))
            separator
            HStack {
                Text(Copy.text("accountEnabled"))
                Spacer()
                Toggle(Copy.text("accountEnabled"), isOn: Binding(
                    get: { !account.disabled },
                    set: { enabled in Task { await store.setAccountEnabled(account, enabled: enabled) } }
                )).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(store.busy || store.accountUpdating != nil)
                if store.accountUpdating == account.id { ProgressView().controlSize(.mini).accessibilityLabel(Copy.text("accountUpdating")) }
            }.padding(.horizontal, 10).padding(.vertical, 4)
            if let updateError = store.accountUpdateError {
                Text(updateError).font(.system(size: 11)).foregroundStyle(.red)
                    .padding(.horizontal, 10).padding(.vertical, 4)
            }
            separator
            ForEach(account.windows) { window in
                let fresh = window.isFresh(at: store.now) && account.readError == nil && store.error == nil
                let tone = fresh ? window.tone(at: store.now) : .unknown
                let percentage = window.leftPercent.map { "\(Int($0.rounded()))\(Copy.text("left"))" } ?? Copy.text("noReading")
                let value = (fresh ? "" : Copy.text("lastKnown") + " · ") + percentage
                HStack(spacing: 10) {
                    LevelCapsule(left: fresh ? window.leftPercent : nil, tone: tone)
                    Text(hoveredLimit == window.id ? value : Copy.text(window.id))
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle()).onHover { hoveredLimit = $0 ? window.id : nil }
                        .help(Copy.text(window.id) + ": " + value)
                        .accessibilityLabel(Copy.text(window.id)).accessibilityValue(value)
                    if let reset = window.resetsAt {
                        if reset > store.now { renewal(reset, relativeOnly: window.id == "five_hour") }
                        else { Text(Copy.text("awaiting")).font(.system(size: 11)).foregroundStyle(.secondary) }
                    } else if window.id == "five_hour" {
                        Text(Copy.text(fresh && window.usedPercent == 0 ? "sessionIdle" : "renewalUnknown"))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            .help(Copy.text(fresh && window.usedPercent == 0 ? "sessionIdleHint" : "renewalUnknown"))
                    }
                }.padding(.horizontal, 10).frame(height: 27)
            }
            if let cooldown = account.cooldownUntil, cooldown > store.now {
                note(Copy.text("cooldown") + " " + Copy.timestamp(cooldown, now: store.now, includeDate: true))
            }
            if let error = account.readError { note(Copy.isFrench ? Copy.text("unknownError") : error) }
            if let extra = account.extraUsageEnabled { note(Copy.text(extra ? "extraOn" : "extraOff")) }
            if account.unlimitedCredits { note(Copy.text("credits") + ": " + Copy.text("unlimited")) }
            else if let credits = account.paidCredits { note(Copy.text("credits") + ": " + credits.formatted(.number.precision(.fractionLength(0...2)))) }
            if let grants = account.resetGrantsLeft, grants > 0 { note(Copy.text("resetGrant") + ": \(grants)") }
            footer
        }
    }
    private func note(_ title: String) -> some View {
        Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 3)
    }
    private var footer: some View {
        VStack(spacing: 0) {
            separator
            MenuRow(title: store.busy ? Copy.text("refreshing") : store.snapshot.map { snapshot in
                let checked = selected.flatMap { id in snapshot.accounts.first { $0.id == id }?.checkedAt } ?? snapshot.fetchedAt
                return Copy.text("updated") + " " + Copy.timestamp(checked, now: store.now)
            } ?? Copy.text("refresh"), actionTitle: Copy.text("refresh"), shortcut: "⌘R", disabled: store.busy) {
                Task { await store.refresh(force: true) }
            }.keyboardShortcut("r", modifiers: .command)
            MenuRow(title: Copy.text("dashboard")) { store.openDashboard() }
            MenuRow(title: Copy.text("settings"), shortcut: "⌘,") { settings = true }.keyboardShortcut(",", modifiers: .command)
            switch updater.phase {
            case .available: MenuRow(title: Copy.text("updateMenu")) { Task { await updater.install() } }
            case .ready: MenuRow(title: Copy.text("restartMenu")) { updater.restart() }
            default: EmptyView()
            }
            separator
            MenuRow(title: Copy.text("quit"), shortcut: "⌘Q") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
            if store.demo {
                Text(Copy.text("demo")).font(.system(size: 10)).foregroundStyle(.tertiary).padding(.vertical, 5)
            }
        }
    }
}
