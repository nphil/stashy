# Stashy engineering notes — deep reference

Companion to the root `CLAUDE.md` (the lean entry point). This file holds the hard-won detail:
**read the relevant section before touching that subsystem**, and update it as you learn. Everything
here was verified against the repo on 2026-07-01; full re-audit against code + git history 2026-07-16.

---

## 1. Build / CI detail

Workflow: `.github/workflows/ios-build.yml`, runs on `macos-15`, triggered on every push to `main`.
`paths-ignore` skips `**/*.md`, `android/**`, `stash-plugin/**`, and `.github/workflows/android.yml` —
doc-only AND plugin-only commits do **not** trigger an app build.

### Fail-fast compile errors (since `f243d30`, 2026-07-08)
The "Build (unsigned)" step tees raw xcodebuild output to `xcodebuild.log` (xcpretty is cosmetic only)
and deliberately tolerates the pipeline's exit code (a framework-validation false-positive). It then
greps the log for the precise `<path>:<line>:<col>: error:` diagnostic pattern — on any hit it prints
the deduped errors up front, emits GitHub `::error file=…,line=…,col=…` inline annotations for `.swift`
diagnostics, and exits 1 **at the Build step**. A red Build step with annotations = compile failure,
already surfaced — no log digging. (The old `| xcpretty || true` swallowed-exit-code trap, where a
compile error showed green until the Package step, is gone.)

Still true:
- On a failed run **no release is published**, so the previously-installed IPA keeps working — a broken
  push is low-blast-radius; only a published release fully proves a push out.
- A pure **linker** error (no `line:col` diagnostic — rare) still passes the grep; it's caught by the
  Package step's executable-present check + ~1 MB IPA-size floor. For those, read logs the old way:
  `get_job_logs` (`return_content:true`, `tail_lines: ~230`), look for `** BUILD FAILED **`.

### A red run is not always a compile error — check WHICH step died
Failure classes, and how to tell them apart from the job log:
- **"Build (unsigned)" red with `::error file=…` annotations** → a real compile error. The usual case.
- **"Resolve Swift packages" red with `failed downloading … downloadError("The request timed out.")`**
  → infrastructure, not your commit. The videoengine package pulls SIX binary xcframework zips from a
  GitHub release and they can all time out at once (2026-08-10, v1.0.367 push — nothing was ever
  compiled). That step now retries 3× with 20/40 s backoff before failing, so this should be rare; if
  it still fails, re-run the job rather than "fixing" code that never reached the compiler.
- **Release step red with `CONFLICT (content): Merge conflict in apps.json`** → two runs overlapped.
  Also not your code: both compiled fine. See below.
- Read failures with `get_job_logs` (`failed_only: true`, `return_content: true`, `tail_lines: ~60`).
  **`list_workflow_runs` returns ~375 KB and blows the tool-result limit** — it gets spilled to a file;
  parse that file with python (`json.load` → `workflow_runs[i]['id' | 'head_sha' | 'conclusion']`)
  instead of trying to read it.

### Verify Apple API signatures BEFORE you push (CI is the only compiler)
Every unverified API guess is a ~6–8 min round trip. Before using an unfamiliar Apple symbol, fetch its
exact Swift declaration from the **doc-JSON endpoint** (works from the sandbox; HTML doc pages are
JS-rendered and return only the title):
```
curl -sL "https://developer.apple.com/tutorials/data/documentation/<framework>/<symbol>.json" \
  | python3 -c "import json,sys; d=json.load(sys.stdin);
[print(''.join(f['text'] for f in v['fragments'])) for v in d['references'].values()
 if v.get('kind')=='symbol' and v.get('fragments')]"
```
(objc-only detail sometimes only appears on the child page `.../<symbol>/<member>.json`.) This session it
pinned down MetalFX (`MTLFXSpatialScalerDescriptor.makeSpatialScaler`, `colorProcessingMode`),
`AVAssetImageGenerator.generateCGImageAsynchronously(for:completionHandler:)`, and the VT super-res inits.
**Sharpest gotcha — failable-vs-not differs across sibling APIs:** `VTLowLatencyFrameInterpolation`
config init is *optional* (`guard let`), but `VTLowLatencySuperResolutionScaler` config **and** params
inits are **non-optional** (plain `let`), and `maximumDimensions` imports as `CMVideoDimensions?`
(unwrap it). Guessing these cost three separate red builds before the doc-JSON habit stuck.

### Auto-versioning and the push sequence
On success, CI commits a version bump to `main` with `[skip ci]` (bumps `MARKETING_VERSION` /
`CURRENT_PROJECT_VERSION` / `CFBundleShortVersionString` in `ios/project.yml` + `Info.plist`, and
patches root `apps.json`, the Feather/AltStore source manifest) and publishes a tagged Release with
the IPA asset. So `origin/main` moves without you — always rebase before pushing:

```
git add <specific files>
git commit -F - <<'EOF' ... EOF
git fetch origin main -q && git rebase origin/main && git push -u origin main
```

**Verify every push** via `get_latest_release`: a *changed* IPA byte size confirms your code actually
shipped. Calibration: v1.0.100 ≈ 7.63 MB, v1.0.107 = 7,733,141 B ≈ 7.73 MB (FFmpeg is statically
linked + dead-stripped, so size creeps up as more of it gets called).

**Don't push while a build is in flight** — and since that rule got broken the moment it mattered
(2026-08-10), the pipeline now defends itself three ways. Understand all three before touching this
step; each one alone leaves a hole:
1. `concurrency: {group: ios-build, cancel-in-progress: false}` — runs QUEUE instead of overlapping.
   Not `cancel-in-progress`: every push to main is meant to produce a release.
2. The version is `max(checkout's plist, highest `v*` tag)` + 1. The checkout is pinned to the pushed
   commit, so its plist predates the bump commit CI lands afterwards — a second push in the same
   window reads a stale version and would republish a tag that already exists. Tags are the authority.
3. The bump commit is BUILT ON current main, not rebased onto it: `git fetch origin main` →
   `git reset origin/main` (mixed — moves branch + index, leaves the edited version files in the
   worktree) → `git checkout origin/main -- apps.json` → patch → commit → `git push origin HEAD:main`.
   The old commit-then-rebase order conflicted, because two runs each insert at the head of
   `apps.json`'s `versions` array and that's the same lines. Patching main's copy means there is
   nothing to rebase.
The symptom this cures, so it's recognisable if it ever returns: `CONFLICT (content): Merge conflict
in apps.json` at the release step, on a run whose code compiled perfectly.

### XcodeGen
The Xcode project is generated in CI from `ios/project.yml`, which **globs `Stashy/`** — new `.swift`
files are auto-included; never hand-edit a `.pbxproj`. Deployment target iOS 26, Swift 6,
`SWIFT_STRICT_CONCURRENCY: complete`, `VALIDATE_PRODUCT: NO` (unsigned IPA; the FFmpeg frameworks have
underscored bundle ids that a CI script patches).

### GitHub MCP quirks
`actions_list` / `list_workflow_runs` returns JSON exceeding the tool token cap — it gets saved to a
file; parse with a short `python3 -c` reading the saved path (`workflow_runs[i]` →
`id,status,conclusion,head_sha,display_title`). `get_workflow_run` for one run is fine. The MCP token
can **expire mid-session** ("requires re-authorization"); `git push` still works (separate proxy) —
keep committing and ask the owner to re-auth to read CI again.

---

## 2. Swift 6 strict concurrency — the patterns that actually compile

`SWIFT_STRICT_CONCURRENCY: complete` is on. Most CI failures this project ever hit were concurrency,
not logic:

- **`@Observable @MainActor final class` is implicitly `Sendable`.** You can capture such instances
  (incl. `self`, and model objects like `DownloadItem`) into `@Sendable` closures.
- **`"reference to captured var 'self' in concurrently-executing code"`** — the classic. Happens when
  you `[weak self]` (an optional *var* binding) and a *nested* `@Sendable`/concurrent closure
  references `self` again. **Fix:** don't re-capture `self` in the inner closure — capture the
  specific Sendable object directly. Real example: a transcode progress callback doing
  `Task { @MainActor [weak self] in self?.items.first... }` inside another `[weak self]` Task errored;
  fixed as `{ p in Task { @MainActor in item.transcodeProgress = p } }`.
- **Non-Sendable Apple objects across a boundary** (`URLSessionTask`, `AVAssetWriterInput`,
  `AVAssetReaderTrackOutput`): wrap in a tiny `@unchecked Sendable` box struct when handing them to
  `@Sendable` closures (e.g. `getAllTasks`'s completion, `requestMediaDataWhenReady`).
  `DownloadManager` has `UncheckedSendableBox`, `VideoTranscoder` has `UncheckedTranscodeBox`.
- **`Task { @MainActor in … }` created inside a `@MainActor` method:** calls to other `@MainActor`
  methods inside are same-actor → **no `await`** (adding one warns "no async operations occur within
  await"). But you still need explicit `self.` for escaping-closure captures.
- **`try?` flattens nested optionals (SE-0230).** `try? url.resourceValues(forKeys:).fileSize` is
  `Int?`, NOT `Int??`. Don't write `?? 0 ?? 0`.
- **`NotificationCenter.addObserver(forName:…, queue: .main, using:)`** block is `@Sendable`. To call
  a `@MainActor` method from it synchronously, use `MainActor.assumeIsolated { self?.foo() }` (safe
  because `queue: .main` runs on the main thread). `Task { @MainActor in }` also works but defers a
  runloop tick — use `assumeIsolated` when you must act *before* suspension (app-phase handoff).

---

## 3. Downloads subsystem (`Services/DownloadManager.swift`) — sharpest edges in the app

### Architecture
- `DownloadManager` (`@Observable @MainActor`) owns `[DownloadItem]`. Each download = **8 parallel
  HTTP range requests** (`Range: bytes=lo-hi`) via `URLSessionDownloadTask`, each writing a **part
  file**; parts are concatenated (`merge`) on completion. Single connection if the server didn't
  report a size.
- **`DownloadDelegate` is a SEPARATE `NSObject` class**, not the manager, because `@Observable` +
  `NSObject` conflict. It runs on a background delegate queue, does the synchronous part-file move
  there, and forwards structural events to the `@MainActor` manager via `@Sendable` closures.
  High-frequency byte progress goes to a lock-guarded `TransferStore` (never hops the actor per
  byte); a **120 ms MainActor poll loop** reads the store and updates the observable UI.

### THE -3000 LANDMINE (shipped regression — do not repeat)
A **background `URLSession` (`URLSessionConfiguration.background`) cannot run 8 PARALLEL range (206
partial-content) tasks** — the out-of-process `nsurlsessiond` daemon returns
**`NSURLErrorCannotCreateFile` (-3000)** on every connection. Commit `ef9e591` switched the whole
engine to a background session, broke ALL downloads, and was reverted in `22f6740`. A **single**
background range task at a time is the normal supported case. (Note: `docs/DOWNLOADS_PLAN_2026-07-01.md`
predates this discovery and asserts the opposite — this file is the correction.)

### Current design (v1.0.107): dual-engine handoff
- **Foreground:** 8-way parallel on `session` (`.default`). Fast. **Sacred — do not break this path;**
  it's the fallback for everything.
- **Background:** on `UIApplication.didEnterBackgroundNotification`, active downloads **hand off** to
  `bgSession` (background config, `sessionSendsLaunchEvents = true`) running **one connection at a
  time**; `connectionFinished` chains the next unfinished part. On `willEnterForegroundNotification`
  it hands back to 8-way parallel.
- **Handoff mechanics:** cancel in-flight tasks with `cancel(byProducingResumeData:)`; resume data
  arrives *asynchronously*, so a per-item `pendingHandoff` counter waits for all blobs before starting
  on the target engine. Part files + per-connection resume data are preserved both directions → no
  progress lost. A short `beginBackgroundTask` assertion covers the handoff so the bg task starts
  before suspension.
- **`inBackground`** is initialized from `UIApplication.shared.applicationState` (so a cold background
  relaunch behaves), then flipped by the two notifications.
- **`taskDescription`** on every task encodes `"<itemID>\u{1}<conn>\u{1}<partPath>"` so after a cold
  background relaunch (empty in-memory store) the delegate can still route a finished file.
  `reconnectTasks` queries **both** sessions' `getAllTasks` on launch.
- **`.active` marker files** (in the meta dir) distinguish an active/resumable download from a stopped
  one, so `loadInterrupted` only resurrects the right ones after relaunch.
- ⚠️ **UNVERIFIED ON DEVICE:** that a *single* bg range task doesn't also -3000 (very likely fine),
  and the whole suspend→continue→relaunch flow. If single-bg -3000s, fall back to leaving downloads
  paused-on-background (foreground still works).

### THE TRANSPORT VERDICT — corrected twice (current as of v1.0.325, device logs 2026-07-24/25)
Several earlier conclusions in this file were wrong. The truth, from `dl-trace` on iOS 26.5.2:

**`NSURLErrorCannotCreateFile` (-3000) is the system's HAND-OVER step failing.** A background
`URLSessionDownloadTask` streams into its own staging file and moves it into our container only at the
end. On the owner's device that final move fails for **every** whole-file transfer, at every size:

| item | size | failed at | strict free | lenient free |
|------|------|-----------|-------------|--------------|
| 2761 | 1.6 GB | `bytes == total`, ×4 | — | 47 GB |
| 2713 | 560 MB | 98% | 8.1 GB | 34.8 GB |
| 1331 | 1.45 GB | 99% | 6.5 GB | 33.2 GB |

`dl-err-detail` (v1.0.316) proves iOS attaches **no `NSUnderlyingError`, no `NSFilePathErrorKey` and no
`localizedFailureReason`** — it is a bare `NSURLErrorDomain -3000`. So it is none of the things this
file has previously claimed: not "a background session can't run 8 parallel range tasks" (that was this
same failure ×8), not "a background session can't deliver a 206" (plain 200 transfers fail identically),
and not disk space (6.5 GB free for a 1.45 GB file). **And not size**: v1.0.326 traces show the FIRST
64 MB slice, with nothing durable yet, failing exactly like a 1.6 GB whole file. **Root cause remains
unknown.**

What IS now measured: five consecutive failed 64 MB slices consumed **472 MB of strict free space**
(~70 MB each — one slice's worth, stranded and never returned) while delivering zero bytes. That is the
"System Data" growth, quantified.

> **Correction (2026-07-25).** A previous revision of this section, and a comment in `connectionFailed`,
> claimed device-proof that the daemon stages OUTSIDE our container. **That was wrong.** It rested on
> `dl-staging` reading `files=0 bytes=0` — from a census whose loop was `if size > 0`, counting only
> non-empty regular FILES. Directories report size 0, so "the delivery directory is absent" and "it is
> empty" produced the identical reading; the theory was never tested at all. Treat any conclusion drawn
> from a `dl-staging` line emitted before v1.0.328 as unsupported.

> **These instruments have been REMOVED** (2026-07-26) now that they have answered the question — see
> the verdict below. `stagingCensus`/`dl-staging`, `probeDeliveryPath`/`dl-probe`, `dl-identity` and the
> Settings → Diagnostics "Re-test System Transfers" button are all in git history; recover them from
> there rather than rewriting them if the -3000 ever needs re-investigating. The description below is
> kept because it documents what was measured and how.

`stagingCensus` counted directories and zero-byte entries and listed names. **`probeDeliveryPath`**
(`dl-probe`, emitted before every slice and at every -3000) was the real instrument: it walked
`Caches/com.apple.nsurlsessiond` → `/Downloads` → `/<bundle-id>`, logging existence at each level, then
performs the two operations the daemon itself must perform — `createDirectory(withIntermediateDirectories:)`
and a 1-byte write-then-delete — and logs the NSError domain:code of whichever fails. Paired with
`dl-identity` (the INSTALLED host bundle id, the session identifier, and whether the widget extension's
id is still nested under the host's), this distinguishes the live hypotheses:

| `dl-identity` | `dl-probe` | Reading |
|---|---|---|
| host id ≠ `com.nphil.stashy`, or appex not nested | — | the sideload signer rewrote identity; explains the -3000 AND the ActivityKit `.denied` in one stroke |
| correct | `mkdir` or `write` fails | a permission/protection fault on the delivery path — the errno names it |
| correct | both `ok`, but `mine=0` beforehand | the daemon's own delivery directory is missing; pre-creating it may be the entire fix |
| correct | both `ok`, directory present | the app is not at fault; the work becomes making the in-process path survive backgrounding |

### VERDICT — the probe ran, 2026-07-25 (v1.0.328). Row 4. Stop looking in the app.
```
dl-probe why=pre-slice bundle=com.nphil.stashy root=1 downloads=1 mine=1 mkdir=ok write=ok
dl-staging why=begin  exists=1 dirs=2 files=0 bytes=0 names=Downloads,com.nphil.stashy
dl-err-detail item=2768 domain=NSURLErrorDomain code=-3000 blob=0      ← 4.19 GB free, first 64 MB slice
dl-probe why=err-3000 bundle=com.nphil.stashy root=1 downloads=1 mine=1 mkdir=ok write=ok
```
The directory the daemon must deliver into **exists, sits inside our container, and our own process can
both create it and write a file into it** — measured in the same millisecond as the refusal. The host
bundle id is intact, so the signer did not rewrite it. Combined with the code audit (no path in
`DownloadManager` can emit -3000; the only synthesised code is `NSURLErrorCannotWriteToFile`), every
app-side explanation is exhausted: not space, not size, not Range, not the path, not permissions, not
our code, not identity. It is an iOS-side refusal that carries no diagnostic.

**Do not spend further builds hunting it.** The correct response is the shipped one: one -3000 condemns
the transport (~1.5 s, ~52 MB — down from 472 MB across five retries) and everything runs in-process
thereafter. Device-verified the same session: a 2.70 GB file completed at 100–112 MB/s and kept
downloading for **29.7 s after the app was backgrounded**, finishing at 100% without being reopened.

**The one real limit that remains.** The in-process path lives on `beginBackgroundTask`, later measured
at ~26 s (the "29.7 s" above is a download *finishing* — a floor, not the ceiling). A transfer with more
than that much work left when the user leaves the app stalls until they return. That is an enhancement,
not a regression: the daemon path it replaced never completed a single transfer. **Superseded as the
final word by "The `audio` keep-alive" below — the window turns out to be renewable — but the figure
itself stands and still governs whenever the keep-alive is off, which is the default.**

**The engine therefore slices (v1.0.325).** `startBackgroundTransfer` → `startBackgroundSlice`: one
background range task at a time, `Range: bytes=<durable>-<durable+64MB-1>`, appended into our part file
by the delegate's existing append branch, then the next slice is queued from `connectionFinished`. Why
this is the right shape regardless of which theory is true:

* the unit of loss on ANY failure is one in-flight task — so make that unit 64 MB, not 1.6 GB;
* every landed slice is durable, so progress is monotonic and survives suspension, relaunch, and iOS
  purging its own caches;
* if the hand-over is broken at every size, it now shows up after ONE slice (≈1 s of bandwidth) rather
  than at 99% of a multi-gigabyte download.

`expected` for a slice is `end + 1` — the part's size AFTER the slice lands — because that is what the
delegate's completeness check compares against. `sliceUnsupported` (in-memory, so it self-heals on
relaunch) routes range-refusing servers, and unknown-size transfers (a Companion transcode still being
written), to `startWholeFileBackgroundDownload`.

**Never retry the same transport on a whole-file delivery failure.** Every byte already arrived, so the
retry replays the whole file and fails identically — the owner watched 1.6 GB re-download four times.
The retry budget in `connectionFailed` is therefore sized to what a retry COSTS: `ranged ? 4 : (already
moved ≥90% ? 0 : 1)`, and a successful slice clears it, so it bounds CONSECUTIVE failures. After that,
escalate: `startForegroundFallback` runs an in-process data task that appends each chunk into our own
part file. No hand-over step exists on that path, so this failure cannot occur; progress is durable and
Range-resumable. It only advances while the app is open, so it is a fallback (sticky per item). The
escalation **keeps the durable part** — only a whole-file transfer genuinely leaves us nothing, because
it alone holds every byte in a temp file we cannot reach.

**A slice must never contribute in-flight bytes to displayed progress.** Two paths would: an aborted
slice's last `didWriteData` figure (now snapped back to the part's real size in `connectionFailed`) and
an iOS resume blob banked from a slice (now refused — its `NSURLSessionResumeBytesReceived` counts bytes
inside the aborted range, none of which are on disk). Both would show progress that a later read
corrects DOWNWARD, which is precisely the 15 → 12 → 8 symptom.

**Resume data for a FAILED task lives in the error's `userInfo[NSURLSessionDownloadTaskResumeData]`.**
`cancel(byProducingResumeData:)` returns nothing for a task that already ended, so not reading the
error meant every daemon-surfaced drop restarted from byte 0. Bank it before any recovery branch;
a reset path that clears it (shipped for one build) turns a resumable failure into a full
re-download. Blobs are epoch-guarded — one belonging to a superseded task will be rejected by iOS —
and since the blob arrives an async hop after `pause()`, Resume waits for it.

**Multi-threading is gone (v1.0.313).** Benchmarked against the owner's server: 1 connection
~32 MB/s vs ~14 MB/s for 8-way, and the single background transfer runs at 85–100 MB/s. Parallel
connections only help where one TCP stream can't fill the pipe (high RTT, loss, per-flow shaping);
on a LAN they just make the array seek. `Services/TransferBenchmark.swift` measured this (counterbalanced
A B C C B A, disjoint slices, slow-start excluded per connection) and was **removed 2026-07-26** with the
question settled — it is in git history if a future link type (high-RTT remote, shaped cellular) ever
makes parallelism worth re-measuring. Do not rewrite it from scratch.

### The background-execution ceiling — every avenue tested, 2026-07-26
With the daemon hand-over confirmed unavailable, the in-process transport is all we have, and it only
runs while the app runs. This is the exhaustive account of how much runtime iOS will give it. **All
four mechanisms below were tested on the owner's device. Do not re-litigate them from first
principles.**

**1. `beginBackgroundTask` — MEASURED at ~26 s.** Two independent runs: 25.57 s (t=30.13→55.70) and
26.32 s (t=576.35→602.67). `dl-bg-expired` is the only honest signal — an earlier "29.7 s" figure was
a download *finishing*, a floor and not a ceiling, and was wrongly quoted as the limit for several
sessions. On cellular at ~5 MB/s that moves ~144 MB, so a multi-gigabyte transfer parks. Note
`UIApplication.backgroundTimeRemaining` reads `.greatestFiniteMagnitude` at the exact moment
`didEnterBackgroundNotification` fires, so it is useless there; elapsed-time-to-expiry is the
measurement. (Converting that sentinel is also what crashed the app in v1.0.332 — see §2.)

**2. `BGProcessingTask` — implemented (v1.0.336), is a CATCH-UP path only.** Apple's reference page,
verbatim: *"Processing tasks run only when the device is idle. The system terminates any background
processing tasks running when the user starts using the device."* `earliestBeginDate` guarantees only
*not sooner*. So it can never serve "background the app and it keeps going". The widespread "needs
wifi + charging" claim is **folklore** — `requiresExternalPower` and `requiresNetworkConnectivity` are
opt-in launch predicates defaulting to false, and Apple documents no wifi-vs-cellular rule; cellular is
fine. What it buys is convergence across idle windows while the phone is untouched.

**3. `BGContinuedProcessingTask` (iOS 26) — implemented behind a toggle (v1.0.337), DOES NOT FIRE.**
This is the API whose stated purpose matches "the user started it, let it finish". Device result:
`dl-cont-register ok=1`, four × `dl-cont-submit ok=1`, and **zero `dl-cont-begin`** — including one
submission on a genuine user tap immediately followed by backgrounding, which is exactly its intended
shape. iOS accepts the request and never grants a window. Two candidate explanations, neither
disproven: open unresolved Apple Forums reports of it not firing on **iPhone 17 Pro** specifically, and
the fact that an **unsigned sideloaded app carries no entitlements** — the same shape as the -3000,
where a system service declines to act for an app it cannot fully vouch for. Toggle ships OFF.
Apple also publishes no maximum duration for it, and developers report ~3 GB transfers surviving while
~10 GB ones die seconds after backgrounding.

**4. Foreground modes.** `location`, VoIP, `bluetooth-central` and `external-accessory` are either
abuse or unavailable to this app. Android's foreground-service model — a persistent notification that
buys indefinite runtime — has **no iOS equivalent**. Live Activities are pure display and grant zero
runtime, which is the single most common misconception about them. **`audio` is the exception, and the
claim once written here — "legitimate only while audio genuinely plays, because iOS terminates an app
that declares it and produces none" — is wrong; see the next section.**

**Net, as of the four tests above:** downloads finish with the app open, survive ~26 s of
backgrounding, converge overnight while the phone is idle. That was read as a platform ceiling. It
isn't — read on.

### The `audio` keep-alive — how the ~26 s ceiling is actually lifted (v1.0.339)
The four tests above are all sound. The **conclusion** drawn from them ("no API lifts it") was wrong,
and this section exists so nobody re-derives the wrong one. It was found by studying
**XITRIX/iTorrent** — a sideloaded open-source torrent client that downloads for hours in the
background — at commit `e95af51`, on the owner's prompting.

**The mechanism.** A `beginBackgroundTask` assertion cannot be *extended*. It can be *replaced*. An app
that declares the `audio` background mode and holds an **active `AVAudioSession`** may end its
assertion and immediately be granted a fresh one, indefinitely. iTorrent's pump, verbatim:

```swift
while !Task.isCancelled {
    guard BackgroundService.isBackgroundNeeded else { stopBackgroundTask(); stopAudio(); return }
    playAudio()
    stopBackgroundTask()                                  // END the old assertion FIRST
    backgroundTask = await UIApplication.shared.beginBackgroundTask { [weak self] in
        self?.startBackgroundTask()                       // expiration → re-enter, don't surrender
    }
    stopAudio()
    guard backgroundTask != .invalid else { continue }    // refused → retry, don't sleep into suspension
    try await Task.sleep(for: .seconds(10))
}
```

**Why ending first is load-bearing.** iOS's background window is **per-app, not per-assertion**. The
clock only resets when *nothing* is outstanding. This is why `DownloadManager.holdTransferAssertion`
now stands down while the pump runs and `enterBackground` releases the per-item assertions it already
holds — one left over pins the window open and the whole renewal silently does nothing.

**Why this one isn't gated like the others.** iTorrent's complete `.entitlements` is app-sandbox,
app-groups, user-selected-files, network client/server, location — **not one `com.apple.developer.*`
key.** `UIBackgroundModes` is a plist *declaration* policed at App Store review, not a signed
capability, so it behaves identically in an unsigned sideloaded IPA. That is categorically unlike
-3000 and `BGContinuedProcessingTask`, which are OS-service handshakes that can decline an app they
cannot vouch for. It is also why an App Store-policy argument ("Stashy is a real media player, so the
declaration is honest") is beside the point: iOS does not check whether you have a video player, it
checks whether a session is active.

**Two things the study also settled**, both killing plausible alternate theories: iTorrent's Live
Activity is `pushType: .none` driven by in-process `Activity.update` — their Dynamic Island stays live
because their *process* does, not because ActivityKit has a privilege. And their torrent payload never
touches `URLSession` at all (raw libtorrent sockets), so their starting position was *worse* than ours
— they never had a daemon hand-over to lose, and solved it purely by refusing to be suspended. The
technique is transport-agnostic and wraps our `URLSessionDataTask` unchanged.

**What we shipped:** `Services/DownloadKeepAlive.swift`, OFF by default behind Settings → Diagnostics.
Deliberate choices, each with a reason that is not obvious:
- **Copy the hybrid, not the ancestor.** iTorrent's `git log --follow` shows it shipped the naive
  design first (`c57b61e`: one infinite silent loop, `numberOfLoops = -1`, no `beginBackgroundTask` at
  all) and spent three rounds of "Background fixes" converging on the pump above. The simple version
  was insufficient; don't rediscover that.
- **The tone is generated at runtime, not bundled** — 0.5 s of 16-bit mono PCM at ~−60 dBFS, played at
  `volume = 0.01`. A bundled resource adds a silent failure mode (XcodeGen not copying it,
  `path(forResource:)` returning nil, the feature quietly doing nothing). Digital silence and
  one-sample files are avoided on purpose: iTorrent shipped a 46-byte single-sample `3.wav` and moved
  to a real 61 KB clip. The reason was never written down, so treat it as a respected hypothesis — but
  there is no upside to retesting the option its author abandoned.
- **A refused window retries rather than sleeping**, and three consecutive refusals tear the pump down
  instead of spinning.
- **An interruption observer re-claims the session.** A call takes the session and iOS does not hand it
  back; without this the pump renews an assertion with no audio behind it until the window closes for
  good. iTorrent needed this too (`9fe6cd4`, "Fix background service interruptions").
- **`startForegroundFallback`'s background guard admits the keep-alive.** This was caught in review and
  is not cosmetic: every background restart path funnels through that guard, and `daemonHandoverBroken`
  routes every transfer on this device down them. Without it, one transient error — a Wi-Fi → cellular
  handoff suffices — parks the item permanently while the pump burns battery for a transfer that will
  never restart. The feature would have been inert in exactly the scenario it exists for.
- **Audio-session category handling is a genuine three-way trade.** The pump leaves the session mixing
  (`.mixWithOthers`) so a background download never silences the owner's music. Restoring that
  unconditionally on foreground return would take the session outright *every time* they open Stashy
  after a download — dropping `.mixWithOthers` on an already-active session interrupts other apps.
  Never restoring leaves a player that outlived the background trip mixing for the rest of the scene,
  because `ScenePlayerModel.start()` early-returns on `guard engine == nil` and `AVPlaybackEngine`'s
  own assertion never runs again for it. Resolution: restore **only when `isOtherAudioPlaying` is
  false** — inaudible when it applies, and when it doesn't the worst case is hearing both rather than
  losing their audio.

**DEVICE-PROVEN, 2026-07-26, iPhone 17 Pro / iOS 26 — first run, no tuning.** The trace, in full:

```
 62.85  dl-phase     to=background active=1
 62.85  dl-parts     item=2624 why=enter-bg  sum=18924673   total=4035314417 pct=0
 63.51  dl-keepalive tick=1  up=0
 ...    (29 consecutive ticks, one per ~10 s, zero gaps)
