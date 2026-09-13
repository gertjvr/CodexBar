# Windows UI parity reference

The target is the owner's running macOS CodexBar, including its configured appearance and
interactions. The Windows implementation is not visually accepted. Successful compilation,
provider fetching, and navigation tests do not establish UI parity.

## Evidence and limits

- The owner supplied screenshots of the dark Codex menu and its daily usage breakdown popup.
- The current macOS process is `/Applications/CodexBar.app/Contents/MacOS/CodexBar`.
- Initially, direct computer automation attachment to the menu-only app timed out. The desktop capture
  did not expose the status icon. The owner then opened the menu, but attachment by both bundle
  identifier and installed app path still timed out. Opening the menu did not resolve the tool
  limitation. On 13 September, the separate settings window made the application accessible.
  The settings inspection below supersedes that limitation for settings. Full live tray-menu
  interaction comparison remains outstanding.
- The source references below corroborate behavior but are not a substitute for observing the
  installed version and its settings. Do not assume the installed app and checkout are identical.
- Do not commit account identities, real usage values, or unredacted screenshots. Use synthetic
  data with the same shape for reproducible comparison images.

## Required comparison

| Area | Reference to reproduce | Original Win32 baseline gap |
| --- | --- | --- |
| Material | Dark tinted translucent background, subtle outline, rounded corners and shadow | Opaque light background; no appearance parity |
| Typography | Original hierarchy, weights, muted text contrast, aligned labels | Different scale and hierarchy |
| Provider navigation | Overview, horizontal icon-and-title tabs, selected blue fill, usage underline | Overview absent; icon stacked above title |
| Header | Provider left, account disclosure right; updated time and plan on next row | Account is a separate text line; disclosure absent |
| Usage sections | Percent in heading, configurable remaining/used mode, reset alignment | Used percentage shown below meter; remaining preference ignored |
| Meters | Provider accent, correct fill direction, pace and warning/workday markers | Basic used-only fill; markers absent |
| Pace | Deficit/surplus and exhaustion forecast accompanying relevant window | Not rendered; provider-level dashboard contract lacks details |
| Additional limits | Code review and provider-specific windows when available | Availability and projection need auditing |
| Reset credits | Available count and individual expiry countdowns | Not exposed in basic tray projection |
| Cost summary | Today and 30-day totals, token counts, model, explanatory note, renewal | Two monetary totals only |
| History | Inline daily chart with reference bar widths, colors and selection behavior | Absent |
| Usage breakdown | Adjacent popup, stacked service colors, selected-day totals and legend | Absent |
| Credits | Meter, remaining amount, token equivalent, purchase action | Plain numeric label |
| Menus | Plan Usage, Cost, account, dashboard, status, settings, about and update entries | Simplified footer with few actions |
| Interaction | Row hover, submenu opening, pointer travel, keyboard navigation, Escape/outside dismissal | Only basic navigation tested; parity unverified |
| Settings | Relevant appearance and display preferences reflected in menu | Basic provider toggle UI only |

## Source reuse map

- `Sources/CodexBar/MenuCardView.swift`: existing card model, metric presentation and sections.
  Models are nested in SwiftUI views and require separating platform-neutral values from UI types.
- `Sources/CodexBar/StatusItemController+MenuCardModel.swift`: app-to-card projection; audit
  dependencies before moving any logic into shared code.
- `Sources/CodexBar/MenuDescriptor.swift`: menu entries, sections and actions. Reuse semantics
  where portable rather than inventing a second menu structure.
- `Sources/CodexBar/ProviderSwitcherButtons.swift`: reference tab layout and selection styling.
- `Sources/CodexBar/MenuCardView+Costs.swift` and `MenuCardView+CodexResetCredits.swift`:
  reference content and conditional sections.
- `Sources/CodexBar/UsageBreakdownChartMenuView.swift`: chart summary, stacked series, legend
  and selected-day behavior. Rendering depends on Swift Charts and SwiftUI.
- `Sources/CodexBarCore/UsagePace.swift`: shared calculations to reuse.
- `Sources/CodexBarCLI/DashboardPayloads.swift`: preserve existing fields and semantics;
  introduce optional additive detail only after checking the existing source of each field.
