---
summary: "Windows CLI Actions builds, downloadable artifacts, and current port status."
read_when:
  - Building or downloading the Windows CLI
  - Diagnosing the Windows Actions job
---

# Windows CLI builds

The Windows CLI workflow, `.github/workflows/windows-cli.yml`, builds the existing `CodexBarCLI`
SwiftPM product on a native Windows x64 runner with Swift 6.3.3 and MSVC. It does not run under WSL
or contain a separate implementation of the providers.

The workflow runs on relevant pushes to `main` and `windows-cli-actions`, relevant pull requests,
and manual dispatches. In GitHub, open **Actions > Windows CLI > Run workflow** to start a manual
build. In a fork, enable Actions if GitHub has disabled its inherited workflows.

After a successful build and packaging smoke tests, the run provides the
`codexbar-cli-windows-x86_64` artifact. It contains a versioned ZIP and its SHA-256 checksum.
The ZIP includes `codexbar.exe`, the core resource bundle, required runtime DLLs, `VERSION`, and
licenses. It is an Actions artifact, not an automatically published GitHub Release asset.

The separate `codexbar-cli-windows-x86_64-logs` artifact captures toolchain, SQLite, dependency
resolution, and compiler output, including failed builds. A logs artifact is not an executable
download. Build and packaging failures remain failed workflow runs; they are not suppressed.

## Current status