352.70  dl-keepalive tick=29 up=289
353.50  dl-phase     to=foreground active=1
353.50  dl-parts     item=2624 why=enter-fg  sum=743998057  total=4035314417 pct=18
353.50  dl-keepalive stop=1 ticks=29 up=290 restored=1
```

**290 s of unbroken background runtime and 725 MB transferred while backgrounded**, against a previous
hard ceiling of 26 s. Zero `refused`, zero `expired`, zero `dl-bg-closing`. The Live Activity pushed
real progress the entire time (`dl-la pct=` 0 → 18, ten updates), which also confirms the process was
genuinely scheduled rather than the card interpolating. `restored=1` confirms the audio-category
restore path ran on foreground return. There is no reason to believe there is any remaining time limit:
nothing in the trace degrades, and the run ended only because the owner reopened the app.

Apple has never documented an active session granting runtime, so a point release can still regress it
with no deprecation and no compile error. Re-read this trace shape after any iOS update.

### Serial download queue + Live Activity payload (v1.0.340)
Three shipped changes worth knowing before touching the download engine or the widget.

**The queue gate lives in `startConnections`, not at the call sites.** FIVE separate fan-out paths can
start a transfer — `bulkDownload`, foreground revival, network recovery, the `BGProcessingTask` resume
window, and plain user taps — and every one iterates and launches every eligible item. Gating them
individually is defeated by the sixth path someone adds later. `startConnections` is the single funnel
all five reach. A queued item sits in `.queued` (a state that already existed and was vestigial, so no
new `DownloadState` case and no new exhaustive switches); `pumpTransferQueue` promotes the next one.
The manual override (`startNow`, the play button on a queued card) inserts the id into `handStarted`,
which the gate consumes exactly once — so a hand-started item runs ALONGSIDE the current transfer
rather than displacing it or reordering the queue behind it.

Promotion runs from `poll()` ahead of that method's guards, plus immediately on stop and delete. That
is a NET, not the only mechanism, and deliberately so: an item can leave `.downloading` down a dozen
paths including eight distinct failure sites, and a queue that stalls because one of them forgot to
call the pump is a far worse bug than one array check per 120 ms tick.

Serial is also simply faster here. `fgSession` sets no `httpMaximumConnectionsPerHost`, so it inherits
the default of 6: several queued downloads used to open six concurrent streams, and six benchmarked
~2× SLOWER than one against the owner's server (v1.0.313: ~32 MB/s single vs ~14 MB/s eight-way). Do
NOT instead set `httpMaximumConnectionsPerHost = 1` as a shortcut — that would also serialise sidecar,
thumbnail and sprite fetches.

**THE TRAP THE QUEUE ALMOST SET.** `DownloadKeepAlive`'s predicate originally counted only
`.downloading` and `.waitingForNetwork`. In the gap between one item's last byte and the next one's
first, nothing is in either state — the pump would tear down, iOS would suspend the app, and a queue of
ten would finish exactly one. The predicate now counts `.queued` and `.merging` too, and
`startKeepAliveIfNeeded()` is callable from the promotion path rather than only from `enterBackground`.
Any future state that represents "work still outstanding" must be added there as well.

**Live Activity payload.** `ContentState` carries `title`, `receivedBytes`, `totalBytes` and `speed`
alongside the original phase/progress/ETA fields. Two things to remember:
- The struct is compiled into BOTH targets via `project.yml`'s
  `- path: Stashy/Services/DownloadActivityAttributes.swift`, so app and widget can never drift — but
  adding a field means checking every `.init(` call site in `liveActivityState()` (there are seven) for
  **declaration-order** argument matching, which this project has lost a CI cycle to before.
- ActivityKit caps combined static + dynamic payload at 4 KB; the title is clamped to 48 characters.

`.queued` is deliberately eligible to be FEATURED on the card. Without that, the instant between one
download ending and the next starting has no active item, the activity ends, and the next push has to
request a brand-new one — which flickers the Lock Screen card once per queued item.

**Privacy Mode gates the title.** Earlier builds refused to send scene titles outside the app at all.
The owner asked for the name (2026-07-26) because a card reading "Download · 4%" is indistinguishable
from any other. The resolution: send the title normally, send an EMPTY string when Privacy Mode is on
(`Privacy.isOn`), and let the widget fall back to its generic phase title. Otherwise the Lock Screen
would be the one surface the app-wide blur didn't reach — in plain text, with the app locked.

**The 8-segment bar is gone.** `segmentCount = 8` in the widget was a metaphor for the eight parallel
connections removed in v1.0.313: it had been decorating a number that no longer existed, and it ate the
horizontal space the card needed for byte counts. Do not reintroduce it. Separately, the Dynamic
Island's expanded regions sit inside the island's rounded shape and the system does NOT inset content
away from that curve — 2 pt was tried and still clipped on device; 13 pt clears it. `minimumScaleFactor`
does not help, because shrinking text does not move it away from the curve.

### The download queue manager (v1.0.341) — invariants, not preferences
Five of these were shipped bugs found in one review pass. Read before touching the queue.

**A queued item MUST be `markActive`d.** *(Fix DEVICE-VERIFIED 2026-07-27: a batch queued with one
transfer in flight survived a force-quit intact — every card back, bytes retained, and the restored order
matching the order they were added. The enqueue-date sort held; the coarse-filesystem-timestamp risk it
carried did not materialise.)* The general rule: *any state that means "live work the user
expects to survive a kill" needs the `.active` marker*, because `loadInterrupted` guards on it and
`sweepOrphanedMeta` deletes the sidecar of anything without it. The serial gate (v1.0.340) returned
before `markActive` ran, so a ten-deep queue came back from a force-quit as ONE item — the other nine
deleted outright, sidecars, thumbs and sprites with them. The companion queue had marked its waiting
items active since it was written; the transfer lane was simply missed. If you add a new waiting state,
mark it active.

**`markActive` is idempotent, and that is load-bearing.** Its file creation date IS the enqueue order
that `loadInterrupted` sorts by. Re-stamping it on every resume would scramble the queue on each
relaunch. Directory enumeration order is unspecified — never rely on it.

**`runCompanionTranscode` has NO gate. Never call it directly** — use `enqueueCompanion` +
`pumpCompanionQueue`. It doesn't check `companionActiveID`, so two direct callers meant N staged cards
fired N simultaneous jobs at the one server GPU. And every early return in the companion path must
`releaseCompanionSlot`: `pumpCompanionQueue` guards on `companionActiveID == nil`, so ONE leak blocks
every future transcode until relaunch. Four such leaks existed (`delete`, two in `monitorCompanionJob`,
the missing-serverURL guard); the last only became reachable once the pump was the sole caller, which
is the general hazard — *changing caller topology turns harmless early returns into permanent pins.*

**The serial gate lives in `startConnections`, not at the call sites.** Five fan-out paths reach it
(bulk download, foreground revival, network recovery, the BGProcessingTask window, user taps) and each
one iterates and launches everything eligible. A gate at the call sites is defeated by the sixth path
someone adds later. Same reasoning put `queuePaused` in `serialQueueGateApplies` rather than only in
the pump.

**A paused queue must drop out of the keep-alive predicate.** `.queued` counts as work, so pausing
without this leaves the pump looping a tone on an active audio session and re-taking a background
assertion every 10 s while moving zero bytes — the worst possible battery outcome. But a blanket
`!queuePaused` is wrong in the other direction: a `startNow` override legitimately runs alongside a
paused queue. Final shape — `.downloading || .merging` unconditionally, `.queued || .waitingForNetwork`
only while unpaused. The same split applies to `hasActiveWork` (which pins the display on),
`scheduleResumeIfNeeded` and `runScheduledResume`.

**`queuePaused` is persisted.** Unpersisted, a relaunch clears it and `resumeInterruptedDownloads`
quietly drains a queue that was deliberately paused overnight.

**Pause must stop the ACTIVE download, not just promotion.** `poll()` runs the pump every 120 ms and
its occupancy test is "is anything downloading" — pause promotion only and the next item starts within
one tick, from a button labelled Pause. Use `pause(_:)`, never `suspend(_:auto:)`: only `pause` writes
the `.userpaused` marker that stops `resumeInterruptedDownloads` un-pausing it on the next launch.

**The pump must respect `awaitingBlob`.** A pause hands its resume blob back one async hop later;
promoting inside that window finds nothing and restarts the whole file. `resume` waits for it — the
pump didn't, and Pause-then-Resume on one toolbar button lands squarely in that window.

**List order = queue order.** New items insert at `queueTailIndex` (after the last unfinished card),
never at 0 — `transferQueue` is FIFO, so inserting at the top made the list read backwards and "Start
Queue" appear to run it bottom-up. Restored actives splice above the finished library, because
`loadCompleted()` runs first and both append. Nothing is re-sorted at runtime, which is why this is an
ordering convention rather than grouped sections: no card ever moves under the user's thumb.

**Menu label + navigation.** Three states on the scene ••• row: `Download Video` (nothing pending —
stages and navigates), `Add to Download Queue` (something pending — stages and stays put), `Show in
Downloads` (this scene already added). Navigation only when nothing is pending: the first add wants the
staging screen, the tenth is an interruption, and both screens hide their back buttons so each costs
two edge-swipes back. `hasPendingWork` is an EXCLUSION list so a future state defaults to pending, and
it excludes `.paused` on purpose — a pause survives relaunch, so counting it would flip the menu into
never-navigate mode for the life of the install.

**Removing navigation removes the only feedback.** `floatingStatus` returned nil for waiting-only work,
so freshly added scenes looked identical to idle on every root screen; it now counts `.staged`/`.queued`
at 0. Plus a tappable confirmation capsule on the scene screen, since the floating button isn't on it.

**Deliberately NOT built** (asked for or obvious, and refused): a top-level Stop All — `stop()` wipes
every downloaded byte plus the sidecar, so a nav-bar bulk version is one mis-tap from hours of transfer
and contradicts the durability invariant. Drag-to-reorder — `startNow` covers the case and queued cards
show `#N` positions. A play button on a waiting server-transcode card — `startNow` guards on `.queued`
so it would be a dead tap, and loosening that guard byte-downloads the ORIGINAL file, discarding the
chosen codec and resolution.

**`.serverProcessing` IS in the keep-alive — owner decision 2026-07-26, don't quietly remove it as an
optimisation.** It is the one clause in the predicate that buys VISIBILITY rather than throughput: the
server encodes whether or not the phone runs, so this holds the process alive purely so the Live
Activity keeps showing real progress. A card frozen at 4% for two hours is worse than no card, and
being able to see it is the entire reason the card exists. The cost — a background window held for the
whole encode, hours on a big job — was accepted explicitly.

It works because the LA sync loop ticks every 2 s and `monitorCompanionJob` refreshes
`serverJobProgress` every 1.8 s: a live process means a live card. NOT gated on `queuePaused` (that
flag governs the transfer queue; pausing it does not stop a server-side encode, and gating would blank
the card for work still running). `companionQueued` waiters count too, same reason `.queued` does.

The earlier decision was the opposite — exclude it, on the grounds that nothing is LOST when the app
suspends, which is true: the server keeps encoding and `reconnectCompanionTranscode` recovers the job
by id on relaunch. That reasoning weighed durability and ignored the feature's actual purpose.

The counter-argument that came up on the way, and why it doesn't land as stated: "the plugin knows the percentage, so
the Live Activity could just show it." True but incomplete — `monitorCompanionJob` obtains that
percentage by POLLING the server every 1.8 s, which requires the app to be running. The server knowing
a number does not move it to a suspended phone.

What WOULD do it is ActivityKit push: `pushType: .token` instead of the `pushType: nil` we pass today,
with the Companion plugin POSTing updates straight to APNs. That is the correct architecture for
"remote thing reports progress" and is how delivery/sports-score activities update with the app fully
suspended. Believed blocked here — APNs authentication needs a key from a paid Developer account and
the app needs a push entitlement, while this build ships unsigned with NO entitlements file at all —
but that is **believed, not verified**, and it is the same shape of untested platform claim that kept
the `audio` keep-alive off the table for a week. The cheap test is one build: request with
`pushType: .token` inside a `do/catch` that falls back to `nil`, and log whether a usable token
arrives. Do that before declaring it impossible.

Note that push would NOT replace the keep-alive for transfers: it updates the display only and grants
no runtime, so bytes still would not move.

Rejected middle option: pointing the Live Activity's existing `estimatedStart`/`estimatedEnd`
projection at the server's reported ETA so a transcode bar keeps gliding while suspended. It renders an
estimate as fact, and a stalled transcode would animate cheerfully — the same class of lie as the
frozen "5.1 MB/s · 7m 7s left" card that started the whole background investigation.

**Swift:** `return` cannot transfer control out of a `defer` block — use `if`. Cost a review catch here.

### Removed: BGContinuedProcessingTask (v1.0.340)
Implemented, shipped behind an off-by-default toggle, and deleted once the keep-alive was proven. It
registered `ok=1` and submitted `ok=1` four times on this device and **never fired once** — suspected
to be the iPhone 17 Pro reports plus a sideloaded build carrying no entitlements. Recover it from git
history if a signed build or a future iOS makes the question live again; do not rewrite it.
`didFinishLaunchingWithOptions` now calls `BGTaskScheduler.cancel(taskRequestWithIdentifier:)` for the
retired id so iOS is not left holding a request whose handler no longer exists (`cancel`, unlike
`submit`, does not validate against `BGTaskSchedulerPermittedIdentifiers`, so dropping the plist entry
is safe).

**KEPT deliberately, despite looking like dead weight.** `BGProcessingTask`: it is the only background
progress when the keep-alive toggle is off. Honest caveat — `dl-bg-sched` has never actually been
observed firing, so "converges overnight" is the design, not a measurement. The entire background
`URLSession` daemon path: unreachable today because `daemonHandoverBroken` latches on this device, but
`handoverStamp` keys on the OS version, so an iOS point release re-tests ~250 lines of dormant slicing
logic for free. Deleting it would be irreversible without re-deriving the slicing design.

### PORTABLE RECIPE — indefinite iOS background execution, for any app
Written to be lifted into another project. Nothing here is Stashy-specific; the whole mechanism is
~150 lines and one plist key. Applies to any work that must keep running while the app is
backgrounded — downloads, uploads, sync, a long local computation.

**What it is.** iOS gives a backgrounded app one ~26 s `beginBackgroundTask` window. That window
cannot be *extended*, but it **can be replaced indefinitely** by an app that (a) declares the `audio`
background mode and (b) holds an **active** `AVAudioSession`. Ending the old assertion *before* asking
for a new one is what makes the grant renewable — iOS's window is **per-app, not per-assertion**, so
the clock only resets when nothing is outstanding.

**Step 1 — the plist.** Add `audio` to `UIBackgroundModes`. That is the entire declaration. It is
policed at App Store review, **not** by code signing, so it works in an unsigned/sideloaded build with
no entitlement and no provisioning profile change. (Shipping on the App Store with it while producing
no audible output violates guideline 2.5.4 — that is a review problem, not a technical one.)

**Step 2 — hold an active session, mixing.**
```swift
try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
try session.setActive(true)
```
`.mixWithOthers` is not optional in practice: without it you silence the user's music the moment a
background job starts. Never call `setActive(false)` on teardown — see the category trap below.

**Step 3 — the pump.** Play a near-silent looping tone, then cycle every 10 s:
```swift
while !Task.isCancelled {
    guard stillNeeded() else { teardown(); return }
    player?.play()
    try? await Task.sleep(for: .milliseconds(150))   // let the audio unit actually start
    endAssertion()                                   // END FIRST — this is the whole trick
    beginAssertion()                                 // ...then take a fresh one
    player?.pause()
    guard assertion != .invalid else { retryShortly(); continue }
    try await Task.sleep(for: .seconds(10))
}
```
The expiration handler must end the task **synchronously** (iOS kills the app otherwise) and then
*re-enter* the loop rather than surrender.

**Step 4 — nothing else may hold an assertion.** This is the mistake that makes the technique appear
not to work. If any other part of the app is holding a `beginBackgroundTask` — a per-item transfer
assertion, a library, an analytics SDK — the window never resets and you still die at ~26 s. Audit for
`beginBackgroundTask` and make everything else stand down while the pump runs.

**Step 5 — handle interruptions.** A phone call takes the session and iOS does **not** hand it back.
Observe `AVAudioSession.interruptionNotification` and re-`setActive(true)`. Without this the pump keeps
renewing an assertion with no audio behind it until the window closes for good. Reading
`Notification.userInfo` from a `@Sendable` handler is awkward under Swift 6 strict concurrency — just
attempt the re-claim on *any* interruption event; it throws harmlessly on the `.began` half.

**The tone.** Generate it at runtime rather than bundling a resource — a bundled asset adds a silent
failure mode (build system doesn't copy it, `path(forResource:)` returns nil, feature quietly dead).
0.5 s of 16-bit mono PCM at ~−60 dBFS played at `volume = 0.01` is inaudible on any hardware. Use a
frequency with a whole number of cycles in the buffer (400 Hz in 0.5 s = 200 cycles) so the infinite
loop has no seam. **Avoid digital silence and single-sample files** — iTorrent shipped a 46-byte
one-sample WAV and moved to a real clip; the reason was never documented, so respect it.

**The category trap.** The audio session is a process-wide singleton. Three interacting facts:
changing the category of an **already-active** session interrupts other apps; `setActive(false)` will
kill your own media if any is playing; and a media player that survives the background trip is often
never re-initialised, so it never re-asserts its own category. The resolution that works: leave the
session mixing on teardown, restore the app's real category **only when
`AVAudioSession.sharedInstance().isOtherAudioPlaying` is false**, and have the media player assert its
category explicitly at the moment playback starts rather than trusting a launch-time default.

**Gate it hard.** Re-check "is this still needed?" at the top of every cycle and tear down the instant
it isn't. This deliberately prevents suspension: radio, CPU and an audio unit stay live, and the
battery cost is real. Apple's documented memory ceiling for a mixable-audio background app is ~100 MB,
so a memory-hungry app can be jetsammed — survivable if your work is checkpointed, but plan for it.

**What does NOT work, so you don't waste the cycles** (all measured on this device):
`BGProcessingTask` runs only while the device is idle and dies the moment the user picks the phone up.
`BGContinuedProcessingTask` (iOS 26) registers and submits `ok=1` and **never fires** on a sideloaded
build. Background `URLSession` hand-over fails with `-3000` for reasons no probe could attribute to the
app. **Live Activities grant ZERO runtime** — they are display only; iTorrent's card stays live because
its *process* does. Android's foreground-service model has no iOS equivalent, and the audio keep-alive
is the closest thing that exists.

**Verdict line for your own port:** log a tick per cycle with elapsed seconds. Ticks climbing past ~30 s
while your work still progresses = it works. Ticks stopping, or the assertion being refused, = it
doesn't, and you should revert rather than tune.

**Known lie on a positive result:** `noteBackgroundWindowClosing` still flips the Live Activity to
"Paused — open Stashy" as the assertion nears expiry, which would fire while bytes are landing. Left
alone deliberately — it is correct for the current shipped behaviour, and rewriting it on a hypothesis
is how this subsystem acquired its regressions.

**Also unverified: whether declaring `audio` changes playback behaviour at all.** The player is
`AVPlayerLayer`-attached and `audiovisualBackgroundPlaybackPolicy` is left at `.automatic`, which Apple
documents only as "the system decides". Do not read either outcome on device as evidence about whether
the plist key took effect, and do not set `.continuesIfPossible` to "fix" it — the key is unconditional
while the keep-alive is opt-in, so that would give background audio to every user with the toggle off
and break the invariant that OFF is byte-identical to before.

### Free space: measure with `volumeAvailableCapacity`, never `…ForImportantUsage`
`ForImportantUsage` counts purgeable caches iOS merely *might* reclaim, and read **40 GB on a phone
with 4.1 GB genuinely free** — which is how a 5.5 GB download was waved through a preflight and then
died at 99%. `availableBytesStrict()` is the honest number and the one every decision uses;
`availableBytes()` is logged alongside it purely so the gap between the two stays visible.

### Space preflight — size it on the REMAINDER (fixed v1.0.338)
`startConnections` charged `item.totalBytes + margin` even when the part file already held bytes, so it
demanded room for data that was **already on disk**. Device trace: a 2.17 GB download with 360 MB
banked was refused with 2.62 GB free — it asked for 2.71 GB when 2.35 GB was the real need. Now sized
on `max(0, totalBytes - fileSize(part))`. The one case still charged the full 2× is a whole-file daemon
transfer, correctly: it cannot resume from our part and re-fetches everything into its own staging.

### Durability rules (v1.0.307–308 — read before touching the background path)
The engine's ONE invariant: **a byte that reached disk is never thrown away by a recoverable error.**
Six shipped defects violated it; the owner experienced them as "minimized a multi-thread download, the
island went 15% → 12% → 8%, froze, and the download restarted on reopening".

> **Historical note (v1.0.313 / v1.0.325).** Items 1 and 5 below describe code that no longer exists:
> multi-threading is gone, so there is no `chunkRange`, no eight segments and no `pendingForegroundStops`
> drain barrier. The *rules* still hold — item 1's diagnosis (a background task commits nothing until
> its range finishes) is exactly why v1.0.325 slices, and its `backgroundSliceBytes` idea came back as
> `DownloadManager.sliceBytes` (64 MB) with the defect that sank it the first time fixed: progress is
> now read only from the part file, never from bytes the daemon is still holding.

1. **Background ranges weren't durable.** A background `URLSessionDownloadTask` writes into URLSession's
   private temp file and only lands in our part at `didFinishDownloadingTo` — so an interruption
   discards everything since the range began. We requested a WHOLE segment per task (totalBytes/8, or
   the entire file for a single download). A minimized transfer could work for minutes, commit nothing,
   and the next attempt re-read a smaller on-disk size → a percentage that decreases. Fix:
   `backgroundSliceBytes` (16 MB) slices, chained in `connectionFinished`, which now closes a connection
   only when the part reaches `connections[conn].total` (that value equals `chunkRange`'s span exactly —
   verified for the remainder-absorbing last segment).
2. **Parts lived in `Caches`** → OS-purgeable while suspended. Moved to Application Support
   (`migrateLegacyParts` carries in-flight ones across).
3. **Mid-transfer range refusal wiped everything.** `badServerResponse` demoted and `launch(reset: true)`
   at any progress level, persisting the demote. A range-hostile server refuses the FIRST request, so a
   later refusal means a proxy collapsing the Range, a 416 from stale size metadata, or a transient
   error. Gated on `receivedBytes == 0`; with progress it backs off through the normal retry budget.
4. **`retry()` was destructive**, contradicting the comments in the merge-failure and -3000 hold paths
   that promise Retry resumes from the preserved parts. Now resumes; re-merges when all parts are done.
5. **The drain barrier could never clear.** `pendingForegroundStops` counted cancelled writers and was
   decremented ONLY by `NSURLErrorCancelled`; a cancelled writer that finished cleanly, reported a real
   error, or went through the delegate's `fail()` (which consumes the completion callback via `terminal`)
   never retired it. Stuck barrier ⇒ `startConnections` refuses every engine ⇒ zero progress for the rest
   of the process, and `enterForeground` skips it too. Now a `Set<Int>` retired from finished/failed/
   stopped, with a 4 s watchdog. `cancelTasks` callers that cancel en masse must call
   `registerDrainBarrier` first — the transient-network branch didn't (the v1.0.305 note lives in
   `suspend()`, which only `pause()` reaches), letting an NWPath flap open a second writer on a part
   still being appended to.