- `Sources/CodexBarWindowsTray/TraySnapshot.swift`: currently omits much of the original
  presentation data. Expanding only the renderer cannot close these gaps.

## Acceptance sequence

1. Observe the installed reference: Codex and Claude tabs, Overview, account disclosure, Plan
   Usage, Cost, chart selection, Status Page submenu, settings, and dismissal behavior.
   Record what actually happens, including which actions open a browser or a separate window.
2. Capture the current display preferences without changing them. Match remaining/used mode,
   enabled sections, provider order and theme before comparing screenshots.
3. Build one faithful Codex panel and its chart popup using synthetic data matching the reference
   structure. Preserve original information hierarchy, labels, alignment and interactions.
4. Compare on both hosts at equivalent logical sizes. Review material, typography, spacing,
   chart geometry, hover, keyboard focus, overflow, and popup placement separately.
5. Obtain visual review of this first panel before expanding the renderer across providers.
6. Keep the CLI-only upstream branch separate. Provider/authentication logic stays shared;
   Windows shell/rendering dependencies belong to the fork's UI. No upstream PR until owner review.

WinUI 3 is now the review renderer. Prove fidelity through comparisons with the reference.

## Implementation plan: existing CLI first

1. **Reuse Linux's data sources.** Consume `config providers --format json`,
   `usage --provider ID --format json --json-only --status`, and
   `cost --provider ID --format json --days 30`. `Integrations/Linux/Shared/Usage.js`
   and `DesktopController.cpp` are the reference. The upstream `dashboard` endpoint
   predates this port and projects less information. No CLI schema change is needed
   for pace, quota details, daily costs, or token totals.
2. **Test the Windows projection offline.** Preserve optional values and unknown history,
   retain dated results on refresh failure, reject mismatched providers, and filter
   expired reset credits. Keep provider credentials and fetching in the existing CLI.
3. **Build the WinUI panel on the Windows host.** Match the supplied Mac screenshot's
   logical dimensions, typography, dark material, horizontal tabs, remaining meters,
   cost summary, and adjacent interactive history popup. Reuse original icon assets.
4. **Complete shell behavior.** Add notification-area activation, outside/Escape dismissal,
   keyboard navigation, provider settings, correct actions and refresh status. Replace
   preview placeholders before treating the new renderer as an installed tray replacement.
5. **Verify real data and visuals.** Run the already-authorized Codex and Claude checks,
   inspect each tab and chart, and test stale/error and overflow states. Web-dashboard
   extras remain conditional on what the CLI actually returns on Windows.
6. **Package and hand off for review.** Keep UI changes in the fork. Preserve the separate
   CLI-only upstream branch; do not prepare or open an upstream PR before owner review.

The WinUI project is present under `Windows/CodexBar.Tray`. The installed Swift/Win32 tray remains
available while the replacement is built and verified. A passing build alone is not
visual acceptance.


## Verified WinUI checkpoint, 13 September 2026

