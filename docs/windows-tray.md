---
summary: "Windows tray UI scope, CLI boundary, and development status."
read_when:
  - Working on the Windows tray UI
  - Checking the Windows tray's CLI compatibility
---

# Windows tray

The Windows tray is maintained in this repository and uses the shared `codexbar` CLI. The new
WinUI renderer consumes its existing `usage` and `cost` JSON outputs, following the Linux frontend.
The older Swift/Win32 tray uses the narrower `dashboard` projection. Provider fetching,
authentication, usage parsing, and configuration remain in the CLI.

The visual reference is [the original menu](codexbar.png): provider tabs, usage bars, reset times,
account and plan details, credits, costs, status, and footer actions. Native Windows window and
notification-area integration should retain that layout while supporting Windows display scaling
and theme settings.

## Try the Windows build

Download `codexbar-windows-x86_64` from the artifacts section of a successful **Windows tray**
Actions run. The [verified combined build](https://github.com/gertjvr/CodexBar/actions/runs/34726647370)
includes the upstream integration, provider overview meters, and revised section layout.

The [redesigned package](https://github.com/gertjvr/CodexBar/actions/runs/34731245378),
`dev-5c5200f09848`, adds original provider icons, rounded tabs and meters, larger typography,
and menu-style footer actions. It passed native normal/overflow fixtures and packaged checks,
then was installed on the owner's Windows host. The Desktop shortcut launched the new version;
both live Codex and Claude panels rendered successfully. The older instance was closed.
Its ZIP SHA-256 is `25704806b890d406c747813204ac7c2e8114d04d14c05b1bb238feb281cc41ba`.

1. Extract the Actions artifact, then extract its versioned `CodexBar-...-windows-x86_64.zip`.
2. Keep `CodexBarTray.exe`, `codexbar.exe`, the DLLs, and `CodexBar_CodexBarCore.bundle` together.
3. Launch `CodexBarTray.exe`. Click its notification-area icon to open the usage popup.
4. Open **Settings…** to enable providers. **Edit configuration…** opens the shared CLI config in
   Notepad. Provider authentication remains owned by the CLI and the selected provider source.
5. Choose **Quit** to stop the tray. Closing or dismissing the popup leaves the notification icon running.

From PowerShell in the extracted folder, the same companion CLI is available directly:

```powershell
.\codexbar.exe --help
.\codexbar.exe config providers --json
.\codexbar.exe config enable --provider codex
.\codexbar.exe config validate
```

For a per-user installation, download [windows-install.ps1](windows-install.ps1) and run it from
PowerShell with `-Archive` pointing to the versioned ZIP. Keep the adjacent `.zip.sha256` file.
The helper verifies the checksum, extracts into a versioned directory under
`%LOCALAPPDATA%\Programs\CodexBar`, checks CLI startup, and creates Desktop and Start menu shortcuts.
It requires no administrator access and does not configure automatic startup. Enable providers
through Settings or the CLI after installation. Existing shortcut files are backed up before replacement.

An enabled provider needs the credentials or installed provider CLI required by its chosen source.
Enabling a provider does not sign in to that provider. Use the existing CLI's configuration and
account commands; the tray does not maintain a separate account database.

The combined ZIP is a portable development build. A standalone CLI download is available from the
**Windows CLI** workflow if the tray is not needed. See [Windows CLI builds](windows-cli.md).

## Current implementation

### Local Windows UI iteration

Install Swift 6.3.3 and the Visual Studio C++ x64 build tools with a Windows SDK using
the [Swift Windows instructions](https://www.swift.org/install/windows/). Open a fresh PowerShell
session after installation. In this fork's Windows checkout, run:

```powershell
git pull --ff-only
./Scripts/windows-tray-dev.ps1 -Test -Launch
```

This compiles only the native tray and its synthetic dashboard fixture. It reuses the installed
MSVC environment, runs normal and overflow navigation checks, and opens a 20-second preview.
Screenshots are saved under `.build/windows-tray-dev/preview`. It does not read provider accounts
or replace the installed application. Use `-InstallTools` explicitly to install missing Microsoft
C++ build tools. Full companion CLI builds and portable package validation remain separate checks.

Verified on the owner's Windows host on 2026-09-13 with Swift 6.3.3, Visual Studio Build Tools
17.14.40, and Windows SDK 22621. The first local tray compile took 26.2 seconds; subsequent
compiles took 11.5 and 9.4 seconds. Normal fixture
navigation and the 200-provider overflow fixture both passed, including keyboard focus scrolling.

`Sources/CodexBarWindowsTray/TraySnapshot.swift` decodes dashboard schema 1 and tolerates additive
fields. `TrayPresentationState.swift` manages provider/account selection, hides idle usage windows,
and retains the previous snapshot with an explicit error after a failed refresh. Account and provider
identity stay scoped to their selected row; an account with no identity never inherits the ambient
account's identity.

The standalone fixture checks these rules without accounts or provider requests:

```sh
swiftc -parse-as-library \
  Sources/CodexBarWindowsTray/TraySnapshot.swift \
  Sources/CodexBarWindowsTray/TrayPresentationState.swift \
  Tests/WindowsTraySmoke/TraySnapshotSmoke.swift -o /tmp/codexbar-tray-snapshot-smoke
/tmp/codexbar-tray-snapshot-smoke
```

`WindowsTrayHost.swift` implements a native notification icon and popup, provider and account
selection, usage bars, reset times, credits, costs, and refresh/configuration/quit actions. The
companion entry point requests dashboard JSON from the adjacent `codexbar.exe`. A separate Windows
tray workflow compiles and runs the popup with an offline fixture, independently of the CLI build.

The [native window check](https://github.com/gertjvr/CodexBar/actions/runs/34689691502) passed on
12 September 2026. Its captured Codex and Claude panels verify rendering and provider switching
with synthetic data. The current controls still use basic system styling; this is not final visual
parity with the original menu.

The Windows-only `CodexBarWindowsTray` target builds a GUI executable. The tray workflow builds
both products and packages `CodexBarTray.exe` alongside `codexbar.exe`, their runtime DLLs, and
shared resources. Packaged validation uses `--smoke-dashboard <fixture.json>` and a minimal PATH;
this explicit mode never launches providers. The complete package passed in
[run 34693026416](https://github.com/gertjvr/CodexBar/actions/runs/34693026416).
The tray includes the original app artwork as an embedded Windows icon, provider-colored bars,
clean label backgrounds, data freshness labels, and Explorer restart recovery. Its settings panel
uses `config providers`, `config enable`, and `config disable` through the companion CLI. Settings
work remains asynchronous and uses the CLI's existing file format. An in-memory settings fixture
checks provider toggling without user configuration; packaging checks separately verify the real
CLI toggle JSON, persistence, and preservation of unrelated credentials.

The [styled window and settings check](https://github.com/gertjvr/CodexBar/actions/runs/34690807140)
passed native compilation, icon generation, provider switching, and an in-memory settings toggle.
Its Codex and settings captures were inspected. Packaged offline runtime validation subsequently
passed; theme/display-scaling polish and installed-provider compatibility remain pending. The CLI portability work
and its tests are tracked separately in [windows-cli.md](windows-cli.md).

The native overflow fixture also passes: it adds 200 synthetic providers, scrolls to the bottom,
and checks that the actual footer control lies within the popup bounds. The captured result was
inspected. Refresh progress and selected-provider usage appear in the popup and notification tooltip.

The package check additionally launches `--smoke-cli` against an isolated all-disabled config and
waits for the popup to display the companion CLI's empty dashboard. This uses the production
subprocess and refresh path. The mode checks test isolation flags and rejects any enabled provider
before requesting a dashboard. Native validation passed in run `34693026416`, including minimal PATH and the packaged companion CLI.

The full tray and CLI compiled in [run 34691945121](https://github.com/gertjvr/CodexBar/actions/runs/34691945121),
but packaging rejected the tray executable with `LNK1106`. Inspection of the preserved binary
found its COFF symbol-table pointer inside section data, producing the exact invalid seek
`0x4019688C`. The build now embeds the manifest in the compiled resource alongside the icon,
avoiding the post-link `mt.exe` rewrite. The corrected package passed native verification in run `34693026416`.

The downloaded combined artifact from run `34693026416` was independently checked: its SHA-256
matches the uploaded checksum, the ZIP passes integrity checks, and both executables are x64 PE
files with valid COFF string tables. The GUI uses the Windows subsystem and the CLI uses the
console subsystem. The package includes 17 runtime DLLs and the shared resource bundle. The
packaged CLI-refresh and Codex fixture screenshots were inspected.

The latest independently verified artifact is `CodexBar-dev-88086fa331b3-windows-x86_64.zip`,
from run `34695789735`, after the 0.60.1 upstream integration. Its ZIP integrity, both executable
subsystems and COFF string tables, and all 17 packaged runtime DLLs passed inspection.
SHA-256: `7e34835c0d5ed9df65027d23703b468ab54b050a8743e0d7463ca66288ae8cf3`.

Keyboard navigation now reveals focused controls when the popup overflows. The overflow fixture
queues Tab messages through the normal message pump, observes focus in the window's GUI thread,
and checks that the focused Quit button is inside the popup bounds. The native check passed in
[run 34695789735](https://github.com/gertjvr/CodexBar/actions/runs/34695789735); the captured focused
Quit button was inspected. The corresponding full package passed run `34695789735`, including synthetic Codex RPC and
the packaged tray refreshing through its adjacent CLI.

Native font assignment was checked in run `34721672625`. All 19 text controls in the Codex
fixture retained the assigned font handles through `WM_GETFONT`; selected font diagnostics report
Segoe UI at normal and semibold weights. The provider and overflow smoke checks passed and the
new screenshot was inspected. This rules out lost font assignments as the explanation for the
preview's typography; it does not establish visual parity. The full package for this diagnostic
revision passed the same run.

The provider selector now includes compact usage meters beneath the tabs, matching the original
menu's overview. Each meter reads that provider's first non-idle dashboard window and uses the same
color and bounded fill renderer as the detailed usage bars. Providers without such a window have
no meter. Native preview, overflow, and full package validation passed in
[run 34723154643](https://github.com/gertjvr/CodexBar/actions/runs/34723154643). The window test now
waits for initial rendering and the footer before inspecting bounds; discovering an HWND alone
was insufficient when the overflow fixture created hundreds of controls.

The plan now sits on the right of the update-time row, and native section dividers separate the
provider selector, usage header, costs, and footer. The Codex, Claude, and keyboard-focused overflow
previews passed and were inspected in [run 34726647370](https://github.com/gertjvr/CodexBar/actions/runs/34726647370).
The font assertion checks text-bearing controls: 20 in the normal fixture and 220 in the overflow
fixture retained their assigned fonts. Etched dividers are also STATIC controls, but render no text
and do not retain fonts; including them in the assertion caused the earlier run `34726421744` to fail.
The full package for this layout revision passed the same run. Independent download verification
confirmed the SHA-256 checksum, ZIP integrity, x64 console/GUI executable types, and 17 bundled
runtime DLLs. The ZIP SHA-256 is
`7e39d758d6d11ba76399f68761b02595a66ed337a19405f3b4347fc6747948b8`.

## Real Windows desktop validation

On 13 September 2026, the combined package from run `34723154643` was downloaded and extracted
on a real Windows machine through an RDP desktop session. Its 53,022,925-byte ZIP matched the
uploaded SHA-256: `c8dd9727529ea9bacd2a4b21bf03df767f09c346a77d21c4c3ac857018bba4e2`.

The isolated helper below passed configuration normalization, all-providers-disabled assertions,
config validation, and schema-1 empty dashboard checks with a minimal PATH. No additional runtime
was installed for the test. The normal tray process then passed these manual checks:

- Its notification-area icon opened the empty dashboard popup.
- Refresh returned to the empty dashboard without an error.
- Settings loaded the shared provider list and showed the selected provider as disabled.
- Back returned to the dashboard; Quit closed the popup and terminated the recorded test PID.

The downloaded synthetic overflow fixture also displayed the provider overview meters within the
desktop work area and responded to wheel scrolling. Its timed smoke process exited automatically.
CI separately verifies the overflow footer bounds, keyboard navigation, populated provider panels,
and synthetic provider settings changes.

This was an offline test on an existing Windows installation, not a freshly provisioned OS or a
live-account compatibility test. No provider was enabled and no authentication was attempted.
Native control styling and typography still differ from the original macOS menu. Private desktop
screenshots are not included in the repository.

## Isolated desktop check

From a profile-free PowerShell session in the extracted package folder, run
[windows-desktop-qa.ps1](windows-desktop-qa.ps1). The helper creates temporary configuration,
explicitly disables every provider, validates the CLI dashboard with a minimal PATH, and launches
only the adjacent tray executable. It restores the shell environment afterward; the child tray
keeps its isolated configuration. It prints the temporary folder and the test tray PID. Do not
enable providers in this test instance unless an installed-provider test has been explicitly planned.

The current layout package `f3c26176136d` from run `34726647370` was also tested on the real
Windows desktop. Its SHA-256 matched the independently downloaded artifact. The isolated helper
passed config validation and dashboard-v1 checks with all providers disabled and a minimal PATH.
The visible notification icon opened the popup; Refresh, Settings, Back, and Quit worked, and
the test process was confirmed absent after Quit. The synthetic overflow fixture rendered the
provider meters; dragging its scrollbar reached the usage details and visible footer within the
desktop work area. The right-aligned plan and section dividers were visible, and the timed fixture
closed afterward. These checks used synthetic usage, not authenticated provider data.

## Live Codex and Claude validation

With the owner's explicit authorization and completed sign-ins,
[the live desktop helper](windows-live-desktop-qa.ps1) passed on package `f3c26176136d`. It uses
a temporary configuration with only Codex and Claude enabled, validates dashboard-v1 output
within the normal 30-second deadline, and prints only provider IDs, sources, and window counts.
Codex selected OAuth with three usage windows; Claude selected its CLI with two. The live tray
displayed Codex's plan, reset times, usage bars, and credits. Switching to Claude displayed its
session and weekly usage without carrying over Codex's account identity or plan.
The helper does not change the owner's persistent provider configuration or perform new sign-ins.
The live tray completed a subsequent refresh and exited through Quit; its process was confirmed absent.

The verified package was installed on the owner's Windows host using the per-user helper.
The installed CLI started successfully, both shortcuts were created, and the Desktop shortcut
launched the tray with live Codex usage. Codex and Claude were enabled in the persistent shared
configuration for the owner's review.

## WinUI replacement development

The replacement under `Windows/CodexBar.Tray` consumes the existing `usage` and
`cost` JSON outputs, following the Linux frontend. The older Swift/Win32 tray above
still uses `dashboard`. No shared CLI schema changes are required for this migration.

On the configured Windows development host:

```powershell
./Scripts/windows-winui-dev.ps1 -Launch       # Explicit synthetic reference fixture
./Scripts/windows-winui-dev.ps1 -Launch -Live # Installed companion CLI, existing accounts
```

Run `dotnet run --project Windows/CodexBar.Tray.Tests` for offline projection checks.
The dedicated **Windows WinUI tray** workflow builds the self-contained renderer
without rebuilding Swift. Its artifact is a UI preview, not a complete CLI package.


The owner’s Windows host now has review revision `f21a6328940d` installed under
`%LOCALAPPDATA%/Programs/CodexBar/WinUI-f21a6328940d`. Use **CodexBar WinUI** on the
Desktop or Start menu. This installation includes its own companion CLI and keeps
the older **CodexBar** shortcut available for comparison.