6. **Cold background relaunch stalls.** `loadInterrupted` restores `.paused`; `reconnectTasks` can't flip
   it because the app was relaunched *because* the task went terminal. Every continue-branch gates on
   `.downloading` ⇒ one slice per relaunch, then dead, plus the Live Activity ends itself. A background
   callback for a paused item adopts it.

Diagnostics for all of the above: Settings → Diagnostics → **Trace downloads** (`dl-parts` census is the
key line). `RemoteLog.flushNow()` on both lifecycle transitions, because the flush timer is frozen while
the app is suspended.

### Ranged single engine (post-v1.0.305 — "single" is no longer full-file by default)
Known-size **single-connection** downloads now run the SAME durable range engine as multi, with one
segment: a foreground data task streams appends into `part 0`; backgrounding hands off (drain barrier
included) to ONE bg range task from the durable offset. Rationale: the legacy full-file
`downloadTask` + iOS resume blob is validator-dependent (`ETag`/`Last-Modified`); when the blob can't
be produced the old path silently restarted from byte 0 — the owner's "backgrounded single download
restarts" bug. The full-file task survives ONLY for (a) unknown `totalBytes` (server transcode
restores) and (b) servers that refuse ranges: any non-206 to a range request inserts the item into
the in-memory `rangeUnsupported` set (`usesLegacySingle`), demotes via `launch(reset:true)`, and the
set self-heals after relaunch (ranged attempt → 206 check refuses → lands back in the set once).
Consequences: single downloads get true pause/resume and cross-relaunch part-based resume; the
-3000/-3003 handler holds ANY durable progress (8 parts or single part 0) — paused +
`resumeOnForeground`, Live Activity kept alive with a "Progress saved" state — and never wipes;
the old "ignore fg errors when !multiThread" guard is now scoped to `rangeUnsupported` members only,
because ranged-single items legitimately run foreground data tasks with multiThread off.

### Storage & privacy
- Video + sidecars live in **`Application Support/Stashy/{Downloads,DownloadsMeta}`** — private to
  the app (NOT visible in the Files app, unlike `Documents`), **excluded from backup**, migrated from
  the old `Documents` location. **Part files are in `Caches/DownloadParts`** (transient). Do not move
  downloads back to Documents.
- Sidecars per download: `<id>.json` (full `StashScene` + apiKey, `Codable`), `<id>-thumb.jpg`,
  `<id>-sprite.jpg`, `<id>.vtt` — these power the offline card, offline playback, and offline scrub
  sprites. **`StashScene` and all nested types are fully `Codable` — keep them that way.**
- Accessors the rest of the app relies on: `localFile(sceneID:)`, `localSprite(sceneID:)`,
  `localVTT(sceneID:)`, `hasDownload(sceneID:)`.

### Companion (server-side) transcode source + VMAF
- `Services/StashCompanion.swift` is the one typed app↔plugin gateway (`runPluginTask` / `findJob` /
  `custom_fields` / `TranscodeResult`). Downloads staging has a third source **Companion** (server GPU
  HEVC / CPU AV1 + resolution + quality): a **`.serverProcessing`** DownloadState drives a *determinate*
  bar from polled `Job.progress`, then hands the finished served file to the normal (Range-capable,
  8-way) byte engine — the load-bearing transfer path is untouched. One combined poll reads `findJob` +
  the scene's `custom_fields.stashy_transcode`, so completion survives an app kill or Stash GC'ing the Job.
- **VMAF quality targeting (plugin v0.2.x, 2026-07-14):** the plugin binary-searches the encoder quality
  knob on short sample windows to hit a phone-model VMAF target (High 97 / Balanced 94 / Small 91).
  During the search it writes a progress fraction to its served progress file (stage `analyzing`) — the
  app shows **"Analyzing quality — X%"** via `item.analyzing` and **skips the Job.progress clobber while
  analyzing** (Job.progress reads 0 during analysis; writing it made the bar visibly bounce — `ba7c65a`).
