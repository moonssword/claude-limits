# Claude Limits

*[Русская версия](README.ru.md)*

A macOS menu bar app that shows how much of your Claude 5-hour session and weekly quota
is left — without opening a browser.

The icon carries both numbers at a glance: the outer (or upper) element is the 5-hour
session, the inner (or lower) one is the weekly quota. Clicking it opens a panel with exact
percentages, reset times and a burn-rate forecast.

> Unofficial, not affiliated with Anthropic. It reads your own usage data from your own
> account and sends nothing anywhere else.

## Requirements

- macOS 14 or newer (Apple silicon or Intel)
- A Claude subscription and Claude Code signed in on this machine (`claude`, then `/login`)
- To build from source: Xcode Command Line Tools (`xcode-select --install`)

## Install

### From a release

Download the `.dmg` from [Releases](../../releases), drag the app to Applications and launch it.

Builds are **not** signed with an Apple Developer ID, so Gatekeeper blocks the first launch.
Either right-click the app → **Open** → **Open**, or clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/ClaudeUsage.app
```

### From source

```bash
git clone <this repo>
cd claude_usage
./build.sh                                  # produces build/ClaudeUsage.app
cp -R build/ClaudeUsage.app /Applications/
open /Applications/ClaudeUsage.app
./make-dmg.sh                               # optional: build/ClaudeUsage-<version>.dmg
```

## Where the data comes from

The app reads the Claude Code OAuth token from the login keychain (the `Claude Code-credentials`
item) and calls `https://api.anthropic.com/api/oauth/usage` — the same source the `/usage`
command inside Claude Code uses. The response provides:

| field            | meaning                                        |
|------------------|------------------------------------------------|
| `five_hour`      | 5-hour session: percent used and reset time    |
| `seven_day`      | weekly quota across all models                 |
| `seven_day_opus` | weekly Opus quota, when the plan has one       |
| `extra_usage`    | pay-as-you-go extra credits                    |

Nothing is sent anywhere else. History is kept locally in
`~/Library/Application Support/ClaudeUsage/history.json`, and the outcome of the last poll
in `status.json` next to it.

### Authorization

Two modes, switchable in Settings:

1. **Claude Code keychain** (default) — nothing to set up. macOS may ask once for permission
   to read the `Claude Code-credentials` item; click **Always Allow**.

   That permission does not last forever: Claude Code writes the item with
   `security add-generic-password`, so its access list names only that tool, and the list is
   recreated on every OAuth token refresh — after a reboot, for instance.

   The app therefore never raises the dialog on its own. Background reads run with
   `SecKeychainSetUserInteractionAllowed(false)` and fail silently when access is not granted
   (`kSecUseAuthenticationUI` does **not** suppress this dialog for the file-based keychain —
   measured: 16 s with a password prompt versus 0.01 s without). A successful read is cached,
   with its expiry, in `~/Library/Application Support/ClaudeUsage/credentials.json` (mode 0600),
   so the keychain is touched again only when the copy expires, usually after 8–12 hours. When
   permission is needed the panel shows an **Allow access** button and the dialog appears only
   on that click.

   `ClaudeUsage --keychain-check` prints what the app sees: read status, timing and cache state.
2. **Your own token** — click **Authorize via browser**. The app runs `claude setup-token`
   as a background process, so the browser opens straight away with no Terminal window and no
   automation permission: you sign in with the claude.ai session you already have, paste the
   code the page shows back into the app, and the long-lived token is stored in the app's own
   file, so no keychain permission is ever needed and password prompts disappear entirely.
   Pasting a token by hand still works; a token shorter than a real one is rejected instead of
   being stored silently.

There is deliberately no built-in OAuth flow of its own: Anthropic does not offer third-party
OAuth client registration for subscription accounts, so an in-app login would have to run under
Claude Code's own `client_id` — that is, pretend to be Claude Code. `claude setup-token` is the
same browser login done the supported way.

## What you get

**Menu bar.** Eleven appearance options: four indicator shapes — rings, two bars, a battery
(charge = session left) and dots — each with an optional label: time to session reset, percent
used (`61·41`), session remaining, or `time · week`. Settings show them as tiles with a live
preview on light and dark backgrounds. The icon is monochrome (template, follows the system
theme) and takes on color only near a limit: amber from 75 %, red from 90 %. Exhausted shows
an exclamation mark; no connection shows dashed rings.

**Panel.** Session and week in large figures: percent used, time left, reset point, progress
bar. Below them the weekly Opus quota and extra credits when they apply, and a burn-rate estimate
(`≈11%/day · about 74% by reset`, or `quota runs out Fri at 18:20`) computed from samples the
app collects locally while it runs.

**Right-click** the icon for Refresh now / Settings… / Quit.

**Settings.** Grouped into Appearance / Menu bar / Updates / System / Notifications /
Authorization. Language, app theme (system, light, dark), icon color mode, poll interval
(1–30 min, 10 by default), notifications (one warning per session window before it resets, and
one when the weekly quota crosses a threshold), launch at login, and the authorization mode.

The icon color mode only changes the accent: the icon and its label always follow the **system**
menu bar theme, never the app theme above. In the default mode both stay monochrome and turn
red only at 90 % or more.

**Languages.** English, Russian, German, French, Spanish, Italian, Portuguese, Arabic
(with RTL layout), Korean, Kazakh, Kyrgyz, Uzbek. The system language is used by default.
Everything except English and Russian is machine-translated — corrections are welcome in
[`Sources/ClaudeUsage/Strings.swift`](Sources/ClaudeUsage/Strings.swift).

**Request rate.** The usage endpoint is rate-limited per account and answers `429` with a
useless `Retry-After: 0`, so the app backs off on its own: 5, 10, 20, 40 minutes on repeated
refusals (never longer than an hour), keeps at least a minute between automatic polls, and goes
on showing the last known figures. Manual refresh ignores the minimum interval but not the
back-off.

## Project layout

```
Sources/ClaudeUsage/
  AppMain.swift              entry point, NSApplication with no Dock icon
  UsageAPI.swift             keychain read + usage request
  Models.swift               models and errors
  UsageStore.swift           polling, state, notifications, back-off
  StatusItemController.swift status item, popover, context menu
  StatusIcon.swift           menu bar indicator drawing
  PopoverView.swift          main panel
  SettingsView.swift         settings window
  Preferences.swift          settings + launch at login (SMAppService)
  AuthFlow.swift             browser authorization via claude setup-token
  TokenStore.swift           the app's own keychain item for the manual token
  History.swift              local samples and burn-rate estimate
  Format.swift               time, percent and status-color formatting
  PreviewRenderer.swift      `ClaudeUsage --render <dir>` writes UI screenshots to PNG
  L10n.swift, Strings.swift  localization (96 keys × 12 languages)
Tools/make-icon.swift        app icon generator
build.sh                     builds the .app
make-dmg.sh                  builds the .dmg
```

## Releasing

Tag a commit and push the tag — [`.github/workflows/release.yml`](.github/workflows/release.yml)
builds the DMG on a macOS runner and attaches it to the GitHub release:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

Publishing an unsigned binary is allowed and common; users just have to clear quarantine as
described above. To ship something Gatekeeper accepts silently you need an Apple Developer
Program membership ($99/year): sign with a Developer ID certificate and notarize with
`xcrun notarytool submit … --wait` plus `xcrun stapler staple`.

## License

MIT — see [LICENSE](LICENSE).