The native CLI ZIP passed its build and packaged offline checks in
[run 34725988653](https://github.com/gertjvr/CodexBar/actions/runs/34725988653) on the CLI-only branch, including 99 native
plugin tests in 10 suites and the synthetic Codex app-server check. Development continues
on `windows-cli-actions` for installed-provider compatibility and the separate tray application.

This CLI-only contribution is based on upstream `5a8f07bf8`. All six macOS/Linux release targets
passed run `34725990008`; the merged source also passed 1,115 local test selections in 93 groups
without retries or timeouts, plus `make check`. The native packaged Codex check uses a synthetic
app-server, so these results do not establish compatibility with every installed provider account.

The original CoreFoundation import failure
has been fixed by replacing boolean type checks while preserving the distinction between JSON
booleans and numeric zero/one.

Native Windows smoke checks have passed for JSON number classification, file identity and timestamp
precision, cache invalidation after file replacement, directory iteration, and interprocess file
locking. The lock check verifies contention and release after a throwing operation. These checks
compile the production helpers independently of the full CLI, so they can run while source porting
continues. They use temporary fixtures and no account credentials.

Shared Foundation networking guards, environment updates, stderr writes, and usage-file metadata
have also been ported. Credential writing now has a Windows implementation using a protected
current-user DACL established at creation, followed by flushed writes and same-directory replacement.
It rejects filesystems that cannot enforce ACLs and fails if volume capabilities cannot be verified.
The [native helper validation](https://github.com/gertjvr/CodexBar/actions/runs/34598655119)
passed permission inspection, replacement, rejected-write cleanup, exclusive-creation collision,
and repair of a deliberately broad ACL on synthetic credential files.

The shared subprocess runner now has a Windows implementation that creates children suspended,
assigns them to a job before resuming, and restricts inherited handles to the child's standard streams.
The [native process validation](https://github.com/gertjvr/CodexBar/actions/runs/34681297702) passed
argument quoting, Unicode environment values, working-directory identity, separate stdout/stderr,
bounded output, nonzero exits, timeouts, cancellation, and cleanup of grandchildren after their
parent exits. These tests use synthetic child executables, not installed provider CLIs.

Codex and Grok now use the same long-lived RPC process owner, backed by Windows jobs on Windows
and the existing Foundation process launch on Unix. The [native RPC validation](https://github.com/gertjvr/CodexBar/actions/runs/34681755172)
passed repeated requests, streamed replies, input closure, and shutdown using a synthetic RPC child.
Gemini's synchronous helper also uses the Windows subprocess implementation.

Windows PATH handling now uses semicolon-separated directories, case-insensitive environment keys,
and PATHEXT suffixes. Explicit uppercase overrides take precedence over inherited mixed-case keys.
The [native discovery validation](https://github.com/gertjvr/CodexBar/actions/runs/34682238869) passed
discovery and launch from a Unicode directory with competing Path/PATH entries. Unix login-shell
capture is bypassed on Windows; inherited PATH is used instead.

The Windows pseudoconsole backend now launches children in their own job with real console handles.
It drains terminal output on a dedicated reader and queues input separately, so prompts are delivered
before the child exits and pseudoconsole shutdown can drain its final frame. The
[native ConPTY validation](https://github.com/gertjvr/CodexBar/actions/runs/34683088897) passed terminal
detection, Unicode interaction, resizing, and shutdown. The shared terminal runner now selects this
backend on Windows while retaining its existing prompt handling, status loop, options, and results.
Its Windows session owner closes the entire job and drains ConPTY on exit, cancellation, and app
shutdown. The [native session ownership checks](https://github.com/gertjvr/CodexBar/actions/runs/34683750005)
passed normal exit, retained exit status, termination of a waiting child, and rejection of new
launches after shutdown. The complete shared terminal loop still needs native validation.

Persistent Codex and Claude sessions now select the same Windows terminal owner. They retain
their shared parsing and session reuse rules, and propagate terminal read failures and output
limits. Windows environment keys are normalized before provider-specific credential scrubbing.
These provider adapters compile in the complete Windows CLI; installed-provider runtime validation is pending.

Provider version detection now uses the native Windows subprocess runner. Its merged-stream mode
uses one inherited pipe for both streams; the [native stream-order check](https://github.com/gertjvr/CodexBar/actions/runs/34684248784)
passed alternating stderr/stdout writes without reordering them.

Kiro pipe probes now use the same registered Windows job owner as terminal sessions. The shared
probe still controls activity detection, idle timeout, cancellation, and output parsing. Its native
smoke check uses production pipe capture to verify live output and EOF after termination. The
[native capture validation](https://github.com/gertjvr/CodexBar/actions/runs/34684748259) passed. POSIX
spawn and process-group helpers are compiled only on Unix.

Antigravity sessions now have a Windows terminal adapter with launch reservations, job-based
shutdown, and native process identity. User ownership compares full Windows SID strings rather
than numeric Unix user IDs. Stale-session cleanup can terminate only jobs whose original handles
are still owned by this process; unmatched live records are retained. Job descendant enumeration
uses the [Win32 job process list](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-jobobject_basic_process_id_list).
The [native identity and launch-reservation checks](https://github.com/gertjvr/CodexBar/actions/runs/34685281390)
passed. The SQLite crash fixture also has a Windows termination path that bypasses transaction cleanup.

During porting, the native build progressed past the initial
source errors, then Swift 6.3.3 crashed in its BoundsCheckOpts optimization pass for the shared
JSONL scanner. Windows now uses UCRT `memchr` for newline search, matching the Unix implementation;
an optimized standalone scanner check exercises bounded reads, persisted checkpoints, truncated
records, Unicode, and appended JSON tails before the full build. The [standalone Windows check](https://github.com/gertjvr/CodexBar/actions/runs/34686390711)
reproduced the compiler crash even with `memchr`. The scanner now holds mutable state in one
scan-owned object instead of captured scalar variables. The
[native optimized check](https://github.com/gertjvr/CodexBar/actions/runs/34686591671) passed; the full
CLI build compiled the shared core and then failed on CLI terminal sizing, sockets, termination
signals, and dashboard output. The adapters below address those source errors. The
[next full run](https://github.com/gertjvr/CodexBar/actions/runs/34687685314) passed all native component
checks and source compilation, then LLVM asserted on debug assignment fragment metadata while
optimizing a CLI route. Windows release builds now pass `-Xswiftc -gnone`: release optimization
remains enabled, but packaged executables omit debug symbols. The
[complete Windows build](https://github.com/gertjvr/CodexBar/actions/runs/34688694539) passed on
12 September 2026 at commit `ec598b857`, including packaging and all offline packaged command checks.
The run uploaded `codexbar-cli-windows-x86_64`, containing the executable ZIP and SHA-256 checksum.

CMD/BAT launch support now selects the Windows command interpreter while retaining the existing
job ownership, deadlines, and output limits. Its fixture checks literal arguments, Unicode paths,
exit status, and timeout cleanup. The [native command-script checks](https://github.com/gertjvr/CodexBar/actions/runs/34686390711)
passed. Passing helper checks
does not establish full CLI or installed-provider compatibility.

CLI terminal detection, color output, width queries, executable-path discovery, and normal exit
now have Windows implementations. Console control monitoring maps Ctrl+C and Ctrl+Break into the
existing command shutdown callbacks; closing the console drains owned helpers synchronously.
The [native CLI host checks](https://github.com/gertjvr/CodexBar/actions/runs/34687685314) passed
terminal sizing and color, callback removal, and restoration of Windows' default control handler.

The local HTTP server now uses Winsock on Windows while sharing its request parsing, Host allowlist,
connection limits, and deadlines. Windows listeners use exclusive address binding. Each accepted
connection retains the Winsock lifetime until its socket closes, so stopping a listener does not
invalidate outstanding requests. The standalone fixture checks UTF-8 responses, headers, forbidden
Host values, and repeated listener lifetimes. Dashboard file output also has a Windows writer that creates an exclusive staging file, flushes
it, and replaces the destination without first truncating it. Its native fixtures check successful
replacement and preservation of existing output when publication fails. Those checks and the native
HTTP fixture passed in the same run. Complete CLI packaging and offline command validation subsequently
passed in run `34688694539`; installed-provider runtime compatibility still needs validation.

The compatibility target is the existing `CodexBarCLI` commands, configuration, and JSON output,
with shared provider logic. A Windows tray UI can consume this CLI without maintaining its own
provider implementation. The Windows tray is maintained separately in the gertjvr/CodexBar fork.
Packaging checks run only once the complete CLI builds successfully. They validate version/help and
resources with a minimal PATH, synthetic config validation and redaction, JSON argument errors, and
dashboard stdout/file output with every provider disabled. No provider request is made by these checks.

All six existing macOS and Linux release targets passed build, smoke, and packaging checks in
[run 34691963682](https://github.com/gertjvr/CodexBar/actions/runs/34691963682). Linux retains a
conditional CoreFoundation import required to deserialize Foundation Thread subclasses with Swift 6.2.1.
Windows does not import CoreFoundation. This manual compatibility run uploaded artifacts without publishing a release.

Existing macOS/Linux artifacts continue to use
[Release CLI](https://github.com/gertjvr/CodexBar/blob/main/.github/workflows/release-cli.yml).

## Packaging checks

`Scripts/build_windows_cli.ps1` downloads and verifies the same SQLite amalgamation used by the
Linux musl release job, builds its static library, and invokes `swift build -c release --product
CodexBarCLI`. Each external command's exit status is checked.

`Scripts/package_windows_cli.ps1` inspects native DLL imports recursively, copies required runtime
libraries, and checks version, help, and core resources from the staged package with the Swift
toolchain removed from the child process's PATH. These checks use no account credentials or live
provider probes. A clean Windows installation remains the final distribution test.

The PowerShell scripts are parsed on the Windows runner before toolchain setup, so syntax errors
are reported even when a later compiler or dependency step fails.

The packaged provider check uses a synthetic Codex app-server behind a Unicode-named CMD shim.
It invokes `usage --provider codex --source cli --json` and checks the RPC request sequence,
provider identity, session and weekly limits, and credits. The same fixture passed through the
local CLI and the native Windows package in run `34695442192`. Its Python interpreter belongs to the runner
and is not distributed with the application. No installed Codex or account credentials are used.

## Authorized installed-provider check

The CLI-only package from run `34725988653` was downloaded on the real Windows desktop.
Its SHA-256 matched the independently verified artifact, and `codexbar.exe --version` returned
`CodexBar dev-49fd5f710198`. Read-only Codex and Claude usage checks with `--source cli`
both returned `No available fetch strategy`. Codex was not on the native shell's PATH or in
the checked npm/local-bin locations; the installed native Claude CLI reported `loggedIn: false`
from `claude auth status`. No credentials were changed and no new sign-in was attempted.
Authenticated provider compatibility remains unverified until the existing signed-in installation
is located. WSL is present, but its provider sessions were not accessed by these checks.

After the owner installed Codex and completed Claude sign-in, live checks passed with package
`f3c26176136d` from run `34726647370` (the shared CLI/Core source matches the CLI-only branch).
A fresh PowerShell process picked up the newly installed Codex executable; the original shell
had a stale PATH. Codex `usage --provider codex --source cli --json` returned usage, identity, and
credits through its app-server path. Claude `usage --provider claude --source cli` passed in
text and JSON formats against the signed-in native CLI. A temporary configuration enabling only
these two providers also passed `dashboard --timeout 30 --identity redacted`: Codex selected OAuth
and returned three usage windows; Claude selected its CLI and returned two. These results establish
live compatibility for the tested accounts and installed versions, not every provider or account type.
No raw account output or credentials were added to the repository.