- Result fields `cq`/`vmaf`/`vmaf_target` come back in `custom_fields` (`TranscodeResult`); `item.vmaf`
  renders a "VMAF NN" chip in `DownloadsView`, and the finish log appends before→after size + % reduction
  and `VMAF: target → achieved · cq` (`f1b008a`, v1.0.252). Achieved sits at/just above target by
  CRF-step granularity — expected, not a mismatch.
- **v0.3.0 VMAF CRF map:** "Compute VMAF Map" / "Rebuild VMAF Map (full)" plugin tasks pre-compute
  per-scene optimal CRF (+ the sampled curve) per resolution into served `cache/vmaf-map.json` —
  incremental, resumable (per-run `vmafMapBudgetMin` time budget), zero scene writes. `run_transcode`
  looks up the cached CRF and skips the ~30 s live analysis; `_crf_from_curve` derives all presets from
  the one stored curve. Full detail: `stash-plugin/README.md` + ROADMAP §encode-quality.

### Follow-ups
- **Encryption (roadmap, not built):** opt-in "encrypt downloads" — Data Protection `.complete`, or
  app-level AES-GCM (CryptoKit + Keychain) decrypted via `AVAssetResourceLoaderDelegate`. See ROADMAP.
- **Live Activity / Dynamic Island** needs a **Widget Extension target** in `ios/project.yml`
  (ActivityKit + `NSSupportsLiveActivities`). **Riskiest remaining downloads item** — it changes the
  IPA structure for a *sideloaded* app; isolate in its own commit so it's revertable.

---

## 4. On-device download transcode — three engines, FFmpeg-first

`DownloadManager.transcode()` (~line 987–1029) routes each job across three engines (all conform to
`OnDeviceTranscoder`, declared in `VideoTranscoder.swift`):

- **Lossless stream copy** — same codec + same-or-smaller target size → `FFmpegTranscoder` remux-only
  fast path (incl. hev1→hvc1 retag). Near-instant.
- **Short clips (< 90 s)** — `VideoTranscoder` (`AVAssetReader` → `AVAssetWriter`, hardware
  VideoToolbox) when the container is AV-native AND the codec is H.264; otherwise `FFmpegTranscoder`
  (universal FFmpeg decode → VideoToolbox encode, commit `151e707`). **MKV/WebM/VP9/AV1 no longer throw
  `.unreadable`** — the old AVFoundation-only limitation is gone.
- **Long re-encodes (everything else)** → `FFmpegResumableTranscoder(workDir:)`
  (`f421ecd`/`d3c0108`/`960ac90`, 2026-07-04): checkpointed keyframe-aligned standalone chunk MP4s
  (`chunk_NNNN.mp4`, atomic-rename commit, `plan.json` + `settings.json` so even a cold relaunch
  resumes from the last committed chunk), finalized by a stream-copy concat remux with single-pass
  audio. **Deliberately chosen over single-file fragmented-MP4 append** (see the file header).
- Presets: resolution (Original/2160/1080/720/480) × quality (Low/Med/High bitrate ladder) × codec
  (HEVC default / H.264). Produces a faststart MP4, **replaces the offline file in place**, updates the
  item's spec chips.
- **AV1 encode is impossible on-device** (LGPL-minimal FFmpeg: videotoolbox H.264/HEVC + AAC encoders
  only — §5). AV1-encoded *downloads* DO exist via the server path: the Companion plugin's SVT-AV1 (§3).
- UI: `wand.and.stars` button on a completed download card → `TranscodePresetSheet` →
  `downloads.transcode`. Progress on the card (accent bar + "Transcoding… NN%") with cancel.
  Progress deliberately rides on `item.transcoding`/`transcodeProgress` bools instead of a new
  `DownloadState` case, to avoid touching the download state machine.

---

## 5. Playback pipeline (full detail in `docs/ROADMAP.md`)

- **Routing:** direct-play H.264-in-mp4/mov/m4v (native HW decode, instant seeks) → **on-device
  linear remux over loopback HLS** for HEVC / foreign-container H.264 (MKV etc.) → Stash server HLS
  for anything Apple can't decode.
- **FFmpeg** comes from the SPM package **`nphil/stashy-videoengine`** (product `FFmpeg`; Swift
  modules `Libavformat`, `Libavcodec`, `Libavutil`, …), pinned in `ios/project.yml` (`from: "1.0.0"`,
  resolving ~1.2.0). **LGPL-minimal + VideoToolbox**: broad decoders (h264/hevc/vp9/av1/…), demuxers
  (matroska/mov/…), but **encoders only h264_videotoolbox / hevc_videotoolbox / aac**. The app **only
  links** it; CI never compiles FFmpeg. To change FFmpeg capabilities, rebuild and publish a new
  `stashy-videoengine` release, then bump the version constraint — a separate macOS-CI project.
- Key files: `FFmpegRemuxer.swift` (custom AVIO read/write, demux→fMP4 stream-copy,
  `frag_keyframe+empty_moov`, 4 MB read-ahead, playhead pacing, seek-by-reinit), `FMP4Index.swift`
  (walks growing fMP4 → HLS byte-range playlist), `LoopbackServer.swift`, `LocalRemuxStream.swift`,
  `FFmpegSource.swift`.
- Player: `PlaybackEngine` protocol; `AVPlaybackEngine` (`onEnded` via
  `.AVPlayerItemDidPlayToEndTime`, route-based mute default); `ScenePlayerModel` (facade;
  `reachedEnd`/replay-from-0, time clamped to duration); `ScenePlayerView` (sprite `.task` prefers
  local downloaded sprite/VTT); `PlayerControlsView`; `ZoomablePlayerSurface`; live Metal blur
  backdrop.
- **Sprite scrubbing:** `SpriteThumbnails` parses WebVTT + crops a sprite sheet (no decode =
  instant). It accepts `file://` URLs (URLSession + ImageCache handle them) — that's how offline
  sprites work.

---

## 6. UI / library patterns

### The popover saga (bit us FIVE times)
**SwiftUI `.popover` is torn down & re-presented whenever its host view's structural identity
churns.** History on the filter/sort panel:
1. Hosted on a `.toolbar` ToolbarItem → rebuilt on every `isActive` change → flicker.
2. Moved to `.overlay` on the list `content` — but `content` is a `@ViewBuilder` that flips
   `_ConditionalContent` branches (grid ⇄ spinner ⇄ empty). A branch flip tears down the overlay's
   host → popover closes & reopens. (`PaginatedLoader.reload()` now keeps the old page visible and
   atomically replaces it, but the host still must not depend on list state.)
3. **Stable-host fix:** host from a **stable `ZStack` sibling** of `content` —
   `LibraryDropdownPanel` in `DesignSystem`, used in `ScenesView` and `PerformersView`. **Reuse this
   pattern for any new filtered list; never host a popover/dropdown on a conditional/churning view.**
4. **Tap-through + navigation race (v1.0.284):** the old `simultaneousGesture(TapGesture)` dismissed
   the dropdown while the card beneath handled the *same tap*. After a tag change, that could push an
   old card just before the debounced reload replaced the grid, occasionally stranding the detail
   screen's hidden navigation-bar preference on the root.
   `dismissesPopover` now installs a high-priority tap only while open (first outside tap dismisses
   only; drags still scroll+dismiss). `ScenesView` also gates `openScene` until the current query reload
   completes, and explicitly owns a visible system navigation bar plus a real `navigationTitle`.
5. **Whole-grid identity flicker (2026-07-20 perf pass):** `PopoverDismissalModifier.body` used an
   `if isPresented` around `content`, changing the structural type that wrapped the entire grid every
   time a dropdown opened or closed. Keep the modifier chain **unconditional**; disable its tap with
   `GestureMask.none` while closed. Scroll dismissal uses a transaction with animations disabled so the
   glass sheet is gone in the first moving frame. `InlineTagEditor` also renders its synchronous ranking
   cache on frame one and uses solid chips — no delayed panel resize and no nested glass samplers.
- **Scenes/Performers title parity:** both interactive jobs titles live in `.topBarLeading` and drive the
   same stable top-leading `LibraryDropdownPanel` spring. Scenes retains its real
   `.navigationTitle("Scenes")` for navigation-bar ownership, but a stable zero-size `.principal` item
   suppresses duplicate centered title chrome. Do not move the trigger back into `.principal`; it makes
   Scenes feel unlike Performers. This is toolbar-only and does not wrap or invalidate the grid.

### Jobs panel (`JobsPanel` + `JobMonitor`) — the scan-progress bug (fixed v1.0.296)
- **Stash's `jobQueue` is a nullable list (`[Job!]`) and its Go resolver returns a nil slice for an
  EMPTY queue — the wire value for "no jobs" is `null`, NOT `[]`.** `StashClient.jobQueue()` decodes the
  field optionally and maps nil → `[]`. The original non-optional decode made every idle-queue poll a
  decode failure: the panel froze its last snapshot on screen (a scan "stuck" at its last %) and after
  ~60 s of failures the monitor silently killed its own poll loop (tapping Scan then painted the bar
  once via `refreshNow` and it never moved again). On the `Job` type only `id`/`status`/`description`/
  `addTime` are non-null — keep any newly-queried field optional in `JobInfo`.
- `JobMonitor.attach()/detach()` is **refcounted**: a rapid dropdown close→reopen can deliver the dying
  panel instance's `onDisappear` AFTER the replacement's `onAppear`, and a plain start/stop pair let
  that late stop kill polling for the panel still on screen. The poll loop also **never self-stops**:
  ≥3 consecutive failures clear the stale snapshot (a frozen bar reads as a stuck job), flip
  `pollFailing` (panel shows "Can't reach Stash — retrying…"), and slow the cadence 1.5 s → 4 s until
  the last panel detaches. A cancellation mid-request (detach) is not counted as a failure, so the
  kept-for-instant-reopen snapshot survives.
- Queue actions surface `actionError` inline (plugin missing / auth / network) and show an optimistic
  "Starting …" line with a 3-poll grace instead of `try?`-swallowing failures.
- The task buttons are compact caption2 icon+name chips in a `FlowLayout` (a few short rows) under a
  "Library tasks" caption — solid fills on the glass panel, matching the filter panel's tag chips.

### Scan vs Generate — Stash sends NO defaults, and a rescan can't repair a bare scene (v1.0.369)

Verified against stashapp/stash `develop` (Aug 2026). Every claim below has a file behind it — do not
re-derive, and do not "simplify" any of it back to an empty input.

- **The two tasks are not two strengths of one thing.** `metadataScan` = *discovery*: walk the library
  paths, hash + ffprobe new/changed files, create the scene rows; its toggles mean "while ingesting a
  file I am **handling**, also make these". `metadataGenerate` = *production*: derived media for rows
  **already in the DB**, ignoring disk entirely. Only Generate can do markers, marker screenshots,
  transcodes, heatmaps, `overwrite`, or scope by `sceneIDs`. Only Scan can create the scene.
- **THE LANDMINE: Stash applies no server-side defaults to either mutation.** The flags live in
  `config.ScanMetadataOptions`, embedded in `manager.ScanMetadataInput` as plain Go `bool`s (not
  `*bool`), and `MetadataScan` → `manager.Scan()` passes the input through untouched. **Every field the
  caller omits arrives as `false`.** The ticks on Stash's Tasks page are the saved `defaults.scan` /
  `defaults.generate` config, applied **by the browser** when it builds the mutation — an API client
  gets nothing. Stashy shipped an empty `ScanMetadataInput()` (and the plugin `{"paths": […]}`) under a
  comment claiming "server defaults", so every scan it ever queued was ingest-only: no cover, no
  preview, no scrubber sprite, no phash. That was the owner's "fetched videos don't process" report.
- **A later scan CANNOT backfill it** — the half that makes the bug permanent.
  `handlerRequiredFilter.Accept` (`internal/manager/task_scan.go`) returns true only when
  `CountByFileID == 0`; a video that already has a scene returns **false**, so `onUnchangedFile` skips
  the handler and `sceneGenerators.Generate` never runs, no matter which toggles are ticked. The only
  repairs are `metadataGenerate` or a scan with `rescan: true` (which routes through the
  `forceRescan` branch of `onExistingFile`). This is why "sometimes it worked": those were files the
  flag-less scan **missed** (still muxing / a `.part`), later ingested fresh by a UI scan with the
  toggles on.
- `sceneGenerators.Generate` runs with `const overwrite = false`, so scan-time generation never redoes
  existing work — re-running is cheap and idempotent.
- **The app's contract** (`Services/StashTaskDefaults.swift`): read `configuration.defaults.scan` /
  `.generate` once per session (`StashTaskDefaultsCache`) and send them explicitly, so a Stashy-queued
  task matches the same task started from the web UI. Every flag is `Bool?` because synthesised
  `encode(to:)` uses `encodeIfPresent` — **a field the server's schema doesn't know fails the whole
  mutation**, so `.fallback` (query failed / nothing saved) carries only long-standing fields, while
  keys read back from a successful query are safe to send by construction. An all-off payload is
  treated as "never saved" and swapped for the stock ticks — a task that generates nothing is the bug,
  not a preference. `GenerateMetadataInput` is FLAT: `GenerateOptions.encode(to:)` is called on the
  shared encoder so its keys merge alongside `overwrite` (pinned false) and the optional `sceneIDs`.
- **Entry points:** jobs panel → *Scan Library* / *Generate* (library-wide); scene ••• → *Generate
  Media* (`sceneIDs: [id]`, toast feedback). Plugin-side, `_scan_generate_options` does the same for
  the post-fetch scan — but deliberately **never** takes `rescan` from the defaults, because that scan
  is scoped to the fetch folder and would re-handle every file previously fetched into it.

### Metadata scrape/edit suite (v1.0.298 foundation; v1.0.299 auto-merge rework)
- **`Services/StashScraper.swift` is the ONE typed gateway** for scraping + metadata editing (wraps
  StashClient like StashCompanion does). Contracts verified against stashapp/stash master — do NOT
  guess: `ScraperSourceInput` takes **exactly one** of `scraper_id` / `stash_box_endpoint`;
  `scrapeSingle*` return non-null lists (`[]` = no match); ALL `Scraped*` fields are nullable except
  `ScrapedStudio.name`/`ScrapedTag.name`; `stored_id` = the matched LOCAL entity (nil = not in the
  library); scraped `image`/`images[]` are **base64 data URLs** (the server already fetched them) and
  the `cover_image`/`image` mutation fields accept "URL or base64 data URL" — pass through unchanged;
  update inputs are **omit-to-keep** (nil optionals encode away) while list fields (`performer_ids` /
  `tag_ids` / `urls` / `stash_ids`) REPLACE wholesale; classic performer scrapers are **two-step**
  (query → re-scrape the picked result as `performer_input`, which accepts no images/tags) while
  stash-box results arrive complete; gender strings normalize case-insensitively to GenderEnum or are
  DROPPED (an invalid enum literal fails GraphQL validation).
- **v1.0.299 auto multi-source (owner: only StashDB / ThePornDB / FansDB, query them all at once, no
  picker):** `isAllowed(name:endpoint:)` keyword-filters sources to those three; `rank(_:)` gives the
  StashDB→TPDB→FansDB priority used for conflict defaults + merge order. `scrapeSceneEverywhere` /
  `searchPerformersEverywhere` fan out over every configured allowed source in a `withTaskGroup`
  (capturing `self` — a `Sendable` struct — is fine) and return **`MultiSourceResult`** = `{ items,
  failed }`, where `failed` = names of UNREACHABLE sources. This is the key resilience contract: a
  source that ERRORS is recorded in `failed` (never blocks the others, never a false "no match"); a
  source that simply had no hit is in neither list; `NoSourcesError` is thrown only when none of the
  three are configured. `groupPerformers` collapses the same person (lowercased name + birthdate) into
  one `MergedPerformerCandidate` tagged with its sources; `resolvePerformer` fetches full detail from
  every contributor in parallel and merges by priority (apply `ordered.reversed()` so StashDB wins),
  unions images (priority order), records one `stash_id` per stash-box.
- **Sheets** (`SceneMetadataSheet`, `PerformerMetadataSheet`, `PerformerCreateSheet`; shared pieces in
  `Features/Shared/ScrapeUI.swift` + `Features/Performers/PerformerForm.swift`): medium-detent system
  sheets (`presentationDetents([.medium, .large])` +
  `presentationBackgroundInteraction(.enabled(upThrough: .medium))`) — the iOS 26 glass "mini window"
  over the still-playing video. System-composited, so the custom-glass-over-scroll landmine doesn't
  apply. **Scene merge:** per-field **`SourceConflictChips`** appear only where sources disagree
  (title/date/details/studio/cover), each labeled with the contributing source(s), plus a "Current"
  chip to keep the existing value; tags+performers UNION deduped (by stored_id then case-insensitive
  name). **Performer merge:** the merged candidate list (`MergedPerformerRow` with source badges) →
  pick → `resolvePerformer` fills the form + the photo picker. Unmatched scene entities render as
  dashed "+" chips (tap → `tagCreate`/`studioCreate`/`performerCreate` with the full scraped profile,
  created id swapped in); anything left dashed is dropped on Save and a caption says so.
- **Photo upload:** `PerformerPhotoPicker` (PhotosUI `PhotosPicker`) sits in the performer photo strip
  (add/manual/edit). A picked image is downscaled + JPEG-encoded to a base64 data URL **off-main**
  (`ImageUpload.dataURL` in a `Task.detached`), prepended + auto-selected, and saved via the normal
  `image` field. `.task(id: pickerItem)` does the load (PhotosPickerItem is Equatable/Sendable); it
  resets `pickerItem = nil` at the end (the re-fire immediately no-ops).
- **Empty dates are OMITTED, never sent** ("" is an invalid Stash date; clearing a date isn't supported
  in-app). **Refresh-in-place after Save:** each sheet refetches the scene/performer INSIDE its own save
  task and hands it back via `onSaved(fresh)` — SceneDetailView assigns `fullScene` (read as `shown =
  fullScene ?? scene`), PerformerDetailView assigns `refreshed` (read as `current = refreshed ?? performer`),
  and the portrait task keys on `image_path` (not id) so a changed/uploaded photo reloads.

### Stores and loaders
- **`PaginatedLoader<T>`** (generic, `@Observable @MainActor`): dedups pages by id,
  infinite-scrolls, and has a **generation token** so a superseded in-flight load discards its
  results (prevents a crash under the open popover from rapid filter changes). A view-level 250 ms
  debounce on query changes sits on top.
- **`LibraryEdits`** (`@Observable @MainActor`, app-wide via environment): optimistic overrides for
  rating/favorite/delete keyed by id (`Int??` for nullable ratings), `visible()` filters deleted.
  **Read ratings/favorites THROUGH this store** so edits reflect instantly across screens.
- **`StashClient`** has DB-lock retry (Stash is SQLite; "database is locked" → back off
  500/1000/1500 ms). `SceneQuery.downloadedOnly` is served locally from `downloads.items`, bypassing
  the network.
- `ImageCache` (actor): 2-tier (NSCache + downsampled JPEG on disk), LRU-evicted, priority tier for
  performer portraits (kept longest). Cache keys strip the `apikey` query param. Ahead-of-scroll work
  goes through a **48-request deduplicated queue with two workers**; never restore the former
  task-per-URL fan-out from every appearing cell. The persistent tier is 800 MB. The decoded-memory
  budget adapts to physical RAM (128–256 MB), and the decoded ThumbHash cache holds up to 20,000 entries
  under a separate 64 MB cost cap.
