import Foundation
import QuotaCore

@main
enum QuotaCheck {
    static func main() async {
        do {
            let snapshot = try await ProxyClient(configuration: .load()).fetch(force: true)
            var history = PaceHistory.load()
            if history.source != Configuration.load().paceHistorySource { history = PaceHistory() }
            let forecasts = Provider.allCases.map { provider -> [String: JSONValue] in
                let estimate = PaceForecaster.forecast(snapshot: snapshot, history: history, provider: provider, at: snapshot.fetchedAt)
                return ["provider": .string(provider.rawValue),
                        "pace": estimate.pace.map { .string($0.rawValue) } ?? .null,
                        "prediction": estimate.displayPrediction.map { .string($0.pace.rawValue) } ?? .null,
                        "scenario_agreement": estimate.displayPrediction.map { .number($0.agreement) } ?? .null,
                        "window_predictions": .object(estimate.windowPredictions.mapValues { .object([
                            "pace": .string($0.pace.rawValue), "scenario_agreement": .number($0.agreement)
                        ]) }),
                        "neutral_reason": estimate.gap.map { .string($0.rawValue) } ?? .null,
                        "observed_hours": .number(estimate.observedHours),
                        "recent_observed_hours": .number(estimate.recentObservedHours),
                        "window_paces": .object(estimate.windowPaces.mapValues { .string($0.rawValue) }),
                        "baseline_points_per_hour": .object(estimate.baselineDemand.mapValues { .number($0) }),
                        "recent_points_per_hour": .object(estimate.recentDemand.mapValues { .number($0) }),
                        "projected_points": .object(estimate.projectedDemand.mapValues { .number($0) }),
                        "prediction_deficits": .object(estimate.predictionDeficits.mapValues {
                            .string(ISO8601DateFormatter().string(from: $0))
                        }),
                        "pressure_low": estimate.pressureRange.map { .number($0.lowerBound) } ?? .null,
                        "pressure_high": estimate.pressureRange.map { .number($0.upperBound) } ?? .null,
                        "horizon": .string(ISO8601DateFormatter().string(from: estimate.horizon)),
                        "shortage_at": estimate.shortageAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null]
            }
            var ordinals: [Provider: Int] = [:]
            let showNames = CommandLine.arguments.contains("--show-names")
            let output: [[String: JSONValue]] = snapshot.accounts.map { account in
                ordinals[account.provider, default: 0] += 1
                return [
                    "account": .string(showNames ? account.label : "\(account.provider.title) \(ordinals[account.provider]!)"),
                    "provider": .string(account.provider.rawValue), "plan": account.plan.map(JSONValue.string) ?? .null,
                    "disabled": .bool(account.disabled), "proxy_unavailable": .bool(account.unavailable),
                    "left_percent": account.freshLeft(at: snapshot.fetchedAt).map(JSONValue.number) ?? .null,
                    "cooldown_until": account.cooldownUntil.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
                    "read_error": account.readError.map(JSONValue.string) ?? .null,
                    "windows": .array(account.windows.map { window in
                        return .object([
                            "window": .string(window.id), "used_percent": window.usedPercent.map(JSONValue.number) ?? .null,
                            "resets_at": window.resetsAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
                        ])
                    }),
                ]
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(JSONValue.object(["forecasts": .array(forecasts.map { .object($0) }),
                                                                  "accounts": .array(output.map { .object($0) })]))
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
            if snapshot.accounts.contains(where: { !$0.disabled && $0.readError != nil }) { exit(2) }
        } catch {
            let safe = (error as? ProxyError)?.localizedDescription ?? ProxyError.unavailable.localizedDescription
            FileHandle.standardError.write(Data((safe + "\n").utf8)); exit(1)
        }
    }
}
