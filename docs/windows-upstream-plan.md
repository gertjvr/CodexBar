---
summary: "Scope and acceptance evidence for contributing the Windows CLI upstream."
read_when:
  - Preparing the Windows CLI contribution
  - Separating shared portability work from the Windows tray
---

# Windows contribution

The contribution targets the existing `CodexBarCLI` and `CodexBarCore`. Windows builds the same
commands and provider implementations. The tray consumes the adjacent CLI's dashboard and config
commands; it does not fetch provider data or own another credential format.

The integration base is upstream `5a8f07bf8`. Its 14 commits after `0f5735e1a` are merged into both
published fork branches:

- `windows-cli-upstream`, commit `49fd5f710`: the CLI portability contribution, with no tray or macOS app changes relative to upstream.
- `windows-cli-actions`, commit `a9b614d3a`: the shared CLI contribution and maintained Windows tray.

[Review the CLI-only diff](https://github.com/gertjvr/CodexBar/compare/5a8f07bf8...windows-cli-upstream)
and [review the additional tray changes](https://github.com/gertjvr/CodexBar/compare/windows-cli-upstream...windows-cli-actions).
The owner wants to review everything before any upstream PR is prepared or opened.

## Upstream CLI scope

Include the Windows host implementations and the small platform selections that use them:

- Files, identity, locking, private credential writes, and atomic dashboard publication.
- PATH and executable resolution, CMD shims, bounded subprocesses and owned process trees.
- RPC pipes, ConPTY sessions, terminal output and console control handling.
- Winsock serving with the existing request parsing and access restrictions.
- QuickJS and SwiftPM build integration, native smoke fixtures, and CLI ZIP packaging.

Keep provider parsing, reconciliation, source precedence, configuration, and output schemas shared.
Platform-specific implementations belong behind the existing host abstractions. Do not replace a
supported command with a successful empty result merely to make the Windows build pass.

The tray target, native window code, icon resources, manifest, preview fixtures, and combined app
workflow form a separate UI change. Keep the CLI-only packaging path independently usable. If an
upstream PR includes only the CLI, remove the optional tray product and packaging hooks from that
patch without changing the maintained fork's combined application.

## Evidence and remaining gates

| Requirement | Evidence | Remaining validation |
| --- | --- | --- |
| Native CLI builds and ships its runtime | Prior-base package `34723154643` passed CI and isolated real-desktop checks | Updated CLI-only run `34725988653` and combined-branch CLI run `34725973797` passed; live Codex and Claude checks passed on the combined package; fresh-OS and broader provider checks remain |
| Existing platforms keep working | The merged source passed all 93 local test groups and lint | All six build, smoke, and packaging targets passed run `34725990008` |
| Windows process, console, file, and HTTP behavior | Production-helper fixtures run before the full Windows build | Complete provider adapter paths still need broader native coverage |
| CLI commands and JSON contracts | Prior packaged help, config, argument errors, dashboard, and synthetic Codex RPC checks passed | Updated native package checks passed in both CLI runs; live Codex app-server and Claude terminal usage also passed; broader provider coverage remains |
| Tray uses the actual companion CLI | Prior packaged refresh and real-desktop empty dashboard checks passed | Current tray run `34726647370` passed native previews, overflow, and full packaging checks; the downloaded ZIP checksum and runtime contents were verified |
| Tray layout and settings | Prior native provider, settings-toggle, and overflow fixtures passed; real-desktop icon, Refresh, Settings, Back, Quit, and synthetic scrolling were checked | Native styling differs from the original; live Codex and Claude display passed; broader theme/scaling and provider coverage remain |
| Reviewability | Both branches are pushed; their shared CLI/Core source is identical, and the CLI-only diff contains no tray or macOS app source | Owner review precedes preparation of any upstream PR |

The merged tree passed `make test`: 1,115 selections in 93 groups, all passing on the first attempt,
with no retries or timeouts. `make check` also passed, including SwiftLint across 2,280 Swift files.
The three merge conflicts concerned an extracted terminal buffer helper, a generated parser hash,
and a test's source-line reference. The resolution preserves the Windows guards, adopts upstream's
shared `StreamScanBuffer`, and regenerates the parser hash from the merged source.

No live provider probes, account logins, or real credential-store reads are part of these offline
checks. The real-desktop check used an existing Windows installation and a minimal PATH; it does
not prove behavior on a freshly provisioned OS or against installed provider accounts.

See [Windows CLI status](windows-cli.md) and [Windows tray status](windows-tray.md) for implementation
history and individual run links. Do not label a raw executable diagnostic artifact as an installable
application package.

The first post-integration release matrix exposed a new Devin parser CoreFoundation type check
introduced upstream. It compiled on macOS but failed on Linux and was incompatible with Windows.
The parser now uses `JSONNumber.isBoolean`, matching its existing numeric parsing. All 28 focused
Devin tests pass, including the table of boolean, numeric, null, string, and absent visibility flags.
The corrected source passed all 92 full-suite groups with no retries or timeouts. All six macOS/Linux
release targets passed run `34694580290`, and the combined Windows package passed run `34694573224`,
including the synthetic Codex app-server fixture. Later Windows-only keyboard and plugin-test changes
passed native runs `34695789735` and `34695442192`, respectively.

The Windows CLI workflow additionally runs `CodexBarPluginTests` with the installed Windows Swift
runtime. This covers the existing portable TypeScript, QuickJS, and provider fixtures without real
accounts. The Unix-specific `CodexBarLinuxTests` target is selected only on non-Windows hosts.
The macOS manifest dump is identical before and after this test-selection change. Native execution
passed run `34695442192`: 99 tests in 10 suites, including the portable plugin runtime.

The CLI-only branch has a clean checkout at `/private/tmp/codexbar-windows-cli-upstream`. Its
published history retains the original portability commit and adds the upstream merge without
rewriting that commit. Shared CLI, core, QuickJS, and native fixture sources match the combined
branch. A local review patch at `.build/windows-review/windows-cli-upstream.patch` is regenerated
against `5a8f07bf8`; branch diffs are the authoritative review surface.