- Settings measures "Cached previews & images" when it opens and once on
  `ThumbnailPrefetcher.completionRevision`. That revision advances only after a Cache All Thumbnails run
  has fully unwound (success or cancellation), so the displayed bytes include the final settled image
  write without polling progress or scanning cache directories during the job. Cancellation keeps
  `isRunning` true until that terminal point, preventing an old cancelled run from clobbering a new one.
- Companion served-map stores (`PlayabilityStore`, `VmafMapStore`, `LoudnessStore`, `ThumbHashStore`)
  fetch on their main-actor owners but decode JSON/base64 in utility detached tasks, then publish the
  completed Sendable value on main. A large library map must never parse during a scrolling frame.

### Behavior defaults
Filters reset on launch; **sort field+direction persist** (UserDefaults). Blur toggles for
thumbnails/titles. Face ID is immediate (minimal privacy blur, no splash). Videos start muted unless
on AirPods/private audio route.

### Scene names: `displayTitle`, never `scene.title ?? "Untitled"` (v1.0.366)
Plenty of libraries have scenes with no metadata title, and a grid of "Untitled" cards is useless. The
model owns the fallback — `StashScene.displayTitle` (title → file basename → "Untitled") and
`fileDisplayName` (`Models/Scene.swift`). Every scene-name render site goes through it: grid card
(`ScenesView.SceneCard`), detail header (`SceneDetailView.metadata`), glasses focused-title block and
grid header. Rules:
- **Truncate the middle, not the tail.** File names carry their identity in the head and their
  extension in the tail; a tail clip drops both the resolution/group suffix and the `.mkv`, so every
  fallback site uses `.truncationMode(.middle)`.
- **The card additionally caps at 52 chars** via `displayTitle(maxLength:)` — that's what two lines of
  `.system(size: 10)` hold in a half-width cell, so the ellipsis lands in the middle instead of the
  layout hard-clipping at the line break. Real metadata titles are returned untouched by that
  overload (they're short and hand-written; clipping them is the layout's job).
- **Don't push the fallback into edit/sort paths.** `SceneMetadataSheet` still binds `data.title ?? ""`
  (a filename must never be pre-filled into the editable title field, or the next save writes it to the
  server), and client-side title sort still keys on `title` so it matches the server's ordering.

### Scrubbing (two gestures, one model) — v1.0.248-era
There are **two** scrub gestures and they must feel identical:
1. **Bar drag** — `ScrubBar.body` `DragGesture` in `PlayerControlsView.swift`. Touch anywhere on the
   full-width, 22 pt-tall track (not just the thumb); first touch jumps to position (tap-to-seek).
2. **Video hold-scrub** — `ZoomablePlayerSurface.Coordinator.handleLongPress`. **This lives in the
   pinch/zoom gesture file — a landmine.** Only ever touch the *time-math* inside `.changed`; leave the
   gesture setup, delegates, `scroll.isScrollEnabled` toggling, and lifecycle alone, or you risk pinch/pan.
- **Variable speed:** shared `ScrubSpeed` enum (module-level in `PlayerControlsView.swift`) →
  `tier(verticalDistance:)` returns (rate, tier 0–3): full speed near the reference line (bar centre, or
  the press-start Y), easing to Fine (0.1×) as the finger moves vertically away. Both gestures are
  **incremental** (accumulate Δx·rate onto the position); the video path keeps its **own accumulator**
  (`scrubAccumTime`) rather than reading the `scrubTime` binding back (avoids propagation-timing bugs).
- **`speedTier` is a shared `@Binding`** owned by `ScenePlayerView`, passed to both the surface and
  `PlayerControlsView`→`ScrubBar`, so the one subtle speed label (opacity-driven, scoped so it never
  animates the thumb) reads the same regardless of which gesture is active.
- **Exact-frame preview** (`Services/ScrubFrameProvider.swift`, `@Observable @MainActor`): decodes the
  real frame under the finger for **local downloads only** (`ScenePlayerModel.scrubFrameURL` =
  `route.url` when `isFileURL`). `AVAssetImageGenerator` with zero tolerance; coalesce by calling
  `cancelAllCGImageGeneration()` before each request so only the latest completes; capped `maximumSize`;
  carry the decoded `UIImage` back to the main actor in an `@unchecked Sendable` box. `PlayerControlsView`
  feeds it from `.onChange(of: scrubTime)` (covers both gestures) and `ScrubBar` prefers it over the
  sprite tile. Release seek is already frame-exact for local media (`ScenePlayerModel.seekPrecise`).