Source revision `f21a6328940d` built on the owner's Windows host in 13.6 seconds and
passed [Windows WinUI CI](https://github.com/gertjvr/CodexBar/actions/runs/34738190124).
The renderer was then installed per user under
`%LOCALAPPDATA%/Programs/CodexBar/WinUI-f21a6328940d`, with its own companion CLI
and Desktop/Start menu shortcuts named **CodexBar WinUI**. The installed application
opened with live Codex data. The older CodexBar shortcut remains available for comparison.

Observed on the Windows host:

- Dark panel, original provider icons, horizontal tabs and usage underlines.
- Live Codex usage, identity/plan, named Spark limits, CLI pace and reset-credit expiries.
- Live Claude limits and local cost totals, with no Codex identity copied into Claude.
- Synthetic stacked usage chart opens beside the menu; selecting a bar updates its
  date, total and service breakdown. These synthetic fields are not evidence that
  the Windows account supplies a live web-dashboard breakdown.
- Outside click dismisses the menu; notification-area activation opens it again.
- Remaining/used preference changes both the text and fill direction. Restored to
  remaining after testing. Provider settings load the shared CLI's catalog.
- Menu size follows content and available desktop space; a long reference fixture
  scrolls to its footer. The native white frame was removed.

Validation: all 1,115 Swift selections in 93 groups passed on the first attempt,
without timeouts or retries. `make check` reported zero violations across 2,281
files. The offline C# projection checks cover optional data, unknown cost history,
stale results, provider isolation, reset-credit expiry and unread credit balances.
The Windows workflow runs those checks before compiling the renderer.

Remaining parity work includes saved account profiles and the full Mac preferences
and update flows. Web-dashboard extras are conditional on the existing CLI payload;
`CLIHelpers.loadOpenAIDashboardIfAvailable` can reuse an authorized cached dashboard,
but ordinary OAuth usage does not imply that this cache exists on Windows. The owner
has not yet accepted the replacement's appearance. This checkpoint is a review build,
not a claim of complete feature parity.

No CLI schema or provider/authentication code changed for this WinUI checkpoint.
The CLI-only contribution remains separate; no upstream PR has been prepared.

## Settings inspection, 13 September 2026

Observed the owner's running Mac app, version 0.58.0 build 141, through its separate
settings window. Navigated every visible app pane and the enabled Codex and Claude
provider panes without changing preferences or invoking authentication actions.
The supplied screenshots also show the Usage & Spend page. Other providers' individual
forms, conditional notification controls, Debug, and actual tray action transitions
still need inspection. Source references explain implementation, not proof of live behavior.

At the inspection checkpoint, the Windows settings flyout had only three appearance
preferences and provider enable switches. It was not equivalent. The implementation target is a
single reusable, resizable settings window that stays open independently of the tray.
Use the same sidebar order, searchable provider catalog, enabled count and status dots,
page titles, grouped controls, and provider previews. Preserve page selection and window
geometry. About and provider settings actions must navigate to the corresponding page.

| Page | Observed controls and required behavior | Windows work |
| --- | --- | --- |
| General | Language, currency, terminal, start at login, adaptive refresh interval, refresh on menu open, low power policy, provider status, global open-menu shortcut, quit | Implement persisted settings and connect each to its actual service. Current timer is fixed at two minutes. |
| Usage & Spend | 7d/30d/90d/All, refresh and ingestion state, partial coverage, currency totals, subscriptions, token categories, models and sessions | Audit shared history and pricing models. The current 30-day cost projection is not this dashboard. Preserve unknown, partial and error states. |
| Notifications | Session exhaustion/recovery, configurable quota warnings, pace warnings, reset confetti | Reuse threshold/event semantics; implement Windows delivery and duplicate suppression. Inspect conditional editors before implementation. |
| Menu Bar | Icon style, per-provider layout and preview, reorderable identity/usage/time/money tokens, conditionals, combined icon, switcher rows, automatic provider choice, configured providers, animation | Current tray uses a static icon. Port rendering rules and map layouts to the actual Windows notification-area constraints. |
| Menu | Remaining/used fill, warning ticks, pace, work days and tick appearance, reset format, changelog links, credits/extra usage, account layout, cost placement and history length, additional totals, local/SSH sessions and labels | Only remaining, pace and costs switches currently work. Preferences must affect menu, Overview and provider preview consistently. |
| Advanced | Install CLI, redact identity/project paths, credential-access policy, local disk usage, Debug tools | Provide Windows CLI installation and diagnostics actions. Keep redaction a display rule. Do not relabel macOS Keychain policy as generic Windows security. |
| Hooks | Enable execution, rule list and add-rule editor | Existing CLI has list/enable/disable/test/watch. Audit rule editing and Windows execution support; keep execution opt-in and preserve shared event semantics. |
| Plugins | Install JS/TS file, refresh, reveal plugin directory, per-plugin permissions | Existing CLI has list/fetch. Audit Windows runtime and approval support before enabling execution controls. |
| iCloud Sync | Sync settings/providers, optional secrets and usage snapshots, remote accounts, fetch state and Macs | Mac-specific integration needs a separate feasibility decision. Do not present working sync without an implemented service or silently replace its security semantics. |
| About | Version/build, automatic updates, stable channel selector, check for updates, project links | Route to settings About page; implement a Windows update mechanism separately from Sparkle. |
| Provider pages | Enable/refresh, source/version/status/account/plan, usage preview, visible usage items and restore defaults, connection options, accent, session/weekly warning overrides, provider-specific options | Bind to shared provider identity/configuration. A toggle catalog alone is insufficient. Each hidden usage item must disappear from all three presentations. |
| Codex accounts/options | System account, re-auth, add account, local cost estimates, historical pace tracking, web extras, external OAuth source opt-in, web battery saver | Reuse shared account and fetching behavior where available. Audit missing CLI operations before proposing additive commands. |
| Claude options | Usage source, credential prompt policy, cookies, admin key, model-specific widget limits, credential-reading controls, claude-swap | Keep provider data isolated and platform-specific controls explicit. No credential changes were made during inspection. |

### Menu action contract

The owner's additional Cost screenshot establishes a separate required flyout, distinct
from the Plan Usage service/credits breakdown:

- Open beside the highlighted Cost row with matching material, outline and rounded corners.
- Show daily bars with token/currency axis labels and a Token/Cost segmented selector.
- Selecting a day shows its date, cost and tokens, followed by model-level costs and tokens.
  Preserve token-only model entries when cost is unknown.
- Show the estimated total for the configured history window in the preferred currency,
  together with the estimate disclaimer.
- Show Projects with parent totals, paths, indented source groups and hidden-source counts.
  Respect privacy redaction and available height; preserve scrolling and submenu dismissal.
- Verify hover/selection, metric switching, axis rescaling, currency formatting, unknown
  costs, empty history and keyboard behavior against the running Mac reference.

Reference implementations are `CostHistoryChartMenuView.swift`,
`CostHistoryMenuScrollView.swift` and `StatusItemController+CostMenuCard.swift`.
The existing CLI cost payload already serializes daily model breakdowns and Codex
projects with nested sources, paths, tokens and costs. Windows `CliSnapshot.cs` currently
retains daily entries but drops projects, and its Cost flyout is a simpler chart.
Preserve and render these existing fields before considering any CLI additions.
Availability of project data still depends on the provider and local history.
No real project names, paths or usage values from the screenshot are recorded here.

Audit each `MenuDescriptor.MenuAction` against Windows routing. This includes update,
refresh, dashboard, status, changelog, account add/switch/system promotion, terminal,
provider login, workspaces, settings/provider settings, About, quit, copy error and
session focus. Also compare Plan Usage, Cost and chart popups for opening, selection,
keyboard navigation, pointer travel and dismissal. Do not treat opening a generic
information popup as equivalent to account management.

`CLISessionsCommand.swift` explicitly limits session focus to macOS. The presence of
a CLI command does not establish Windows capability. The same audit is required for
hooks, plugins, storage scans and provider-specific connection methods.

### Implementation order and acceptance

1. Build the independent settings window and navigation, then move existing functioning
   preferences into their matching pages. Keep the tray alive when settings closes and
   keep settings alive when the tray dismisses. Repeated Settings actions reuse the window.
2. Implement General, Menu and provider display preferences, including persistence and
   immediate effects across menu, Overview and settings. Match defaults and option values
   from the Mac source. Test behavior and restart persistence with synthetic data.
3. Implement provider configuration and account routes using existing CLI operations.
   For missing operations, first inspect Core and Mac implementations. Propose optional,
   additive CLI operations only where required; preserve existing command/output behavior.
4. Add spend history, notifications, icon/layout customization, hooks and plugin management
   with verified Windows capabilities. Separate Windows shell APIs from shared provider,
   pricing, history, account and event logic.
5. Complete diagnostics, updates and platform-specific decisions. Maintain an explicit list
   of unsupported features rather than inert switches or an unqualified parity claim.
6. Compare each page and action on both hosts, including errors, missing data, keyboard
   operation, scrolling and persistence. Build locally on Windows and install a review
   revision. Full parity remains incomplete until these checks and owner review pass.

Primary source references: `PreferencesView.swift`, `PreferencesGeneralPane.swift`,
`PreferencesMenuPane.swift`, `PreferencesMenuBarPane.swift`, `PreferencesNotificationsPane.swift`,
`PreferencesProvidersPane.swift`, `PreferencesSpendDashboardPane.swift`, the other
`Preferences*Pane.swift` files, `SettingsStore*`, provider settings implementations,
`MenuDescriptor.swift`, and `Sources/CodexBarCLI/CLI*Command.swift`.


## Settings and Cost implementation checkpoint

Revision `68ee082ede08` implements the independent settings window and the detailed Cost
flyout. It is an incremental implementation of the plan, not full settings parity.

- Settings opens as a separate reusable window with General, Menu, Advanced, About and
  searchable provider pages. It retains size and selected page; closing it leaves the tray
  running. Account disclosures navigate to their provider page, and About uses the same window.
- Saved controls now affect refresh interval, refresh-on-open, provider status requests,
  remaining/used labels and meters, pace, reset formatting, credits, costs, history length,
  identity/project redaction, per-provider visible limits and accent colors.
- Provider enable changes use the existing CLI config command. Provider previews show live
  status, identity, plan and usage. No new authentication implementation was added.
- The Cost flyout includes Token/Cost selection, calendar-spaced daily bars, selected-day model
  details, token-only unpriced entries, totals, project/source groups and expansion. It uses
  existing CLI fields. Missing calendar buckets remain unknown rather than invented zero costs.
- Window title bars use the dark theme and the provider sidebar uses original provider icons.

Validation: `make test` passed all 1,115 selections in 93 groups on the first pass in 830.5
seconds, with no failed groups, timeouts or retries. `make check` reported zero violations.
The extended C# tests pass both locally and on Windows, covering nested projects, unpriced
models, provider-specific preference persistence, selected history windows and sparse calendars.
The final native Windows build completed with zero warnings and errors in 7.78 seconds.

Live Windows cost output has daily history but currently reports an empty projects array.
Project rendering is therefore verified with synthetic data, not claimed as live account data.
Currency currently follows the returned cost currency; preferred-currency conversion is still
outstanding. The full Usage & Spend dashboard, remaining notification parity, configurable tray layouts,
startup/global shortcuts, account management, hooks/plugins UI, advanced diagnostics, updates,
localization and platform-specific sync remain outstanding. Provider settings also still need
connection controls and the complete preview sections. The CLI-only upstream branch is unchanged.

Direct native development is now available through the existing SSH alias `astrix`. Build/test
commands can run there; desktop interactions still use the Windows App session. The remote
checkout contains an unrelated untracked `setup.ps1`, which this task leaves untouched.


## Notifications implementation checkpoint

Revision `db6a8c24f34f` adds a Notifications page with quota depleted/restored alerts,
session and weekly threshold controls, predictive pace warnings, sound and optional
on-screen text, plus provider-specific Global/Custom/Off overrides. Warning markers
use the configured thresholds. The policy currently supports Codex and Claude and
consumes existing CLI usage and pace fields; the CLI-only branch is unchanged.

Focused tests pass locally and on Windows for threshold selection/rearming, stale and
failed observations, account isolation, Codex restore confirmation and pace deduplication.
The native build passed with zero warnings/errors in 8.55 seconds. `make check` passed.
The full Swift suite reported above remains the validation baseline; no Swift source changed.

Installed and running on Asterix from `WinUI-db6a8c24f34f`. A synthetic test alert was
visibly received in Windows Notification Center; clicking it reopened the tray menu.
The expanded session/weekly threshold controls and scrolling were checked on the desktop.
After the owner's manual reset, a fresh usage read showed weekly quota changing from
0% to 100% remaining and reset credits from three to two. This is live data confirmation,
not proof of a session-restored alert, since the affected quota was weekly.

The on-screen overlay and audio still require direct observation. Confetti is not implemented
in this WinUI source. The owner reported confetti over both Mac and Windows; only the new
WinUI CodexBar process was running on Windows when checked. The animation's source is
unconfirmed, and it must not be counted as Windows celebration implementation proof.
