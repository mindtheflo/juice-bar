# Development and operations

Juice Bar connects directly to CLIProxyAPI. The retired dashboard plugin only provided a launch page; the native app has no plugin dependency.

## Requirements

- macOS 13 or later and Xcode Command Line Tools with Swift 6 or later.
- CPAMC backed by a running local CLIProxyAPI. Tested with CLIProxyAPI 8.0.4 and CPAMC 1.26.2.
- Its management key available in a local text file. CPAMC's dashboard password is the management key, not a client API key.

## Build and install

```sh
git clone https://github.com/mindtheflo/juice-bar.git
cd juice-bar
swift test
bash scripts/install.sh
```

The installer builds the app from source into `.build/app`, replaces any earlier Juice Bar in `~/Applications/Juice Bar.app`, keeps your settings and opens it. Add `--login` to start Juice Bar at login, or turn on **Launch at login** in Settings. A build of `nightly`, the default branch, updates itself once the branch it follows includes its commit: `stable`, unless you choose **Nightly** in **Settings › Updates**. A build with uncommitted changes never does.

An app you build yourself is never quarantined, so it opens without Apple notarization. Local builds are ad-hoc signed; to sign with your own Developer ID certificate, pass its identity:

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" bash scripts/install.sh
```

`bash scripts/build.sh` writes the app and zip to `dist/`. The repository includes them, signed but not notarized: a copy downloaded with a browser is quarantined and blocked by Gatekeeper, so prefer building from source.

There is no standalone app window or Dock icon: the subscription panel is a compact, arrow-free dropdown anchored to the menu-bar icon. It closes on an outside click or Escape. Its two allowance bars appear in the macOS menu bar. Click them to inspect subscriptions, or choose **Open CPAMC** to open the existing quota dashboard.

## Updates

Juice Bar updates itself from source, so it needs no notarization or update server. Once a day it asks GitHub for the latest commit of the branch it follows: `stable` for releases, or `nightly` for every change as soon as it is merged. When there is a new one, it fetches it into `~/Library/Application Support/Juice Bar`, builds it with that commit's `scripts/build.sh` and the running app's signing identity, and checks the result: commit, app identifier, signature and team. The new version replaces the app while its menu is closed, right away or as soon as you close it, and reopens in the background. Settings and the login item are kept.

- Choose the branch in **Settings › Updates**, which also shows the state, the version and the commit it was built from. A new branch is checked right away.
- Only a clean build is replaced, and only by a later commit of its branch: a withdrawn release is never replaced by an older or different commit, and after switching from Nightly back to Stable the app keeps its version until Stable includes it.
- Turn off **Update automatically** to update only with **Check now** and **Install**.
- Updating needs the Xcode Command Line Tools. The source and build cache use about 90 MB; `update.log` in the same folder records the last updates.

## Connect your CPAMC instance

The default connection is `http://127.0.0.1:8317`, with the key read from:

```
~/Library/Application Support/CLIProxyAPI/management-key
```

Choose **Settings…** in the menu to change the URL or select an existing key file. Only loopback connections are accepted. The key remains in that file; this app does not copy credentials, log response bodies, or package secrets.

**Upgrading from an earlier build or CPAMC Menu Bar:** since 0.3.0, the app identifier is `io.github.mindtheflo.juice-bar`. The installer quits the earlier app, copies its preferences to the new identifier and replaces it; an old `CPAMC Menu Bar.app` is moved to Trash. The configuration file and URL scheme are unchanged. Launch at login is reset by the new identifier: turn it back on in Settings or install with `--login`. Menu-bar managers such as Bartender may need the icon placed again.

Configuration is stored in `~/Library/Application Support/CPAMC Menu Bar/config.json`. A key-file path is stored, not the key itself. `config.example.json` shows the supported fields.

## Quotas are read-only

The app reads `/v0/management/auth-files` every 30 seconds. Every five minutes (or on explicit Refresh, with a 30-second minimum between reads), it asks the proxy to perform **GET-only** Claude usage/profile and Codex usage queries via `/v0/management/api-call`. Provider OAuth tokens are substituted by the proxy using `$TOKEN$`; they are never read from credential files by this app.

It makes **no model requests**, never buys/enables extra usage, never consumes promotional resets, never clears cooldowns, and never edits tokens. The explicit account toggle updates only that account’s enabled/disabled state through the management API; it does not change routing strategy or other accounts. The explicit Start/Stop buttons only control the matching local proxy process; stopping it interrupts agents using that proxy. The proxy continues running independently when this app quits. Service controls are available only when the existing `~/Library/LaunchAgents/com.flo.cliproxyapi.plist` points to the same CLIProxyAPI installation and port; unrelated services cannot be controlled. HTTP redirects are rejected to prevent the local management key from being forwarded elsewhere.

No analytics, cloud account, sign-in, or third-party packages are required. Connection diagnostics never include keys or raw provider errors.

## Diagnostics

```sh
swift run cpamc-quota-check
```

This prints a live, redacted quota snapshot plus global provider forecasts, neutral reasons, observed coverage and forecast horizons, and exits. `prediction` is the displayed central-scenario hue and `scenario_agreement` controls saturation; the score is not an accuracy probability. `projected_points` reports central demand in points of one plan; `prediction_deficits` identifies the limiting allowance and central deficit date. Hover a provider heading in the menu for that date and projected weekly-plan use. `pace` remains the conservative whole-band decision and may be null while a tentative prediction is available. `observed_hours` needs at least six comparable hours; `recent_observed_hours` needs at least 1.5 hours in the latest two hours, so recovery after sleep can still be neutral despite sufficient older history. It reads the app’s existing history without writing to it. Individual allowances contain measurements only. Use `--show-names` only when you intentionally want account names in your terminal. Disabled accounts are queried read-only too; a failed reading leaves the account disabled and never makes it available for routing. `cpamc-menubar --demo` uses fictional example.com accounts and no network calls, for screenshots/UI review.

## Remove it

```sh
bash scripts/uninstall.sh
```

Only this companion, its optional login item and its update cache are removed. CPAMC, CLIProxyAPI, all credentials and routing remain untouched. Local settings are retained.

## Development

```sh
swift test
swift run cpamc-menubar --demo --show-menu
python3 scripts/capture-screenshots.py
```

Demo captures use fictional accounts in an isolated app. Release preparation and stable promotion are defined in [the release skill](../.agents/skills/juice-bar-release/SKILL.md). The mathematical model is documented in [forecasting.md](forecasting.md).