- **Pitfall that cost a build:** adding `speedTier`/`exactFrame` to `ScrubBar` — a SwiftUI `View`'s
  synthesized init requires call-site args in **declaration order** (Swift won't reorder labelled args).

### UI/UX overhaul (v1.0.253–265) — design system, mesh background, motion, glass discipline
A cohesive iOS-26 pass over the **browse** surfaces (the fullscreen player rework is deferred). **Read this
before touching theme, backgrounds, chips, or grid→detail transitions.** Owner asks (all shipped): lean on
Liquid Glass where functional; Apple-Music/Photos-grade motion; a themed background gradient with depth
that is **not biased toward black**; **fluid scrolling above all**.

- **`DesignSystem/` folder** (XcodeGen globs `Stashy/` → just add files, never touch a `.pbxproj`):
  - `ThemedBackground.swift` — a per-theme **static** `MeshGradient` (3×3 regular-grid `points`,
    `.perceptual` colour space) exposed as `.themedBackground()`. Wired behind every browse screen
    (Login, Scenes, Performers, Downloads ×2, Scene/Performer detail, Settings) replacing the old flat
    `backgroundColor.ignoresSafeArea()`. **One static layer, never per-cell** — recomputed only on theme /
    slider change, so it is free while scrolling (the scroll-perf rule). Its explicit `RenderIdentity`
    includes only palette/vibrancy/lift: this forces iOS 26 to replace a retained off-screen tab's stale
    mesh layer after a theme change (Scenes once restored an old dark Synthwave mesh over light Meadow)
    without adding any scroll-time invalidation.
  - `CardStyle.swift` — `CornerRadius` (card 12 / small 10 / large 18) +
    `cardContour(isDark:)` (a sub-point edge stroke). The former blurred grid-card elevation was removed
    in the inertial-scroll pass: even with a vector source, a blur still consumes compositor fill-rate for
    every visible card at 120 Hz.
  - `FilterPill.swift` — `filterPill(active:tint:foreground:)`, the one filter-chip style. Active = solid
    `tint` fill + white label; inactive = `foreground.opacity(0.12)` capsule. **Solid, never glass** (see
    glass discipline). Panel control chips use it; the smaller inline-tag chips use the same solid fills
    with their compact padding.
- **Theme.swift** — 14 distinct palettes (dark: nocturne/aurora/synthwave/ember/verdant/ruby/slate/mocha;
  light: daybreak/blossom/meadow/citrus/periwinkle/seabreeze — synthwave & mocha kept by owner request).
  `meshColors(vibrancy:lift:)` builds the 9 mesh colours from the palette tokens, blending toward
  `foreground`/`primary`/`accent` — **never toward black** ("don't bias the gradient toward dark").
  **`MeshTuning`** = slider ranges + defaults (vibrancy 0.50, lift 0.32). `ThemeManager` persists **four**
  values — vibrancy & lift, **separately for light & dark** (`stashy.mesh.{vib,lift}.{dark,light}`);
  `currentMeshVibrancy/currentMeshLift` select by `current.variant`. Settings → "Background depth" hosts the
  4 sliders (`meshSliderRow`).
- **Motion** (system springs → reduce-motion-safe): Scenes and Performers use the native navigation
  push/pop. The earlier grid→detail `.navigationTransition(.zoom)` was removed in the 2026-07-20
  performance pass: iOS 26 FB21961572 retained the matched source after pop, forcing a 600 ms scroll lock
  or showing a frozen card. Owner chose immediate, consistently fluid scrolling over that hero. The
  long-press scene preview keeps its own fake hero. `.tabBarMinimizeBehavior(.onScrollDown)` remains on the
  `TabView` (iOS 26, iPhone). `.contentTransition(.numericText())` + `.animation(.snappy, value:)` remains on
  the selection-count button (rolling digits).
- **Glass discipline (cost a CI cycle):** Liquid Glass only shows character over **vibrant/varied content**
  (the mesh, media) — NOT over flat `Material` or over another glass surface. So the floating filter **panel**
  (`LibraryDropdownPanel`) is `.glassEffect(.regular)` because it sits over the mesh/grid, but the **chips
  inside it are solid `filterPill`s**. History: v1.0.262 glassed the chips over the then-material panel →
  invisible; v1.0.264 flipped it (glass panel, solid chips); v1.0.265 made active chips fill accent.
- **No scrollbars anywhere** (owner standing pref): `UIScrollView.appearance()` indicator flags off in
  `StashyApp.init()` + `.scrollIndicators(.hidden)` in `ContentView` (propagates via environment). Reinforce
  on any new scroll view; never reintroduce an indicator (incl. `UIScrollView`-backed views).
- **Scroll-perf rule (strengthened 2026-07-20):** `ScenePreview` does **no global frame conversion while
  scrolling**. It tracks only the cell's stable `CGSize`; on long-press,
  `UIGestureRecognizerRepresentable.Context.converter` supplies the global + local locations and the
  source rect is reconstructed once. The long-press fake hero is preserved. Keep global
  `frame(in: .global)` / preference writes, unbounded task creation, JSON decoding, animated glass, and
  matched-transition source state out of visible grid cells and scroll-time main-actor work.
- **Inertial scroll keeps content flowing:** `BrowseScrollCoordinator` is driven by
  `onScrollPhaseChange` on Scenes, downloaded Scenes, Performers, and performer-detail scene grids.
  DownloadManager skips only its 120 ms **UI progress poll** while moving (transfer engines continue
  untouched). v1.0.286's image freeze was a failed tradeoff: it made cards blank and did not materially
  improve device scrolling. ThumbHashes render during motion, memory hits publish immediately, and
  disk/network loads publish on completion. The later idle-gated pagination was also wrong: device
  telemetry showed 119.67–119.92 FPS / 8.33 ms p95 while the visible "stop" was the fling reaching the
  physical end of a 25-item page. `PaginatedLoader` now starts the next request one quarter into the newest
  page, appends immediately without showing a layout-changing next-page footer, and exposes a cheap
  `contentRevision`; each grid uses that revision to enqueue the newest page's images once. This removes
  the former per-appearing-card index/suffix scan while giving thumbnails maximum lead time. Scene
  download/transcode badges remain one array walk. The coordinator is deliberately **not Observable**.
- **Browse scroll telemetry (opt-in RemoteLog):** `BrowseScrollPerformanceMonitor` attaches a 120 Hz
  `CADisplayLink` only while a tracked grid is moving and Settings → Diagnostics → Stream debug logs is
  enabled. It records callback intervals and phase with no per-frame observation writes, then does all
  sorting/string/log work after `.idle`. ntfy receives separate `scroll-segment` lines for interaction
  and deceleration plus `scroll-end`: effective FPS, target Hz, avg/p95/p99/max frame time, hitch %, severe
  ≥50 ms gaps, missed maximum-Hz intervals, coefficient-of-variation "judder", a cadence histogram, and
  real-thumbnail publication/memory-hit/load-latency counts. Pagination adds page-append count/item count/
  p95 request latency so any append hitch is directly correlated. It diagnoses main-run-loop cadence; it
  cannot directly prove a compositor-only missed presentation. Normal use with logging off has no display
  link.

### Minimized search (v1.0.268) — no scroll-top drawer, tap-to-expand button
Owner ask: search must NOT appear when the list scrolls to the top; it should pop up only when the
magnifier is tapped. Applied to Scenes & Performers.
- **Why the old setup revealed it:** `.searchable(..., placement: .navigationBarDrawer(displayMode:))`
  puts search in the nav-bar drawer, shown at the top and hidden on scroll-down — BOTH displayMode cases
  (`.automatic`, `.always`) show it at scroll-top. The `isPresented:` binding governs only the
  ACTIVE/focused state, NOT whether the collapsed drawer chrome renders. No drawer mode hides it at top.
- **Fix (iOS 26):** `.searchToolbarBehavior(.minimize)` (spelling is `.minimize`, NOT `.minimized`)
  renders the searchable as a **button** that expands into the field on tap — nothing at scroll-top. Drop
  the `.navigationBarDrawer` placement (default `.automatic`). Pin the button top-left with
  `DefaultToolbarItem(kind: .search, placement: .topBarLeading)` inside `.toolbar { }` (it's
  `ToolbarContent`, iOS 26.0+); without it the button lands in the iOS 26 default (bottom) slot. Remove the
  custom magnifier `Button` — the system provides one. Keep `isPresented: $searchPresented` (optional; the
  system drives it) + the debounced `.task(id: searchText)` → `query.search`.
- **Toolbar landmine respected:** the search `DefaultToolbarItem` is UNCONDITIONAL (always present) and the
  top-leading `ToolbarItem` keeps stable identity with only its CONTENT conditional (`if selectionMode {
  Cancel }`). Do NOT gate the whole search item behind `if !selectionMode` — a conditional whole toolbar
  item risks the "vanishing button" drop bug. Accepted consequence: the magnifier shows during Scenes
  multi-select next to Cancel.
- **All iOS 26.0+** (`searchToolbarBehavior`, `SearchToolbarBehavior.minimize`, `DefaultToolbarItem`,
  `ToolbarDefaultItemKind.search`); deploy target is 26.0 so no `#available` gate. Signatures were
  doc-JSON verified before push.

---

## 7. Smaller facts that will still trip you up

- **`AppDelegate` lives in `Services/OrientationLock.swift`** (surprising location). It handles: the
  interface-orientation lock (whole app portrait; only fullscreen video allows landscape via
  `OrientationController.lock`), the **background-URLSession completion handler**
  (`handleEventsForBackgroundURLSession` → `BackgroundDownloadSession.completionHandler`, called by
  `DownloadDelegate.urlSessionDidFinishEvents`), the audio-session category, `RemoteLog` enable, and
  a stale-temp-file sweep. Wired via `@UIApplicationDelegateAdaptor` in `StashyApp.swift`.
- **Rating scale:** Stash stores **0–100 (`rating100`)**; UI shows **0–5 stars = value/20**.
  Favorites are plain booleans. Don't confuse the scales.
- **Stash auth:** append **`?apikey=<key>`** to media/image/sprite/vtt URLs; GraphQL uses the
  `ApiKey` header. `StashClient` holds `serverURL` + `apiKey`, both in the **Keychain**
  (`KeychainService`); `AppState` (in `StashyApp.swift`) owns the client and drives login/logout.
  URL helpers on `StashScene`/`Performer` (`directFileURL`, `thumbnailURL`, `spriteURL`, `vttURL`,
  `imageURL`) all take `apiKey:`.
- **`DownloadState` is switched exhaustively** in `DownloadsView`'s
  `controls`/`statusText`/`statusColor` — adding a case means updating those switches.
- **`FlowLayout`** (custom `Layout`) for chip rows; **`PopupMenu`**/native `Menu` for 3-dot actions;
  **`glassEffect(...)`** for Liquid-Glass chips. `ThemeManager` (`@Observable`, env-injected)
  exposes `accentColor/foregroundColor/backgroundColor/surfaceColor/preferredColorScheme`.
- **Navigation:** per-tab `NavigationStack` with a `[Route]` path + `AppRouter` (`Route` enum,
  `RouteDestination` switch, `.downloads` route). Cross-screen jumps (e.g. tag tap → filtered
  scenes) go through `router`. `fullScreenCover`/`sheet`/push usage is currently a bit ad hoc — the
  owner wants this rationalized (ROADMAP nav-cleanup item); tread carefully here.
- **Telemetry:** `RemoteLog` → ntfy (`Services/RemoteLog.swift`), OFF by default; server URL + topic
  configurable in Settings → Diagnostics (self-hostable). **KEPT feature — owner decision 2026-07-16
  reversed the old remove-before-wider-release rule**; the §5 checklist in
  `docs/OPTIMIZATION_PLAN_2026-06-30.md` is reference only. Privacy note: on the default public
  `ntfy.sh`, anyone with the topic name can read the stream — the topic is a random burner ("New topic"
  rotates it); point at a self-hosted ntfy for full privacy.

---

## 8. Release history quick-reference

- `ef9e591` background-session switch → -3000 regression → reverted in `22f6740`.
- v1.0.101: Downloads M1 (8-connection engine + screen), downloaded-only filter, offline sprites.
- v1.0.105–106: on-device transcode (AVFoundation, presets, card UI).
- v1.0.107: single-connection background continuation with foreground handoff (`b8ea21d`).
- 2026-07-03/04: downloads transcode goes FFmpeg-first (`151e707` universal engine;
  `f421ecd`/`d3c0108`/`960ac90` checkpointed resumable engine — §4).
- 2026-07-04/05: M-A on-device *streaming* transcode playback tier shipped… then **removed** in
  `c088325` (flaky + glitchy scrubbing; exotic codecs → server HLS). M-B (server-quality menu) stays.
- Also shipped in the big handoff session: scene ratings + performer/tag favorites (`LibraryEdits`),
  Apple-Photos-style image viewer, portrait-fullscreen tab-bar fix, popover stable-anchor fix,
  private Application Support storage migration, network-loss recovery ("Waiting for network…" +
  bounded auto-retry), replay-after-end + time-over-duration fixes.
- **v1.0.253–265 — UI/UX overhaul** (browse surfaces; player deferred): new `DesignSystem/` (mesh
  `ThemedBackground`, `CardStyle`, `FilterPill`), Theme.swift rewrite (14 palettes + `meshColors` + 4
  background-depth sliders), hero **zoom** grid→detail transitions, tab-bar minimize-on-scroll,
  `numericText` selection count, Liquid-Glass filter panel with **accent-fill active chips**, no-scrollbars
  enforcement, and the `ScenePreview` `onGeometryChange` scroll-perf fix. Full detail in §6.
- **v1.0.266–268 — Phase-4 consolidation + minimized search**: DesignSystem primitives
  `LabeledSegment`/`overlayBadge`/`capsuleField` + `SceneFilterBar` → `filterPill`; and search reworked to
  an iOS 26 minimized toolbar button (no scroll-top drawer — `.searchToolbarBehavior(.minimize)` +
  `DefaultToolbarItem(kind: .search)`, §6).
- **2026-07-20 library performance pass:** fixed dropdown whole-grid identity flicker; immediate
  no-animation glass removal on scroll; removed nested tag-chip glass; eliminated scroll-time global
  geometry conversion; bounded thumbnail prefetch to two deduplicating workers; decoded companion maps
  off-main; removed iOS 26 zoom-navigation sources and their 600 ms return scroll lock. §6 is the guardrail
  for future browse fixes.
- **2026-07-20 inertial-frame follow-up:** initially deferred pagination mutations and the transfer UI poll;
  replaced blurred grid elevation with a contour stroke. The attempted thumbnail publication/prefetch/
  ThumbHash freeze was reverted after device feedback (blank cards, no meaningful FPS gain). Real images
  and ThumbHashes now remain live during motion, memory/decoded-placeholder caches are larger, and opt-in
  ntfy scroll frame telemetry supplies evidence for the next isolation pass. The pagination part was later
  superseded by the telemetry-driven fix below; the transfer UI poll remains protected. Actual downloads
  and their foreground eight-way engine are unchanged.
- **2026-07-20 telemetry-driven pagination follow-up:** 42 sessions / ~80 seconds measured Scenes at
  119.67 FPS and Performers at 119.92 FPS, both with worst p95 8.33 ms and no ≥50 ms severe hitch, even
  across 4,137 thumbnail publications. The perceived hard stops were 25/30-item content boundaries caused
  by `loadNextIfNeeded` waiting for `.idle`. Pagination now fetches early during motion, hides next-page
  loading state, appends atomically, and prefetches every new page's images once via `contentRevision`.
- **v1.0.296 — jobs-panel scan-progress fix + compact task chips:** the null-vs-empty `jobQueue` decode
  bug (see §6 "Jobs panel") froze/hid the scan progress bar since the panel shipped; JobMonitor gained
  refcounted attach/detach, a never-self-stopping poll loop with a visible reconnecting state, inline
  action errors, and an optimistic "Starting …" line. The four task buttons shrank to caption2 flow
  chips under a "Library tasks" caption.
- **v1.0.297 — multiThread download default restored ON** (owner decision; the v1.0.284–295 rework had
  defaulted it OFF). Staging still offers Background per download; the bad-server-response and -3000
  fallbacks still demote an item permanently; pre-field sidecars restore as multi-thread.
- **v1.0.298 — metadata scrape/edit suite:** scene + performer ••• menus gained Scrape/Edit Metadata
  (medium-detent glass sheets over the playing video), and Performers gained a + add-performer flow
  (scraper search → pick match → pick photo → create). New `StashScraper` gateway; contracts + sheet
  patterns in §6 "Metadata scrape/edit suite".

### Shipped-feature log (moved out of `CLAUDE.md` 2026-07-25)

This was `CLAUDE.md`'s "Current state" section. It grew into a 336-line changelog in an
always-loaded file — ~8.5k tokens every session, for history almost none of which a given
session needs. It lives here now, read on demand. `CLAUDE.md` keeps only the CURRENT release
and the work queue; the one-line "do not repeat this" lessons stay in its Landmines section.
Newest first.

- **Fetch URL → server (v1.0.359–365 + plugin 0.5.0→0.5.3), 2026-08-09.** Paste or resolve a link →
  the SERVER (yt-dlp, self-bootstrapped into the plugin's `cache/`) downloads it into the library and
  scans it; the phone never carries the bytes. Live "On Server" cards in Downloads read the plugin's
  served `fetch-status.json` (speed/size/ETA) with pause (`stopJob`, `.part` kept) / resume (resubmit
  same `fetch_id` → byte-exact) / cancel / queue. In-app WKWebView resolver (`LinkResolverView`) for
  button-gated + streaming hosts: auto-captures download AND media responses, sniffs `.m3u8`/`.mpd`
  stream URLs, contains popup ads offscreen, and replays Origin + a per-domain cookie jar (`--cookies`)
  so token-gated CORS streams authenticate. **DRM streams (SAMPLE-AES/FairPlay/Widevine) are out of
  scope — no bypass.** Full mechanics + landmines in the §8 "Fetch URL → server pipeline" entry above;
  packaging rule: plugin zip + `index.yml` sha256 rebuilt together, `stash-plugin/**` pushes skip CI.

- **Backgrounded-downloads round 3 (v1.0.307–308) — SIX defects, all "durable bytes thrown away or
  never committed"**: the owner's "% went 15→12→8, froze, restarted on reopen" was NOT one bug. See the
  new Landmines entries + ENGINEERING_NOTES §3 "Durability rules" for the full list; the headline is that
  a background download task commits nothing until its whole range finishes, so whole-segment background
  ranges were structurally unable to make durable progress while minimized. Also shipped: **download
  tracing** (Settings → Diagnostics → Trace downloads) — `dl-parts` census, `dl-slice`, `dl-err`,
  `dl-wipe`, `dl-drain-timeout`, `dl-la`. UNVERIFIED on device; if it recurs, the trace names the part.
- **Latest push — backgrounded-downloads robustness round 2 + auto-collapse:**
  (1) **Ranged single engine**: known-size single downloads now run the SAME durable engine as multi
  with one segment (fg data task streaming into part 0 ⇄ one bg range task from the durable offset);
  the legacy full-file task + iOS resume blob (validator-dependent, silently restarts from byte 0 when
  the blob can't be produced — the owner's "backgrounded single restarts" report) survives ONLY for
  unknown sizes and range-refusing servers (`rangeUnsupported` set, fed by the 206 check; in-memory,
  self-healing after relaunch). Single downloads therefore get true pause/resume + cross-relaunch
  part-based resume. (2) **-3000 hold unified**: any durable progress (8 parts or single part 0) is
  held, never wiped; fg -3003 no longer orphans a live bg task; held items keep the **Live Activity
  alive** ("Progress saved — resumes when you reopen Stashy") instead of ending it mid-background.
  (3) **LA projection clamp** (widget): projected % capped at last real snapshot +8% and never below
  it (fixes "% went down then up"). (4) **`TabBarMinimizer`** (`Features/Player/TabBarVisibility.swift`):
  no public force-minimize API exists, so it registers a hidden non-interactive scroll view via
  `UIViewController.setContentScrollView(_:for:.bottom)` (iOS 15+, the documented "bars observe this
  scroll view" hook) and nudges it downward (animated offset) ~400 ms after push → the system runs its
  own minimize animation. Attached to SceneDetailView + compact DownloadsView. UNVERIFIED on device —
  if the bar still doesn't collapse, this is the component to iterate on (it's harmless when inert).
- **v1.0.305 — background-download audit fixes (the "minimize → stall/crawl → fail to build" report):**
  (1) the transient-network suspend path now registers the SAME `pendingForegroundStops` drain barrier
  as collapseToBackground, and `startConnections` refuses to start any engine mid-drain (a stale
  part-size snapshot poisoned the next range request → -3003 append-guard trips); (2) the -3000/-3003
  background fallback no longer wipes parts — multi items retry ONE fresh bg range then HOLD (paused,
  `resumeOnForeground`) and resume 8-way with zero loss on foreground (retry budgets reset per
  foregrounding); (3) merge failure keeps the durable parts (Retry re-merges instead of re-downloading)
  and emits `dl-merge-fail` (per-part sizes) + `dl-bg-reject` RemoteLog events for residual diagnosis.
  Also: **floating download-status button** (`Features/Downloads/DownloadStatusButton.swift`,
  `.downloadStatusOverlay()` on Scenes/Performers/Settings roots) — ~52 pt glass circle, accent progress
  ring + live % + ×N badge, tap → Downloads tab, hidden when idle, rides the existing 120 ms poll (paused
  during scrolls). **Live Activity expanded-island text no longer clips** (minimumScaleFactor / 2-line
  wrap / edge padding). The app→island collapse morph is SYSTEM-owned; its precondition (activity
  requested at download start) was already met — the perceived failure was the engine stall above.
- **v1.0.304 — VMAF-map provenance in transcode logs** (+ **Companion v0.3.8** — owner must update the
  plugin): the plugin stamps `crf_source` ("map"/"live"/"preset"), `map_res` (the vmaf-map res key
  consumed) and `vmaf_expected` into every served progress write + the terminal result; the app logs
  "Quality: cq N from VMAF map (1080p entry, ≈VMAF 94, target 94) — live analysis skipped" once at
  encode start and tags the finish VMAF line "from map (…)"/"live analysis". Honest across engine
  fallbacks (fallback engine ⇒ "preset"). Old plugin = no fields = no line.
- **v1.0.303 — bottom tab bar everywhere** (owner: the collapsible bottom bar shows on every screen,
  incl. the scene player + downloads-via-scene; it arrives in whatever minimized state the grid left it
  and expands on tap — **no public API exists to force the minimized state**, verified against SwiftUI
  TabBarMinimizeBehavior + UIKit UITabBarController docs). The player's top bar lost its back chevron
  (bar stays weightless with ZERO items; back = edge-swipe / player control). Fullscreen hides the tab
  bar via BOTH the SwiftUI preference and the deterministic UIKit `setTabBarHidden` probe
  (`Features/Player/TabBarVisibility.swift`, responder-chain lookup, restores on dismantle) — the two
  always agree in value, and the imperative call covers the documented portrait-fullscreen
  in-place-toggle failure.
- **v1.0.301→302 — nav bar on the scene player (LANDMINE: this screen’s layout keys off the safe area):**
  goal (owner): the bar stays visible across screens so list⇄scene pops are native item cross-fades (the
  old hide→show pop was jarring; a masking fade was disliked). v1.0.301 naively made the bar visible —
  but a visible bar SHRINKS the SwiftUI safe area, and SceneDetailView derives its whole layout from
  `safeAreaInsets.top`: the 16:9 box slid down by the bar height, the blur bleed grew, the bar drew the
  title over the video (duplicating the metadata header), a suppressed system back button left the bar
  EMPTY, and the inflated inset polluted the player’s inline control padding. **v1.0.302 fix — the bar is
  present but weightless:** the screen `.ignoresSafeArea(.top)` and derives the status-bar strip from the
  WINDOW’s device insets via `WindowMetricsReader` (the fullscreen player’s proven probe; zero for ≤1–2
  frames mid-push) → geometry pixel-identical to the bar-hidden days; `toolbarBackground(.hidden)` + no
  `navigationTitle` (metadata header owns the title); ONE floating mini back chevron (topBarLeading,
  content gated on `!isFullscreen`; system back stays suppressed, edge-swipe alive); player gets
  `windowSafeArea`, not geo’s. Fullscreen still hides the bar — and even if the in-place toggle lags, a
  background-less bar with gated-out content shows nothing. **`DownloadsView(compact:)`** = empty-title
  bar when pushed from a scene (RouteDestination), full “Downloads” title from the tab.
- **v1.0.300 — scene delete options simplified:** the delete dialog no longer offers “remove from Stash
  but keep the file” (**owner standing rule: NEVER delete a scene from Stash while keeping its disk
  file**). Downloaded scene → **“Delete Download from Phone”** (local copy only, scene stays;
  `DownloadManager.deleteDownload(sceneID:)`) + **“Delete from Stash & Disk”** (`deleteScene(deleteFile:
  true)` + also removes any phone copy). Stream-only → just the latter.
- **v1.0.299 — metadata scrape rework (auto multi-source; supersedes the v1.0.298 source-picker flow):**
  “Scrape Metadata” now queries **StashDB / ThePornDB / FansDB in PARALLEL** — no scraper picker (only
  those three are kept; `StashScraper.isAllowed` filters by name/endpoint keyword). **Scenes** merge all
  sources into the edit form with **per-field source chips** where they disagree (title/date/details/
  studio/cover; a “Current” chip preserves the existing value), tags+performers UNION deduped. **Performers**
  (detail scrape + add-performer “+”) show a **merged candidate list** — same person (name+birthdate) across
  sources collapses into one row with source badges, different people stay separate; picking resolves+merges
  full detail across sources (priority StashDB→TPDB→FansDB), unions photos. **Native PhotosPicker “Upload”
  tile** in the performer photo strip (add/manual/edit) → downscaled base64 data URL → saved via
  performerCreate/Update. **Source-unavailable handled** (`MultiSourceResult` separates matches from
  UNREACHABLE sources → “Couldn’t reach FansDB”, never a false “no match”; one source failing never blocks
  the rest). **Instant refresh**: sheets refetch the scene/performer inside the save task and hand it back
  (`onSaved(fresh)`) so detail header/tags/portrait update in place. Details §6.
- **v1.0.298 — metadata scrape/edit suite (FOUNDATION; scene/perf ••• menus + “+” add-performer):**
  `Services/StashScraper.swift` is the one typed gateway; medium-detent glass sheets float OVER the
  playing video. Key GraphQL contracts (verified against Stash source, still current): sources =
  `configuration.stashBoxes` first then capability-filtered `listScrapers`; `ScraperSourceInput` takes
  **exactly ONE** of `scraper_id`/`stash_box_endpoint`; scraped images are **base64 data URLs** passed
  straight into `cover_image`/`image`; update inputs are omit-to-keep and list fields REPLACE; classic
  performer scrapers need a **two-step** query→`performer_input` re-scrape (stash-boxes one-step). Unmatched
  scraped entities = dashed “+” chips. All transient sheets — zero browse/player perf impact. Details §6.
- **v1.0.296 — jobs-panel scan bar FIXED (was broken since the panel shipped):** Stash's `jobQueue` is
  `null` (not `[]`) when EMPTY → the non-optional decode failed every idle poll, freezing the last
  snapshot ("stuck" bar) and silently killing the poll loop after ~60 s. Now: optional decode
  (`StashClient.jobQueue`), refcounted `JobMonitor.attach/detach` (rapid reopen delivers the old panel's
  onDisappear AFTER the new onAppear), a never-self-stopping loop (≥3 fails → clear snapshot, show
  "Can't reach Stash — retrying…", 4 s cadence), inline `actionError`, optimistic "Starting …" line.
  Task buttons shrank to caption2 flow chips under "Library tasks". Details §6.
- **v1.0.284–295 (owner + GPT-5 Codex, 2026-07-20):** library scroll-perf pass v2 — card shadow →
  hairline `cardContour`; `ScenePreview` tracks size only (preview origin from the touch point);
  pagination invisible + earlier (`contentRevision` page prefetch); ImageCache bounded 2-worker
  prefetch queue + RAM-adaptive memory budget; served-map stores decode off-main;
  `BrowseScrollCoordinator` (non-observable `isScrolling`; DownloadManager skips its 120 ms UI progress
  poll while scrolling) + opt-in ntfy frame telemetry (`BrowseScrollPerformanceMonitor`). **Hero zoom
  transitions REMOVED** (plain push/pop; `ZoomReturnScrollGate` deleted — don't re-add zoom without §6).
  **Downloads reworked to an adaptive engine** (foreground 8 range data-tasks appending to durable
  parts ⇄ ONE background range task, no resume-blob handoff) with a staging "Transfer:
  Background | Multi-thread" picker — that series defaulted `multiThread` OFF, **reverted to ON in
  v1.0.297** (owner decision 2026-07-24). Download **Live Activity / Dynamic Island**
  shipped (new `StashyLiveActivity` extension target; 2 s equality-gated sync; ActivityKit failures
  surface on the Downloads screen for sideload-signing diagnosis).
- **Jobs panel shipped (v1.0.280–283)** — Scenes & Performers have a **jobs status dropdown** off the title,
  plus job-queue actions. **The v1.0.282 custom-glass-overlay approach was REVERTED at v1.0.283** after owner
  on-device testing: a custom glass top bar floating over the scrolling grid re-sampled the moving content
  per-frame → **scroll judder** (the CLAUDE.md glass-over-scrolling-list landmine), the full-screen sibling
  ZStacks **missed taps** (leaked to scene cards), it **hid the system nav bar** (lost native collapse), and
  the `glassEffectID` morph "just popped". `GlassMorphDropdown` + `LibrarySearchField` were **deleted**.
  **The shipped design (v2):** keep the **SYSTEM nav bar** — inline title, `.searchable(.minimize)` magnifier
  pinned top-right, funnel + selection actions as toolbar items — so scroll stays buttery (no custom glass over
  the grid), taps are reliable, and the bar collapses natively. The **title is a nav-bar Button** (“Scenes”/
  “Performers” + chevron) toggling the jobs dropdown. Both panels are `DesignSystem/LibraryDropdownPanel`
  (stable ZStack siblings of `content`, exist **only while open** so glass never samples the scroll; anchor
  `.topLeading` jobs / `.topTrailing` filter; open with the system `.snappy` spring +
  `.transition(.scale(anchor:))`; **hit-catcher** `.background(Color…0.0001…onTapGesture{})` behind the
  controls kills the tag-tap-through). `dismissesPopover` (restored) closes a panel AND scrolls in one swipe —
  no modal backdrop, no pause. `Features/Library/JobsPanel` shows the live Stash job (title + bar bound to
  `progress`, idle line, “+N queued”) with a **stop.circle.fill cancel button** → `JobMonitor.cancelRunningJob`
  → `StashClient.stopJob(job_id:)`; Scenes shows Scan Library / Compute VMAF·ThumbHash·Loudness, Performers is
  status-only. `JobMonitor` (@MainActor @Observable) polls `jobQueue` **only while a panel is open**. The old ⋯
  menu folded into `SceneFilterPanel` (`onDownloadAll`/`onSelect`/`bulkLoading`). Lesson: **custom glass must
  never float over a scrolling list** — the system nav bar composites its glass efficiently; custom glass does
  not. **NEXT (owner-queued URGENT): fix AI slow-mo quality degradation** (ROADMAP).
- **ThumbHash blur placeholders shipped (v1.0.272–274 + Companion v0.3.5–0.3.6)** — a card now shows an instant
  tiny blur *before* its real thumbnail loads, so a fast flick never flashes blank cards. Three sources,
  merged (on-device hashes always win): (1) **on-device** — `Services/ThumbHash.swift` (verbatim MIT port
  of evanw/thumbhash; keep its non-idiomatic `while` loops — they dodge Swift's slow type-checker) +
  `Services/ThumbHashStore.swift` (`@MainActor`, **NOT** `@Observable` — cards read `placeholder(for:)`
  imperatively so a hash arriving mid-scroll never invalidates cells; persisted base64 JSON in App Support),
  computed as each thumb loads via `ingest`, keyed by scene id and `"perf-"+id`; (2) **bulk pre-cache** —
  `Services/ThumbnailPrefetcher.swift` (Settings → “Cache All Thumbnails”, sequential = gentle server load,
  cancellable/resumable) walks the whole library to disk-cache thumbs AND build the hash map (ImageCache
  disk cap bumped 200→800 MB so a full pre-cache isn't evicted); (3) **server map** — the Companion plugin’s
  **Compute ThumbHash Map** task writes `cache/thumbhashes.json` (zero scene writes, incremental/resumable,
  budget-capped, prune-only-on-clean-pass), which `ThumbHashStore.refresh(serverURL:apiKey:)` fetches +
  merges (wired in `ScenesView.task` beside Playability/VMAF refresh; mirrors `PlayabilityStore.refresh`).
  The plugin encoder is a pure-stdlib port of `ThumbHash.swift` using `floor(x+0.5)` — **NOT** Python’s
  banker's `round()` — so its bytes decode in-app; covers decoded via one ffmpeg PPM pass. Scene-only
  (performers get on-device hashes only). A **Scene.Create/Destroy hook auto-maintains the map on scan**
  (Companion v0.3.6, gated by `autoThumbhashNewScenes`, independent of the codec-report toggle; ONE hook
  entry per trigger — `run_hook` maintains both served maps, a 2nd entry would double-invoke).
  **Owner step: deploy Companion v0.3.6 + run Compute ThumbHash Map once.**
- **120 Hz scroll-perf pass shipped (v1.0.269)** — browse-grid flick judder fixed: (1) `ScenePreview` was
  writing each cell's `.frame(in:.global)` to `@State` via `onGeometryChange` on EVERY scroll frame,
  re-rendering every visible cell at 120 Hz → now a reference box (`FrameBox`, no invalidation) — the
  dominant cause; (2) `cardElevation` casts its shadow from an opaque backing `RoundedRectangle`, not the
  clipped cell (kills the per-cell offscreen pass); (3) `ImageCache` decodes grid thumbs off-main
  (`byPreparingForDisplay`) before caching. The post-zoom **source-card freeze** is a separate Apple bug
  (FB21961572, see Landmines) masked by `ZoomReturnScrollGate` (600 ms `scrollDisabled` after a pop,
  v1.0.271); `geometryGroup` was tried + reverted. Remove the gate once iOS 27 fixes it (ROADMAP Tech debt).
- **UI/UX overhaul shipped (v1.0.253–265)** — full reference in ENGINEERING_NOTES §6 "UI/UX overhaul".
  In brief: new **`DesignSystem/`** folder — `ThemedBackground` (per-theme **static** `MeshGradient`
  behind all browse screens via `.themedBackground()`, blends toward foreground/primary/accent **never
  black**), `CardStyle` (`CornerRadius` + `cardElevation`), `FilterPill`
  (`filterPill(active:tint:foreground:)`). **Theme.swift rewritten**: 14 distinct palettes (8 dark +
  6 light; synthwave & mocha kept), `meshColors(vibrancy:lift:)`, `MeshTuning` ranges, and **4 Settings
  sliders** (vibrancy + lift, separately for light & dark; defaults 0.50/0.32). **Motion:** hero **zoom**
  grid→detail (`matchedTransitionSource` + `.navigationTransition(.zoom)`) on Scenes & Performers;
  `.tabBarMinimizeBehavior(.onScrollDown)`; `.contentTransition(.numericText())` on the selection count.
  **Filter panel** is Liquid Glass with solid (never-glass) chips; **active chips fill accent** (pink for
  Favorites). **No scrollbars anywhere** (Standing rules). (The `ScenePreview` `GeometryReader` →
  `onGeometryChange` change from this pass later proved to be the 120 Hz judder cause — see the scroll-perf
  bullet above.)
- **Phase-4 consolidation + minimized search shipped (v1.0.266–268)**: (1) DesignSystem now owns the
  repeated styling — `LabeledSegment` (Downloads caption-over-segment helper, was copy-pasted in two
  files), `overlayBadge()` (the translucent media badge ×3), `capsuleField()` (the filter text-field
  capsule), and `SceneFilterBar` chips migrated to the shared `filterPill`. (2) **Search reworked** on
  Scenes & Performers — dropped `.navigationBarDrawer` (it shows the bar at scroll-top; `isPresented`
  only controls focus, never the collapsed chrome) → iOS 26 **`.searchToolbarBehavior(.minimize)`**
  renders search as a tap-to-expand magnifier BUTTON (nothing at scroll-top), pinned top-left via
  **`DefaultToolbarItem(kind: .search, placement: .topBarLeading)`**; custom magnifier removed (system
  provides one). All iOS 26.0+ (deploy target 26.0, no gating). Full detail in ENGINEERING_NOTES §6.
- **VMAF quality-targeted transcodes shipped** (Companion v0.2.0→v0.3.1 + app v1.0.250–252): the plugin
  binary-searches the encoder quality knob on short sample windows to hit a target VMAF (phone model;
  presets are now perceptual targets High 97 / Balanced 94 / Small 91; default ON; needs libvmaf — in the
  BtbN software ffmpeg build, NOT jellyfin-ffmpeg; HDR/DoVi or any measure failure falls back safely to
  the preset CRF). v0.2.2 fixed the `-lavfi` double-escaped-colon bug that silently broke EVERY
  measurement; v0.2.3 parallelized sample windows (~45s→~27s) + `vmafSamples` setting. Result JSON carries
  `cq/vmaf/vmaf_target` → Downloads shows a live **"Analyzing quality — %"** phase (served-file progress;
  the Job.progress clobber is skipped while analyzing or the bar bounces), a **"VMAF NN" chip**, and
  **before→after size + reduction** on finish. **v0.3.0 VMAF CRF map**: "Compute VMAF Map" / "Rebuild VMAF
  Map (full)" tasks pre-compute per-video optimal CRF (+ the measured curve) per resolution into served
  `cache/vmaf-map.json` (kilobytes for the whole library, zero scene writes, incremental + resumable via
  `vmafMapBudgetMin`); `run_transcode` uses the cached CRF and skips the ~30 s live analysis;
  `_crf_from_curve` derives all three presets from the one stored curve.
- **Companion v0.3.1 — the mid-run map FAILURE (~20.7%, GraphQL 401) is FIXED and LIVE-VERIFIED**
  (2026-07-16): job 56 ("Compute VMAF Map") ran clean from ~02:25 to past 05:56 (41.1% progress, scene
  1461, zero 401s in the docker log) — over an hour past the previous ~2h40m death point. Both the cause and the
  damage: (1) **auth** — Stash's session cookie expires during multi-hour jobs, so `main()` now swaps to
  the server's API key at task start (`Stash.adopt_api_key`, fetched while the cookie still works; Cookie
  header dropped; one retry on 401); (2) **data loss** — the finally-block deleted-scene prune ran on ANY
  exception with a partial `seen`, erasing every mapped scene the run hadn't reached and persisting the
  gutted map — now prunes only after a clean full pass (`_prune_missing`); (3) hardening — whole per-scene
  body try-wrapped (INFO log + `failed` count, run continues), malformed entries reset, 30-min per-
  (scene,res) `deadline` in `_vmaf_search` (map task only). Unit tests: `stash-plugin/tests/` (stdlib-only;
  the prune regression test fails on v0.3.0). Full story in ROADMAP §encode-quality.
- **Companion v0.3.2 — settings survive plugin updates**: Stash wipes `plugins.settings.stashy-companion`
  from config.yml on EVERY package update (box-verified; cache/ + bin/ survive), so `_sync_settings` in
  `main()` backs the live map up to `cache/settings-backup.json` every run and auto-restores it via
  `configurePlugin` (whole-map replace) when the map turns up completely empty; a PARTIAL map = user
  intent, never overwritten; restore only fires on a successful settings read. Owner re-enters settings
  once on v0.3.2, then they stick.
- **Scrubbing upgrades shipped this session** (all in `Features/Player/PlayerControlsView.swift` +
  `ZoomablePlayerSurface.swift` + new `Services/ScrubFrameProvider.swift`): (1) **exact-frame preview**
  on downloaded (local) files — `AVAssetImageGenerator` (zero tolerance, `cancelAllCGImageGeneration`
  coalesce-to-latest, capped `maximumSize`), gated to `route.url.isFileURL`; sprite tile is the instant
  placeholder. Release seek was already frame-exact for local (`seekPrecise`). (2) **Variable-speed
  scrubbing** — shared `ScrubSpeed` enum (Hi/Half/Quarter/Fine by vertical finger distance), incremental
  accumulator (never read the `scrubTime` binding back), on BOTH the bar drag and the **video hold-scrub**
  (`ZoomablePlayerSurface.handleLongPress` — changed ONLY the time-math, gestures untouched). `speedTier`
  is a shared `@Binding` owned by `ScenePlayerView`, driving one subtle speed label. See ENGINEERING_NOTES §6.
- **Settings connection is edit-locked** (v1.0.247): a saved server shows greyed read-only URL + masked
  key with a standard header **Edit** button (Cancel discards, Update & Reconnect commits); not-connected
  stays editable for first setup. `isEditing` @State in `SettingsView`.
- **App-switcher privacy blur shipped** (`SnapshotPrivacyModifier` in `Services/AppLock.swift`, outermost
  in `StashyApp`): thick-material cover whenever `scenePhase != .active` so the multitasking snapshot
  never shows media. Deliberately unanimated (cover must be drawn in the snapshotted frame). Settings →
  Privacy toggle, default ON. Independent of Face ID lock and in-app Privacy Mode.
- **Watch-heat shipped** (`Services/WatchHeat.swift`): per-scene 100-bin watched-seconds accumulation
  (host-scoped keys, JSON in App Support, debounced off-main writes), fed from `ScenePlayerModel`'s time
  tick (model now takes `sceneID`; delta window rejects seeks). `ScrubBar` draws the outlier-capped,
  smoothed, normalised curve above the track **only while scrubbing**. Settings → Player: toggle
  (default ON; off = stops tracking too) + Clear data.
- **AI upscaling REVERTED (2026-07-10)** after two shipped iterations (VT zoom-crop v1.0.241, MetalFX
  2×/4× + neural pause-stills v1.0.242–244): owner called it buggy + not visually worth it on 720p
  sources. `UpscaleRunner.swift` deleted; gear toggle/stats/overlay/geometry-provider removed. Pinch-zoom,
  AI slow-mo and the slow-mo Lanczos pass are untouched. **Read ROADMAP §AI-upscaling before any new
  attempt** — full postmortem (960×960 VT input cap, silent green-screen on unqueried scale factors,
  session-rebuild storms on variable crops, frame-tap competition, SwiftUI-overlay-races-pinch) plus the
  researched revival plan: iOS 27 VT query APIs; **Real-ESRGAN Core ML paused-frame enhance** on A19 Pro
  (reuses the proven tiling design); **Snapdragon 8 Elite live NPU SR** (0.96 ms/tile) for the future
  Android app; server P40 Real-ESRGAN as max-quality offline option.
- **Tilt-to-fullscreen made reliable**: `suppressReentry` now re-arms on ANY recognised non-landscape
  orientation (faceUp used to eat the next tilt), and opening the player while already held landscape
  enters fullscreen from `onAppear` (no orientation-change notification fires in that case).
- **AI slow-mo shipped & working** (`Services/SlowMoInterpolator.swift` + `SlowMoRunner.swift` +
  `Features/Player/SlowMoRenderView.swift`): on-device Neural-Engine frame interpolation via `VTFrameProcessor`
  (`VTLowLatencyFrameInterpolation`, iOS 26). While playback ≤0.5× (gated, `aiSlowMoEnabled` off by default),
  a `CADisplayLink` pulls decoded frames from the player's `AVPlayerItemVideoOutput`, synthesises **3 mid
  frames (4×)** per pair, and paces real+synth onto a Metal overlay (`SlowMoRenderView`) via a display-time
  FIFO (single-flight, `latency`=0.15s). **The -19730 saga (see Landmines):** feed the config's required
  **420v** format (not BGRA) AND **cap at 1280×720** (device max the model won't exceed). Confirmed producing
  synthesised frames on-device. Deferred: adaptive frame count per rate; the standalone 0.25×-won't-play bug.
- **Stashy Companion plugin shipped** (`stash-plugin/` — its OWN top-level folder, sibling to `ios/`):
  a stashapp/stash plugin (`interface: raw`, zero-dep Python) that adds what vanilla Stash can't — **GPU
  HEVC (hevc_nvenc, Tesla P40) / CPU AV1 (SVT-AV1) transcode**, ffprobe codec+HDR stats, and a served
  playability report (no scene writes). Delivery mechanism (researched from real Stash source): plugin writes the iPhone-native
  MP4 into its served `cache/` dir (`/plugin/stashy-companion/assets/…`, Range-capable) and records the
  download path on the SOURCE scene's `custom_fields.stashy_transcode`; the app polls `findJob` for real
  `Job.progress`. Encoder ladder: NVDEC+NVENC → CPU-decode+NVENC → libx265. Install = add
  `raw.githubusercontent.com/nphil/stashy/main/stash-plugin/index.yml` as a Plugin Source (zip+sha256
  committed). CI `paths-ignore` now skips `stash-plugin/**` so plugin-only commits don't build the app.
- **App↔plugin foundation shipped** (extensible — more plugin features will hang off this): `Services/
  StashCompanion.swift` = the one typed gateway (`runPluginTask` / `findJob` / `custom_fields`); Downloads
  staging gained a 3rd source **Companion** (HEVC/AV1 + resolution + quality) → new `.serverProcessing`
  DownloadState drives a *determinate* bar from live `Job.progress`, then hands the finished file to the
  normal (Range-capable, multi-connection) byte-download engine. Load-bearing transfer path untouched.
- **Debug logging system shipped** (`Services/RemoteLog.swift` + `Services/DebugOverlay.swift`): ntfy
  server URL + topic are now **configurable** (Settings → Diagnostics; point at a self-hosted Unraid ntfy
  for privacy, default public `ntfy.sh`). `RemoteLog.event(tag, fields)` = compact structured one-liners.
  Transcode/remux/playback paths now stream stage diagnostics (`⚙︎ transcode-in/frame1/out`,
  `⚙︎ remux-header-FAIL/out`, `▶︎ video size=…`) to debug the HEVC-won't-play-native +
  video-disappeared-after-transcode bugs. **App-wide floating camera button** (own passthrough UIWindow,
  excluded from its own shot) → `RemoteLog.uploadImage` PUTs a screenshot as an ntfy attachment; assistant
  fetches the hosted URL (public server only). **ntfy has NO delete API** — "New topic" rotates to a burner
  channel; auto-expiry (public ~12h msgs / ~3h attachments) or short self-hosted retention is the cleanup.
  Still off by default; **kept permanently** (owner decision 2026-07-16 — see Standing rules).
- **M-B shipped**: player gear → custom quality menu forcing Stash HLS at a resolution. The `?resolution=`
  bug is fixed — Stash's HLS URL already carries `resolution=ORIGINAL`, so `serverQualityRoute` now
  *replaces* it (a duplicate param made Stash read the first = ORIGINAL). Enum values LOW/STANDARD/
  STANDARD_HD/FULL_HD/ORIGINAL verified against stashapp/stash source. Quality switch resumes at the exact
  position (client-side seek; `start=` doesn't work on the HLS manifest).
- **M-A (on-device *streaming* transcode playback tier) shipped then was REMOVED** (`c088325`,
  2026-07-05): flaky, seek-by-reinit made scrubbing glitchy, and it pulled the whole original over the
  network to re-encode locally. `FFmpegStreamTranscoder`/`LocalTranscodeStream`/`FFmpegAudioReencoder` are
  **deleted** — don't go looking for them (git history only). The "Apple can't decode at all" bucket
  (VP9/software-AV1/exotic) now routes straight to Stash **server** HLS at any resolution. On-device FFmpeg
  transcode survives in the **Downloads** flow only: `FFmpegTranscoder` (universal single-pass + lossless
  stream-copy fast path) and `FFmpegResumableTranscoder` (checkpointed keyframe-aligned chunks, shipped
  2026-07-04 — deliberately chosen over fragmented-MP4 append; used for long re-encodes) beside the
  AVFoundation `VideoTranscoder` (short native H.264 only). See ENGINEERING_NOTES §4.
- **Player UX this session** (all shipped): intelligent loading donut (per-mode `LoadEstimator` rolling
  average + saturating curve, % inside ring); inline expanding **volume slider** 0–100 (starts muted);
  quality+method **status badges** on one control row; gear moved right; resume-from-position on return
  from performer/link (safe reload, not a live pause — pop-to-root would crash a kept-alive engine);
  transcode box rich live line + **auto-pause/resume on background/foreground**; **keep-screen-awake** on
  Downloads/active work; social-links overlap bug fixed (ScrollView) + unified `SocialLink.list`; performer
  ••• menu vertical.
- **Seek-donut tuning shipped**: a seek-by-reinit re-buffer now fills the loading ring on a **warm per-seek
  estimate + snappy curve** (`LoadEstimator.expectedSeek`/`recordSeek`, `LoadCurveParams.seek`, gated by
  `loadIsSeek` in `ScenePlayerModel`) instead of the slower cold-start estimate — and seek times stop
  polluting the first-load learning. Untouched (load-bearing): the `seekTarget`/`seekHoldUntil` hold that
  pins the scrub thumb where the finger releases — verified the change is bookkeeping-only, no regression.
- **File-aware load estimate shipped**: the loading donut's expected time (load AND seek) now scales by a
  cheap `resolution × bitrate × codec` **weight** (`LoadProfile` in LoadEstimator.swift; `Scene.loadProfile`),
  so a 4K HEVC file and a 720p H.264 file no longer share one estimate. `LoadEstimator` now learns
  seconds-*per-weight* per tier (defaults bumped to `.v2`, old raw samples discarded) and multiplies by the
  current file's weight — threaded via `ScenePlayerModel(loadProfile:)` from `ScenePlayerView`. **Plugin-
  independent**: every input comes free from Stash's scene metadata (the companion plugin gives the *player*
  donut nothing — it's a Downloads-flow tool; its server-transcode download bar is already determinate off
  live `Job.progress`).
- **RESOLVED**: the HEVC-won't-play-native + video-disappeared-after-transcode bug is no longer open (owner
  confirmed). Diagnostics (`⚙︎ transcode-in/frame1/out`, `remux-header-FAIL/out`, `▶︎ video`, `color=HDR-…`)
  stay wired but the hunt is closed.
- **Playability intelligence shipped (served-file, NO scene writes)**: plugin `Library Codec Report`
  (v0.1.18) ffprobes the library → one served `cache/playability.json`; **zero `sceneUpdate`** (the old
  per-scene tag/custom_field writes caused a hundreds-of-Sync-tasks storm — never write per-scene in bulk;
  use served files, like the transcode-progress file). App: `PlayabilityStore` fetches+caches it →
  (1) **smarter routing** (`playbackRoute(pluginNeedsTranscode:)` skips a doomed remux on Apple-undecodable
  4:2:2/4:4:4 HEVC), (2) **playability filter** (`SceneFilterPanel` Any/Direct-play/Needs-transcode, pages
  via `findScenesByIDs`). No scene-card badges (owner). Plugin writes nothing to scenes; the **Remove Stashy
  Tags (cleanup)** task deletes the `Stashy:*` tag definitions left by ≤0.1.17 (tag-definitions only —
  the residual `stashy_probe` custom field is deliberately left as dead data; clearing it would be a
  per-scene write = Sync storm).
- **Playback speed shipped**: Podcasts-style speed pill on the player control row (left of the gear) →
  0.25×–2× menu, **pitch-corrected** audio (`AVPlayerItem.audioTimePitchAlgorithm = .timeDomain`). Rate is
  published via `AVPlayer.defaultRate` + a re-invoked `play()` (applies live, keeps
  `automaticallyWaitsToMinimizeStalling` on, won't force-start while paused). `PlaybackEngine` gained
  `playbackRate` + `slowMute`; the model re-applies both in `makeEngine` so speed survives every engine
  rebuild (seek-reinit / quality / fallback). Persisted **"Mute when slowed"** toggle in the same menu
  (mute vs. pitch-corrected audio below 1×; `slowMute` is a separate output-volume gate so it never
  clobbers the user's volume). Fully-decoupled *normal-speed audio under slow video* stays deferred.
- **Fetch URL → server pipeline shipped (v1.0.359–361 + plugin 0.4.0→0.5.0, 2026-08-09).** Phone
  submits intent; the SERVER carries the bytes. The moving parts and their sharp edges:
  - **Plugin (`run_fetch`)**: yt-dlp zipapp self-bootstraps into the plugin's persistent `cache/`
    (survives plugin updates; "Update Fetch Engine" task refreshes it). Destination = `fetchDir`
    setting, must be INSIDE a Stash library (validated) — default `<first lib>/stashy-fetch`. On
    finish it queues a `metadataScan` of just that folder. URLs yt-dlp refuses fall back to a plain
    streamed HTTP GET. Failed tasks print `{"error": ...}` on stdout so `Job.error` carries the real
    reason. **yt-dlp's `-o` is a TEMPLATE**: literal `%` in the dest dir or a filename hint must be
    doubled on the command line only (filesystem checks use the raw path) or the parser eats it.
  - **Live telemetry**: Stash's job API can't carry bytes/speed, so the plugin writes a served
    `cache/fetch-status.json` (~1 Hz, flock + atomic replace, pruned 7 d/50 entries) keyed by the
    app-generated `fetch_id`; parsed from yt-dlp's `--progress-template` (4 fields, per-field NA
    tolerance). The app merges it over job status in `ServerFetchStore.pollOnce` — job status is
    authoritative for PHASE, the served file for NUMBERS, and a served "done"/"failed" also closes
    the hole where Stash GC'd the finished job.
  - **Pause/resume semantics**: pause = `stopJob`. The plugin process is KILLED by Stash, so the
    yt-dlp child holds `PR_SET_PDEATHSIG` (`_LIBC.prctl`, resolved at module import — an import
    inside `preexec_fn` runs between fork and exec and can deadlock on the import lock) → child dies
    too, the `.part` STAYS. Resume = resubmit the SAME `fetch_id` + URL + headers → yt-dlp continues
    the `.part` byte-exact (a filename hint whose `.part` exists keeps its name; a completed same
    name dedups with `(n)`). Cancel additionally runs the `fetch_delete` task (realpath-jailed to the
    fetch folder). Removing a DONE card passes `entry_only=1` — without it the plugin resolves the
    recorded filename and would delete LIBRARY content.
  - **App (`ServerFetchStore`, "On Server" cards in Downloads)**: @MainActor @Observable singleton,
    persisted in UserDefaults; 1 Hz poll only while Downloads is visible, backoff ×1.7 cap 10 s,
    never self-terminates (house rule). **Every verb re-resolves the item index by id AFTER each
    `await`** — MainActor reentrancy means a cancel tap mid-request shrinks the array and a
    pre-suspension index traps. Queueing = just submit again; Stash's job queue is serial.
  - **Resolver (`LinkResolverView`) for button-gated hosts**: WKWebView (non-persistent store, fixed
    Safari UA shared with the server fetch) + `WKDownloadDelegate`. Capture point =
    `download(_:decideDestinationUsing:)` — `response.url` is the post-redirect signed file URL;
    cookies filtered by domain suffix + Referer + UA are handed to the plugin (`--add-header`);
    `completionHandler(nil)` cancels the local download. Both `decidePolicyFor` decisionHandlers are
    `@escaping @MainActor @Sendable` (SDK-exact — verified via doc-JSON). **Media plays ≠ media
    captured** (v1.0.363; owner: "the video starts playing on the browser window"):
    `canShowMIMEType` is TRUE for `video/*` and HLS, so the response policy needs an explicit
    main-frame media-MIME check that routes them `.download` instead of letting the inline player
    eat them (main-frame ONLY, or ad-iframe autoplay teasers fire it). **Streaming-only sites**: a
    document-start user script in every frame (page world — it must hook the PAGE's `fetch`/XHR +
    poll `<video>.currentSrc`) reports `.m3u8/.mpd/.mp4…` URLs through a `WKScriptMessageHandler`
    (a WEAK relay object, never the coordinator — the content controller retains its handler
    strongly and a shared popup configuration would cycle); the bottom-bar **Send Stream / Send
    Page** button ships the best sniffed URL (newest MANIFEST preferred; filename hint only for
    direct files — naming an HLS output `master.m3u8` would be wrong) or, with nothing sniffed, the
    page URL for server-side yt-dlp extraction. Sniffed URLs clear on main-frame `didCommit`.
    Plugin 0.5.1 guards the paired trap: `_plain_fetch` refuses `text/html` responses (a page
    yt-dlp can't extract must FAIL on the card, not scan junk HTML into the library as a "video").
    **403 on a fresh tokenized manifest ≠ dead token** (owner hit it on a `master.m3u8?token=`
    seconds old): the page's player fetches via CORS, so token-gated stream backends validate
    `Origin` — the app now replays it (v1.0.364). Cookies ride a REAL Netscape jar since plugin
    0.5.2: the app adds an `X-Stashy-Cookie-Jar` header (structured JSON with each cookie's own
    domain/path) that `run_fetch` pops into a tempfile'd `--cookies` jar (NEVER under `cache/` —
    that dir is HTTP-served) and deletes when yt-dlp exits; the flattened `Cookie` header stays
    for the plain-HTTP fallback and is dropped from the yt-dlp command when the jar exists. Jar
    lines with tab/newline in any field are dropped (line-forgery). If a stream STILL 403s with
    Origin + jar: the token is IP-bound (retest with phone on the same egress as the server) or
    the host TLS-fingerprints clients (would need yt-dlp `--impersonate` + curl_cffi — not
    bundled in the zipapp; a deliberate non-feature until a real site demands it). **Popups NEVER touch the
    visible page** (v1.0.362; the v1.0.361 version loaded them into the main view and ad popups
    hijacked it with no way back — owner report): WKUIDelegate `createWebViewWith` returns an
    OFFSCREEN web view (MUST use the provided configuration — also what shares the cookie store)
    wired to the same delegates, so a file-serving popup is captured while an ad renders to nowhere;
    capped at 4, evicted ones stopLoading, `webViewDidClose` prunes. Same-tab redirects are escaped
    via real back/forward toolbar arrows (`ResolverPageState`, synced in the nav-delegate callbacks —
    deliberately NOT KVO: `canGoBack` is a MainActor-isolated property, and a key path to it in
    `observe()` is strict-concurrency quicksand). Non-web schemes (itms-apps, market:// …) are
    refused in the action policy. IP-signed URLs work where phone and server share egress (home
    wifi); away they fail visibly on the card. Known gap, deliberate: a popup that itself needs a
    HUMAN interaction (second button/captcha INSIDE the popup) dead-ends invisibly — iterate only
    if the owner actually hits one.
  - **DRM is a hard wall, by design** (plugin 0.5.3): once Origin+cookies get yt-dlp PAST the 403,
    some hosts return a SAMPLE-AES / FairPlay / Widevine manifest and yt-dlp reports "This format
    is DRM protected". The bytes are encrypted with a key only a licensed player obtains — no
    header/cookie/format tweak downloads them, and the plugin does NOT attempt a bypass
    (`_is_drm_error` just surfaces an honest card message). Not a bug to reopen; DRM-protected
    streams are out of scope. The resolver still works on the many hosts that serve clear HLS/MP4.
  - **Resolver chrome is deliberately minimal** (owner 2026-08-09: "treat it as a real browser,
    immersive fullscreen"): the top instruction banner was removed — `‹ › + Send + reload` in one
    thin `.bottomBar` group over a full-height WKWebView is the whole UI.
  - **The submit sheet is one field + one morphing button** (v1.0.367, owner 2026-08-10: "it's not
    good UX… get rid of the instructions"). No footers, no prose, no em dashes in any visible string —
    the BUTTON is the instruction. `Services/LinkProbe.swift` classifies the pasted link and the action
    follows: `.direct` → **Fetch on Server**, anything else → **Open in Browser** (the resolver, whose
    Send button still ships a page URL for yt-dlp). Rules that make it robust:
    - **Headers decide, never the extension.** A `.mp4` that 302s onto a login wall serves `text/html`,
      and submitting it scans junk HTML into the library (the exact trap plugin 0.5.1 guards
      server-side). Verdict order: markup → `video/*`/`audio/*`/manifest → `text/*` (only `.m3u8`/`.mpd`
      survive as streams) → attachment/octet-stream (unless the suggested NAME is markup) → empty type
      falls back to the extension → **everything else is `.page`**. `.page` is the safe default: a
      wrong `.page` costs one browser tap, a wrong `.direct` costs a junk file in the library.
    - **Never read a body.** `URLSession.bytes(for:)` returns at the HEADERS, then `stream.task.cancel()`
      — `data(for:)` would buffer the response, i.e. download the movie to decide whether to download it.
      HEAD first, one ranged-GET retry ONLY when the host answered with a status (many 403/405 HEAD);
      no answer at all is not retried, or the sheet sits on "Checking" for two 5 s timeouts.
    - Probe runs from `.task(id: url)` (300 ms leading sleep debounces typing; task cancellation drops
      stale verdicts). Redirects are followed, so `http.url` — not the typed URL — supplies the name.
    - A verdict can still be wrong for the RIGHT reason (per-IP signed link, one-shot token), so the
      primary button carries a `.contextMenu` with the opposite action. Deliberately invisible: it's an
      escape hatch, not a second affordance competing with the button.
  - **Packaging rule bites here**: `stash-plugin/**` pushes don't trigger CI, but the zip is FLAT
    (yml + py at zip root) and `index.yml`'s sha256 must match byte-for-byte — rebuild both together
    (`cd stashy-companion && zip -X ../stashy-companion.zip stashy-companion.yml stashy_companion.py`).

## 9. XR glasses (Viture Pro) — external-display mode, remote, and the hosting rules

Device-proven pipe (2026-08-03, v1.0.348): `glasses-connect bounds=1920×1080 scale=1.0 maxfps=60
overscan=zero`. DP alt-mode is 60 Hz — design all glasses animation for 60, not ProMotion.

### The pipe (three builds of pain — do not re-derive)
- An external-display scene requires **BOTH** `UIApplicationSupportsMultipleScenes: true` **AND** a
  **STATIC** `UISceneConfigurations` entry for `UIWindowSceneSessionRoleExternalDisplayNonInteractive`
  (delegate module-qualified via `$(PRODUCT_MODULE_NAME).ExternalSceneDelegate`). The flag alone was
  device-verified insufficient (iOS 26.6); `configurationForConnecting` is **NEVER consulted** for the
  external role even when everything works — iOS reads the static manifest only (CarPlay-style).
  Without both keys you get silent system mirroring and zero `glasses-*` log lines.
- iOS 27 moves discovery to `UISceneAccessory` — availability-gate a migration then.
- Video on glasses = a **second `AVPlayerLayer` on the same `AVPlayer`** (`externalRenderView`).
  Never reparent the phone's layer; never rebuild the player for a route change.

### Ownership model (v1.0.349+, "glasses-first")
- Plug in → `GlassesTakeoverDriver` (observation-driven, `initial: true`) presents a **takeover
  WINDOW** (`.normal + 1`, no makeKey, filters `.windowApplication`) over the whole app tree — nav
  state survives unplug. Phone shows `RemoteRootView` (the eyes-free remote); glasses show
  `GlassesScreenRoot` (10-foot home + playback).
- `GlassesCoordinator` (singleton, `@MainActor @Observable`) owns glasses-first playback: builds
  `ScenePlayerModel` via `PlaybackRouteResolver`, sets `glassesActive = true`, restores the persisted
  `glassesVolume` (owner decision; models start muted by design — that rule is the PHONE's).
- The v1 per-player routing in `ScenePlayerView` (opacity-hide + syncGlassesRouting) still exists,
  reachable only after EXIT — deliberate interim; retire once the coordinator path is trusted.

### THE hosting rule — a UIView has ONE superview (v2 lesson, two real bugs)
The AI slow-mo runner's `renderView` is ONE view that either the phone's zoom surface or the glasses
container may host, never both:
- `ScenePlayerModel.overlayActive`/`overlayRenderView` are the **PHONE-side contract only** and read
  `slowMoActive && !glassesActive` — without the gate, the hidden v1-EXIT phone surface silently
  **steals** the view off the glasses container (last `addSubview` wins).
- The glasses receive the view explicitly via `GlassesSession.setOverlay(view)`, hosted INSIDE
  `videoContainer` so pinch-zoom transforms video + interpolated frames together; `setVideo`
  deliberately preserves the overlay subview (`where sub !== overlayView`, video at index 0).
- Teardown paths call `setOverlay(nil)` **UNCONDITIONALLY**: a `didSet` observer runs AFTER the
  property flipped, so `if glassesActive { setOverlay(nil) }` inside the glassesActive→false
  transition never fires and strands a frozen interpolated frame on the glasses forever. Clearing is
  a no-op with no scene attached — gate the SET, never the CLEAR.
- Flipping `glassesActive` does `suspendSlowMo(); scheduleSlowMoReengage()` — the runner is REBUILT
  for the new hosting side, not migrated.

### Remote (phone) — gesture vocabulary + feel
- All UIKit recognizers on one clear view (`RemoteTouchSurface`); browse focus steps 52 pt horizontal
  / 70 pt vertical (72/90 device-tested "a bit slow"); flick = one step; dominant-axis lock at 12 pt
  holds for the whole gesture.
- Playback: horizontal drag scrubs (tiered rate by vertical distance, commit on lift); vertical drag
  = **speed ladder** (±1 rung per 80 pt over [0.25, 0.5, 1, 1.5, 2], up = faster); long-press = 2×
  hold; single tap play/pause; double-tap = ±10 s by tap half; two-finger tap = mute. **Volume is the
  phone's hardware buttons** (owner: gesture freed for the ladder).
- Pinch = zoom 1–4× (absolute scale vs `pinchBase` captured at gesture start); while zoomed,
  one-finger drags PAN 2D (×3 pt→px mapping) and double-tap resets (Photos parity). **Pan↔pinch must
  be delegate-paired for simultaneous recognition** — default UIKit exclusion starves the pinch
  whenever one finger moves ~10 pt first. Reset `pinchBase` on `remoteLocked` flips (a mid-pinch lock
  skips the ended-reset → stale base → zoom jump).
- Haptics vocabulary (`Services/Haptics.swift`): `selectionTick` (rate-limited picker tick — scrub
  cues), `step` (rigid detent — focus/rung steps), `tap` (medium/light press), `notify`
  (mode boundaries: lock, exit, play commit). Scrub ticks fire per **sprite cue crossed** (matches
  the preview frame the wearer sees), 10 s buckets before sprites load.
- Status card: 78×44 poster + title (BOTH gated on `Privacy.isOn` — the remote is the shoulder-surfable
  surface), progress bar + times while playing, "rail · n of m" while browsing.

### Glasses UI (10-foot)
- 1920×1080 at scale 1.0 → **pt == px**. No glass/materials on black (nothing to refract — documented
  landmine); white caps at **0.92, never pure** (birdbath optic blooms); text ≥ medium weight; pure
  black idle screens (micro-OLED pixels off). Springs: `response 0.32, damping 0.86`;
  opacity/transform-only animation at 60 Hz.
- Wall: fixed focus slot, content slides (Apple TV model). Rails in FIXED order **Recently Played
  (UserDefaults `glassesPlayHistory`, capped 20) → Recently Added (`created_at desc` — a stable shelf,
  deliberately not the phone's browse sort) → Downloaded** (offline shelf, paints instantly from
  disk). `upsertRail` restores focus by rail **IDENTITY** — a server rail landing above the browsed
  one must not shift focus by position. Server fetch retries forever (jobs-panel rule) with backoff.
- **Poster parity rule:** every surface (glasses wall, phone grid, remote card) renders the SERVER
  screenshot first, download-time local frame grab as offline fallback ONLY — local-first on one
  surface made downloaded scenes look like different videos across screens.
- Focus treatment (device-iterated): scale 1.18 + lift −10 + 5 pt ring + white shadow; unfocused
  cards 0.45, unfocused rails 0.30 (1.08 read ambiguous at cinema distance).
- Playback OSD answers every remote gesture where the eyes are: paused card, ±10 s badges, scrub
  strip (sprite preview thumb 416×234 above timecode/delta/tier + 1152×8 bar), transient speed pill
  (truthful `playbackRate`, AI badge when the runner is live), persistent top-right mode chips (zoom
  scale; non-1× rate) — dim status, not chrome; nothing rendered in the normal case.
- `GlassesScreenRoot` renders BLACK while `mode == .playing` — an `AVPlayerLayer` shows nothing until
  first decoded frame, and the home UI bleeding through a buffering start looked broken.
- Posters/playback on glasses are deliberately **UNBLURRED under Privacy Mode** (optical path is
  wearer-only; that privacy IS the feature). Blackout cover gates on `appActive &&
  !AppLockState.isLocked` (didBecomeActive fires when the Face ID prompt APPEARS, not on success).

### Standing glasses rules
- **No `beginBackgroundTask` and no audio-session writes anywhere in glasses code** — either pins the
  ~26 s background window open and kills DownloadKeepAlive's renewal.
- `ScreenAwake` arbiters the idle timer by reason-set (locking the phone kills DP output).
- Any scene enumeration must filter `.windowApplication` (the external scene is not one —
  OrientationController/DebugOverlay do this).
- Known gaps, deliberate: end-of-video countdown card not built (didReachEnd currently returns to
  browse); v1 EXIT routing retained; `screen-notify` diagnostic answered its question, removable.

### v3 owner-feedback pass (2026-08-04) — the remote's settled shape
- **The analog joystick was built, shipped, and REMOVED same-day** (owner: "not very intuitive").
  `RemoteJoystick.swift`, `JoystickMapping.swift`, `StickHaptics.swift` and their Settings toggles
  live in git history around v1.0.357 — recover, don't rewrite, and don't re-add without being asked.
  The CoreHaptics research stands if ever needed: nil-session `CHHapticEngine()` +
  `playsHapticsOnly = true` BEFORE `start()` is the audio-session-safe construction; a continuous
  event caps at 30 s (loop a short pattern on an advanced player); engine handlers fire OFF-main
  (`Task { @MainActor }`, never `assumeIsolated` — it traps).
- **Volume on the glasses = the HARDWARE buttons, nothing else.** The glasses player's model gain is
  pinned at 1.0. The original design (persisted 40% model volume) multiplied UNDER system volume, so
  with system volume near max the buttons changed nothing audible — "volume doesn't work". The pill
  on the glasses is driven by a READ-ONLY KVO observation of `AVAudioSession.outputVolume`
  (armed on sessionBegan, invalidated on sessionEnded; fires only while the session is active, which
  playback guarantees). The no-audio-session-WRITES rule stands — reads are fine.
- **Every OSD pill/badge is transient (~1 s) and the expiry lives in the COORDINATOR**, one
  cancellable task per pill re-armed on each change. The in-view `.task + .id(pulse)` pattern is a
  TRAP: `try? await Task.sleep` swallows the CancellationError, so the cancelled (re-keyed) task
  falls through and clears the pulse anyway. Nothing may render persistently over the video (the
  old always-on zoom/rate mode chips are deleted). Also applies to the skip badge.
- **Finger trail:** `GestureTrailView` (the touch surface's host view) drops a fading radial-gradient
  CALayer per touch sample (6 pt spacing gate, ~0.45 s fade, self-removing). Raw `touches*`
  overrides coexist with the recognizers because every recognizer sets
  `cancelsTouchesInView = false` — without that, the trail dies 12 pt into every drag when the pan
  recognises. Zero SwiftUI involvement, so zero re-render cost.
- **A pinch landing mid-scrub must ABORT the scrub** (`scrubTarget = nil`, no seek) — once
  `isZoomed` flips, the pan handler returns before delivering `ended: true`, which would pin the
  scrub strip over the video and commit a stale seek on the next drag.
