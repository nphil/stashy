# Stashy — Performance & Stability Review (2026-07-01)

31 findings, each surfaced by a subsystem reviewer and then **adversarially verified** against the code
by a second agent (31 confirmed, 3 refuted, 0 uncertain). Static analysis only — the app can't be
profiled locally, so magnitudes are estimates but every mechanism is line-verified. Severities below are
the *verifier-corrected* values.

**How to use this doc:** each item has file:line, the mechanism, the fix recipe, and the trade-off/gotcha
that matters. Implement straight from here — no re-analysis needed. Items are grouped by the implementation
phase in the plan. **Read `docs/ENGINEERING_NOTES.md` for the touched subsystem before editing**, keep
commits small and single-purpose, and verify each non-`.md` push produces a new release with a changed IPA
byte size.

Legend: **[H]** high, **[M]** medium, **[L]** low. "SACRED" = the fix touches the load-bearing foreground
8-way download path or basic playback → verify on device.

---

## Phase 1 — concurrency-interleaving trio (highest care)

> **Status (shipped v1.0.108–110):** #1 and #2 done. #3 parts (a) temp-sweep-detached and
> (c) migration one-shot flag done; part (b) — moving `loadCompleted`'s per-item sidecar decode off-main —
> **deferred to Phase 3** because a race-free version needs `DownloadItem.title`/`scene`/`apiKey` to become
> `var` (a model change best designed alongside the ImageCache work in cluster A).

### 1. [H] Handoff race double-starts engines, can delete a completed file
`Services/DownloadManager.swift:596`
`handoff()` clears `tasks[item.id]=[]` then its empty-active fast path starts immediately; meanwhile the
pending `cancel(byProducingResumeData:)` completions (8 of them) each decrement `pendingHandoff` and at 0
start *again* with no check a start already happened. A quick bg→fg flip before the resume-data callbacks
land → engine #1 (fast path) + engine #2 (completion) = 16 live tasks on the same 8 part files; duplicate
`connectionFinished` re-enters `finalizeIfComplete`, and `merge()`'s opening `try? fm.removeItem(dest)` can
unlink a just-completed file. The reverse (fg→bg mid-cancel) starts two parallel bg range tasks = the -3000
pattern.
**Fix:** Guard #1 — early-return in `handoff()` when `pendingHandoff[item.id] != nil` (the pending
completion already honors the current phase). Guard #2 — in that completion's start branch, require
`(tasks[item.id] ?? []).isEmpty` before starting. Optional #3 — defensive cancel of stragglers in
`startConnections`/`startBackgroundConnection`.
**Trade-off:** Normal single-flip path (pendingHandoff nil) stays byte-identical; guards only trip on a
2nd flip mid-cancel. Lives inside the sacred handoff → device-verify both flip directions + cold relaunch.

### 2. [H] Cold foreground relaunch strands a background download
`Services/DownloadManager.swift:710`
`connectionFinished`'s chain-next-part is gated on `inBackground`. After a jetsam + icon relaunch,
`inBackground` inits to false and `attach()` reattaches the lone bg task as `.downloading`; when it
finishes, not-all-8-done + `inBackground==false` + empty `tasks` → nothing starts. Download runs at 1/8
speed then freezes forever at a partial %, recoverable only by manual pause/resume.
**Fix:** After `attach()` groups reattached tasks, normalize each item to the current phase via the
existing `handoff(item, toBackground: inBackground)`. Reuses battle-tested machinery — do NOT touch the
8-way engine internals or invent stall-detection.
**Gotcha:** the "check tasks[id] for no live tasks" alternative is harder than it looks — `tasks[id]` is
never cleared per-task, only wholesale-reset, so a dead-but-referenced task defeats a naive `.isEmpty`.
Use the `handoff()` route. Also: give attach()'s handoff its own `beginBackgroundTask` assertion (the
cancel/restart is async and could be cut off by suspension on the bg-launch-for-events variant).
`willEnterForegroundNotification` does NOT fire on cold launch, so no double-handoff race with #1.

### 3. [M, SACRED] Cold-launch path does synchronous library-scaling disk IO on the main thread
`Services/DownloadManager.swift:288` (+ `StashyApp.swift:11`, `Services/OrientationLock.swift:14`)
`DownloadManager.init` (evaluated synchronously in a `@State` initializer before first frame) runs
`loadCompleted()` (dir listing + full-`StashScene` JSON decode + `fileExists` per completed item) and
`loadInterrupted()` (JSON decode + 8× stat + 8× resume-blob read per active item), plus
`sweepStaleTempFiles()` and audio-session IPC in `didFinishLaunching`. Cost grows linearly with the
downloads library → ~50–250 ms added launch, paid again on every cold background relaunch.
**Fix (staged, cheapest→riskiest):**
- (a) `sweepStaleTempFiles()` → `Task.detached(priority: .utility)` — it's `nonisolated static`, touches
  only tmp; near-zero risk.
- (c) one-shot `UserDefaults` flag to skip `migrateLegacyStore` after first success.
- (b) move `loadCompleted`'s disk IO/JSON decode off-main, hop back to MainActor to build `DownloadItem`s.
  **Scope this to `loadCompleted` FIRST** (no ordering dependency) — it carries most of the win.
**Critical ordering constraint (verified):** `finalizeReadyItems()` reads `finished[item.id]` populated by
`loadInterrupted()`'s per-connection loop; `reconnectTasks`→`attach()` hard-cancels any task whose item
isn't yet in `items`. A naive concurrent restructure of `loadInterrupted` could cancel a live
continuation task on the sacred path. Preserve `loadInterrupted → finalizeReadyItems → reconnectTasks`
ordering; do NOT make `loadInterrupted` fire-and-forget. Transient empty-`items` window at launch is a
harmless UX flicker (no new `DownloadState` case needed). Cheaper fallback if the async restructure feels
risky: batch `loadInterrupted`'s 8 per-connection `resourceValues` calls into one directory listing like
`loadCompleted` already does.

---

## Phase 2 — mechanical fixes (verified recipes, CI is the compile gate)

> **Status (shipped v1.0.112–114):** #4–#12 and #14 done. #13 (delete ScenePreviewGesture's redundant
> thumbnail `.task`) **folded into Phase 3 cluster A** — its main cost is the duplicate network fetch that
> #15's ImageCache coalescing removes at the source, and both touch ImageCache, so they land together
> (edit ImageCache once). #12 shipped its primary half (cancel-on-dismiss); the in-flight download dedup is
> deferred to cluster A too (it conflicts with clean caller-cancellation without awaiter ref-counting).

### 4. [H] beginBackgroundTask without expiration handlers → ~30s watchdog kill mid-transcode
`Services/DownloadManager.swift:405` (and merge at `:667`)
Both `beginBackgroundTask` sites pass a nil expiration handler; iOS terminates the app when the ~30s grace
expires. A transcode runs minutes; a multi-GB merge can exceed 30s. Kill orphans the transcode temp
(→ ghost item, #23) and can leave a partial merged dest that `loadCompleted` resurrects as "completed".
**Fix:** transcode handler → `{ transcoders[id]?.cancel(); UIApplication.shared.endBackgroundTask(bg) }`;
merge handler → `{ UIApplication.shared.endBackgroundTask(bg) }`.
**Gotcha:** an expiration handler is only the last-seconds notice, not extra time; `cancel()` sets a flag
checked async in the pump, so this is "very likely graceful abort," not a hard guarantee. Still a strict
improvement over guaranteed kill. (dl-handoff assertion at `:570` is already safe — self-ends via 15s timer.)

### 5. [M] transcodeFinished deletes the original before the replacing move succeeds
`Services/DownloadManager.swift:440`
`try? fm.removeItem(at: src)` + `try? fm.removeItem(at: finalURL)` run BEFORE `try fm.moveItem`. A rare move
failure leaves `.completed` with a dangling `localURL` (offline copy gone, transcoded bytes stranded → ghost).
**Fix:** `try fm.replaceItemAt(finalURL, withItemAt: output)` (atomic, handles the `src == finalURL` case —
delete the manual conditional at `:441`). Also set `item.state = .failed`/invalidate `localURL` in the catch
if src can't be recovered.

### 6. [M] Transcode progress reported per video frame → hundreds of MainActor Tasks/sec
`Services/VideoTranscoder.swift:197`
pump() calls `onProgress` per video sample (100–500+/sec at HW transcode speed); each spawns
`Task { @MainActor in item.transcodeProgress = p }` + an animated `DownloadCard` re-render.
**Fix:** local vars on the serial pump queue (no lock needed — single writer); invoke `onProgress` only when
Δprogress ≥ 0.005 or ≥100 ms elapsed. Video pump only (audio pump already passes `onProgress: nil`).
`transcodeFinished` force-sets progress=1 on success, so a swallowed final frame is harmless.

### 7. [M] Remux file-write failure swallowed with try? while bytesWritten advances
`Services/FFmpegRemuxer.swift:419`
`try? fileHandle.write(...)` discards the error then advances `bytesWritten` and returns count — FFmpeg is
told every byte landed. Disk-full mid-remux → player frozen on an endless spinner AND the remux keeps
pulling GBs over the network into a failed handle for the rest of the file.
**Fix:** `do { try fileHandle.write(contentsOf:) } catch { return -28 }` (AVERROR(ENOSPC)); advance
`bytesWritten` only on success. This fails `av_interleaved_write_frame` → loop breaks → `finishedFlag` set →
`FMP4Index` emits ENDLIST at the last good fragment (video ends cleanly instead of spinning; also stops the
runaway network pull for free). Nicer UX (auto-`fallbackToHLS`) needs a new remuxer→model error signal — a
larger follow-up, not required here.

### 8. [M] Loopback server binds all interfaces, not 127.0.0.1
`Services/LoopbackServer.swift:41`
`NWListener(using: .tcp)` with no endpoint restriction binds the wildcard address despite the doc claiming
127.0.0.1. Any LAN peer can port-scan and download the currently-playing media (bypasses the app's privacy
posture). `serveMedia` serves arbitrary ranges with zero auth.
**Fix:** `let p = NWParameters.tcp; p.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback),
port: .any); NWListener(using: p)`. AVPlayer already uses the hardcoded `http://127.0.0.1:<port>/` URL
(`start()` line 60), so restricting the bind can't change what AVPlayer connects to. Drop the reviewer's
`conn.endpoint` fallback — unnecessary. Device-verify AVPlayer still connects (SACRED-adjacent: remux path).

### 9. [M] fallbackToHLS racing stop() resurrects an auto-playing engine → crash
`Features/Player/ScenePlayerModel.swift:273`
`fallbackToHLS` is the only engine-creating path with no `stopped` guard. If the item fails as the user backs
out, an enqueued `onFailed` Task runs after `stop()`, creates a fresh AVPlayer (`init` ends with `play()` +
registers a periodic time observer), never torn down → dealloc trap crash + background audio.
**Fix:** `guard !stopped else { return }` at the top of `fallbackToHLS` (mirrors buildLinear/reinitLocal).
One line, only trips post-stop, zero happy-path change.

### 10. [M] Playback failure on routes without a fallback URL is swallowed → infinite spinner
`Features/Player/ScenePlayerModel.swift:256`
`fallbackToHLS` starts `guard !didFallback, let fallback = route.fallbackURL else { return }`. `fallbackURL`
is nil for H.264 direct-play, server-HLS, last-resort, and downloaded-local routes — so a `.failed` item does
nothing: `lastError` never set, spinner spins forever, Stats overlay shows no error.
**Fix:** else-branch on that guard: set `lastError = error`, `isBuffering = false`, terminal
`loadingStage = "Playback failed"`, and a `didFail` flag the view renders as an error card.
**Design decisions:** default to a manual retry button, NOT an auto-retry timer (auto-retry against a down
server/corrupt download is a new landmine); the `didFail` flag needs an explicit unset on retry (mirror the
`stopped`/`startInProgress` reset) or you only buy one extra attempt. Owner is exacting about UI feel — the
error card deserves a polish pass. Don't couple new error text to the `RemoteLog` call at :259 (slated for deletion).

### 11. [M] Cancelled search task wipes the newer search's results/spinner
`Features/Library/SearchView.swift:30`
After the `async let` awaits, the cancelled task unconditionally writes empty arrays + `isSearching = false`
into shared `@Observable` state (no post-await cancellation check). Typing flashes "No Results" between
keystrokes.
**Fix:** `guard !Task.isCancelled else { return }` before assigning any state AND again before
`isSearching = false` (a stale task that already set `isSearching = true` must not clear the new spinner).
Bare cancellation check is sufficient here (`search()` always cancels the prior task); a generation token is
belt-and-suspenders consistency with PaginatedLoader.

### 12. [M] Preview clips neither cancelled on dismissal nor deduplicated in flight
`Features/Library/ScenePreview.swift:225` (+ `Services/PreviewCache.swift`)
`ScenePreviewContainer.loadPlayer` starts an unstored `Task` that downloads the *entire* clip via
`session.download(from:)`; `onDisappear` only calls `model?.stop()`. Long-press→swipe still finishes the
download; re-pressing doubles it (no in-flight tracking).
**Fix:** hold the load in `@State loadTask: Task<Void, Never>?`, cancel in `onDisappear`. Add a per-*filename*
in-flight `[String: Task<URL?, Never>]` to the PreviewCache actor — key on `filename(for:)` (content-hash,
apikey-stripped, already exists), not the raw URL, so a rotated apiKey still coalesces.
**Isolation:** PreviewCache owns its own `URLSession`, fully disjoint from DownloadManager — cannot touch the
sacred paths. Optional: 1–2s dismiss grace before cancelling if repress-within-seconds proves common.

### 13. [M] Every scene cell loads its thumbnail twice
`Features/Library/ScenePreview.swift:106` (+ ScenesView:285, SearchView:150)
`SceneCard` loads the thumbnail in `.task(id: scene.id)` AND the `.scenePreview` modifier's
`ScenePreviewGesture` loads the identical URL in its own `.task` (used only as the preview poster). Both fire
same-frame; on cold cache = 2× network + decode + disk write per cell (gesture's copy loads even when
`animatedPreviews` is off).
**Fix (prefer the low-touch option):** delete `ScenePreviewGesture`'s `.task` entirely; resolve the poster at
long-press time via a synchronous memory-cache-only accessor on ImageCache (popup already falls back to
black). Avoids the view-hierarchy restructuring the "pass image down" option requires. Changes only
ScenePreview.swift. (Item 15's coalescing also neutralizes the network cost, but delete the redundant task
regardless.)

### 14. [M] RemoteLog memory-warning handler blocks main thread; enable() stacks duplicate observers
`Services/RemoteLog.swift:142`
`observeMemoryWarning()` registers with `queue: nil` → handler runs on the MAIN thread and does
`flushSync(timeout:1)` (blocking HTTPS POST). `observeMemoryWarning()`/`installExceptionHandler()` run on
EVERY `enable()` (launch + 2 UI toggles), so N toggles = N never-removed observers → N× sequential 1s stalls
on a memory warning. Debug-only (off by default) but that's exactly when the owner debugs 4K playback.
**Fix:** synchronous `hasInstalledHooks` flag checked in `enable()` BEFORE the `queue.async` dispatch (avoids
the async-registration timing wrinkle of moving the calls inside the closure). Memory-warning flush →
`queue.async { self.flushLocked() }` (disk tail at :93 already covers hard-kill). Keep the blocking flush
only in the uncaught-exception handler.

---

## Phase 3 — load-bearing or design-decision fixes

> **Status (shipped v1.0.115):** #16 (decoded costing + 128MB budget), #17 (low-water eviction), #L1
> (diskBytes resync), #18 Tier 1 (LibraryEdits ordering token) done. **Remaining, grouped by why:**
> — *Subtle, needs a careful session:* ~~#15 (ImageCache in-flight coalescing — the awaiter-cancellation
>   shield is the trap)~~ **DONE (commit `3fb8ddd`, v1.0.118):** actor-local `inFlight` registry;
>   `image(for:)`/`originalImage(for:)` join an in-flight fetch or start one, body moved to
>   `fetchDownsampled`/`fetchOriginal`; shared unstructured Task shields against one awaiter's cancellation;
>   registry cleared on success AND failure (identity-guarded); also kills the #L1 double-count at source.
>   Remaining in cluster: #13 (nonisolated memory-peek accessor + delete ScenePreviewGesture's `.task`) +
>   #12 download-dedup. #18 Tier 2 (server-side coalescing).
> — *Sacred batch:* **#20/#21/#22 DONE (commits `c7b3dd7`/`f6b0c7f`/`7f4ee67`, awaiting owner device
>   test):** #20 catchable `write(contentsOf:)` + non-optional read + size-verify before success; #21 read
>   callback retries a transport error (EOF only on a clean empty response) → EIO not fake-EOF; #22
>   `teardown()` nulls `hostView.player` + removes host/backdrop + `LiveBlurBackdropView.invalidate()`.
>   **#25 REVERTED (commit `a65d932` → revert `0427952`): it regressed HEVC playback** — remux stuck →
>   Stash-transcode fallback. `sendHeaderThenBody`'s non-final header (`isComplete: false`) + nested-
>   completion send stalled segment delivery to AVPlayer, exactly the truncate/stall the finding warned
>   about. Left as-is (low value — existing 15s-buffer / 75s-pace bounds already cap the double-buffer
>   spike). Only revisit with real device testing (e.g. `NWConnection.batch{}` around two `.contentProcessed`
>   sends, or chunk the body from the FileHandle) — do NOT re-apply the isComplete:false-header shape.
>   Device-verify the survivors: low-disk merge, mid-play Wi-Fi toggle, far-seek/HLS fallback/scene reopen.
> — ~~*Non-sacred downloads housekeeping:* #23 (ghost transcode temp), #24 (stop() meta cleanup).~~
>   **DONE (commit `bc42aeb`):** #23 transcode temp → OS tmp dir + `loadCompleted` sweeps stray
>   `*.transcode.mp4`; #24 `stop()` now calls `cleanupMeta`, `retry()` re-heals the sidecar from the
>   in-memory scene if missing, and `init` runs `sweepOrphanedMeta()` (delete meta whose id has neither a
>   completed file nor an `.active` marker).
> — *Folded into the pending connection-screen feature:* #19 (keychain accessibility) — that rework
>   rewrites KeychainService anyway.
> — *Deferred lows:* disk-hit decode, per-frame GeometryReader, deadline race; and Phase-1 #3(b).

### Cluster A — caching / data layer (read ImageCache once, edit coherently)

### 15. [M] ImageCache has no in-flight coalescing → every uncached thumbnail fetched 2–3×
`Services/ImageCache.swift:52` (root cause of the #16-adjacent drift and the prefetch storm at
`Features/Library/ScenesView.swift:199`)
`image(for:)` suspends at `session.data(from:)`; actor reentrancy lets concurrent callers for the same key
pass both cache checks before the first writes. Two are guaranteed per cell (#13) plus overlapping prefetch
windows → 5–10× duplicate fetch/decode/write on cold scroll (against the minimal-server-load tenet).
**Fix:** actor-local `inFlight: [String: Task<UIImage, Error>]`; join an existing task if present, create
otherwise, **remove in a defer covering BOTH success and thrown-error paths** (clear-on-success-only
permanently poisons the key after any failure). `originalImage(for:)` (sprite crops, different key namespace)
needs its own entry — safe to share one dict. **Cancellation hazard (real):** SceneCard's
`.task(id: scene.id)` is view-identity-cancelled; a naive `await sharedTask.value` propagates cancellation
into the shared task, aborting the fetch for all awaiters — use a shielded inner task or reference-counted
awaiters. Also fixes the diskBytes drift (#L1) at the source.

### 16. [M] NSCache costs are compressed JPEG bytes for decoded bitmaps → 10–20× over budget
`Services/ImageCache.swift:76` (+ disk path :59, originalImage :104)
`cost: jpeg.count` (~40–100 KB) against a decoded UIImage bitmap (~0.8–1.4 MB); `totalCostLimit = 64MB` never
binds — only `countLimit=500` does → worst case ~400–700 MB resident (background-kill risk).
**Fix:** `let cost = (image.cgImage.map { $0.bytesPerRow * $0.height }) ?? data.count` at all four
`setObject` sites.
**Decision:** honest costing shrinks the effective cache to ~45–80 thumbnails at 64 MB. **Raise
`totalCostLimit` to ~128 MB** (≈90–160 thumbnails) to soften the scroll-back regression — still a large net
memory-safety win vs the current unintentional ~500-count ceiling.

### 17. [M] Disk eviction has no hysteresis → full dir scan+sort per new image at capacity
`Services/ImageCache.swift:147`
`enforceLimit` evicts to exactly `maxBytes`; the next write puts it back over → at steady state (3k–5k files)
a full `contentsOfDirectory` + per-file `resourceValues` + O(n log n) sort runs once per fetched thumbnail.
**Fix:** evict to an ~85% low-water mark: `let lowWater = maxBytes * 85 / 100; ...while diskBytes > lowWater`.
Amortizes scans to once per ~30 MB. `PreviewCache.swift` has the identical exact-cap pattern — decide
explicitly whether to patch it in the same pass (its write frequency is far lower, so deferring is defensible
if intentional). Combine with the #L1 diskBytes resync since both touch `enforceLimit`.

### 18. [M] LibraryEdits optimistic mutations race → persist AND re-display a stale value
`Services/LibraryEdits.swift:57`
Each edit spawns an independent Task that unconditionally writes the server response back; nothing orders
concurrent same-id mutations. Amplified by StashClient's DB-lock retry (500/1000/1500 ms): tap 3★ then 5★ →
request A retries after B commits, so the server permanently stores 3★ AND the UI snaps back to 3★. Silent
data mis-persistence in a daily-used feature.
**Fix Tier 1 (do this, ~10 lines, risk-free):** per-id `editSeq: [String: Int]`; capture a token at edit
time, apply the response/rollback only `if editSeq[id] == token`. **Must gate the `catch`/`restore()` branch
too**, not just success. Fixes the UI snap-back.
**Fix Tier 2 (server-side ordering — decide in-session):** *coalescing* (skip in-flight, send only latest) is
preferred over *chaining* (chaining adds 500–1500 ms latency per burst edit during the exact contention this
targets, and needs a per-id `[String: Task]` map pruned to avoid unbounded growth). Coalescing must re-check
"is my value still current" after the in-flight request resolves, or a naive impl drops the genuinely-final
value. Tier 1 fixes the confusing UI; Tier 2 fixes "server is permanently wrong" — don't drop it.

### 19. [H] Keychain WhenUnlockedThisDeviceOnly → cold locked relaunch shows LoginView until force-quit
`Services/KeychainService.swift:12`
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` + `AppState.init` reads credentials exactly once at launch.
On a cold background relaunch while the device is locked (normal: phone pocketed while a v1.0.107 handoff part
completes), both reads return `errSecInteractionNotAllowed` → `client = nil` latched for the process life →
owner later foregrounds into the login screen despite valid credentials. Looks like data loss.
**Fix (both):** (1) safety net (near-zero risk, and effectively load-bearing since it's the ONLY self-heal):
`.onChange(of: scenePhase)` → if `appState.client == nil`, re-read keychain + rebuild client (device is
unlocked when foregrounded); guard against clobbering an authenticated client and coordinate with
AppLockModifier's own scenePhase handler. (2) root cause: write with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, migrate by rewriting on next successful unlocked read.
**Trade-off:** (2) relaxes at-rest protection to readable-while-locked-post-first-unlock — standard for
background-work apps, but a conscious concession for a privacy-focused app. Confined to KeychainService.swift.

### Cluster B — downloads / playback hardening

### 20. [H, SACRED] merge() uses throwing FileHandle.write (disk-full crash) + try?-swallowed reads (silent truncation)
`Services/DownloadManager.swift:698`
`out.write(chunk)` is the legacy ObjC API that raises an *uncatchable* NSFileHandleOperationException →
process crash on ENOSPC mid-merge (peak disk ~2× file size; filling the disk downloading movies is normal
use). Separately `try? inHandle.read(...)` turns a mid-file I/O error into loop-exit-as-EOF → merge returns
true, item marked `.completed`, parts deleted → silently truncated file discovered only at playback.
**Fix:** `try out.write(contentsOf: chunk)` + non-optional `read` inside do/catch returning false; after
concat, verify dest size == expected total (`item.totalBytes` or sum of part sizes) before returning true.
**Multi-part branch only** (`parts.count > 1`, :693–701); the single-part `moveItem` fast path is already
safe — leave it. Fix eliminates crash + silent lie; does NOT add resume-from-partial-merge (don't oversell).
Device-verify with an intentionally low-disk scenario.

### 21. [H, SACRED-adjacent] Single network failure in remux read callback treated as EOF → movie silently "ends"
`Services/FFmpegRemuxer.swift:396`
`guard let data = box.data, !data.isEmpty else { return averrorEOF }` — the completion error is discarded, no
retry, no `offset` vs `size` check. One 8s Wi-Fi stall on a long HEVC/MKV remux (a primary daily route) →
trailer written, ENDLIST published, AVPlayer sees a clean end (`onEnded`, no `.failed`, watchdog already
disarmed) → video "finishes" mid-movie with no error/fallback.
**Fix:** in `read()`, capture the completion error; treat failure as EOF only when `size >= 0 && offset >=
size`. Else retry the slab 2–3× with short backoff, **polling `isAborted` between attempts** so teardown
stays prompt; after exhausting, return AVERROR(EIO) = -5 (not averrorEOF) so `reachedEOF` stays false and no
trailer is written.
**Residual gap (document in a code comment):** servers that never send Content-Range keep `size == -1` → the
fix can't gate and the bug persists there. Verify/tighten how reliably `size` gets populated for Stash
(`ensureSize()`/`totalLength()` at :427–451). Retries add ≤~20s hang on a genuinely dead network — still a
strict improvement over silent truncation. The blocking-sleep-in-AVIO-callback mechanics are the real risk to
get right. Device-test with a mid-play Wi-Fi toggle.

### 22. [H, SACRED] Engine swap leaks the entire previous AVPlayer stack + blur view
`Features/Player/ZoomablePlayerSurface.swift:138` (+ LiveBlurBackdropView:145, AVPlaybackEngine.teardown :172)
`reinitLocal` (far seek on remux) and `fallbackToHLS` swap engines, but the view layer never detaches the old
one: `attachPlayerView` only adds the new view, `teardown()` never sets `hostView.player = nil` or
invalidates the blur CADisplayLink. `AVPlayerLayer.player` is a strong ref → each stale host view retains a
full AVPlayer+item (tens of MB with 15s forward buffer on 4K) + a still-ticking 20 Hz blur display link. 5–10
far seeks on a 4K file = 100+ MB stranded + 100–200 pointless calls/sec. Real jetsam risk.
**Fix:** in `AVPlaybackEngine.teardown()`: `hostView.player = nil`, `hostView.removeFromSuperview()`,
`blurBackdrop.invalidate()` (CADisplayLink) + `blurBackdrop.removeFromSuperview()`. Extends an
already-correctly-invoked lifecycle method (called from stop/reinitLocal/fallbackToHLS); doesn't touch attach
logic. 1-frame black gap during reinit is already narrated by the existing `loadingStage="Seeking…"`/`isReady
= false`. Device-verify: inline↔fullscreen, far seek on remux, HLS fallback, scene close/reopen (view
re-parenting has bug history here — see the popover saga in ENGINEERING_NOTES).

### 23. [M] Transcode temp lives in downloadsDir → kill/crash resurrects it as a ghost "completed" download
`Services/DownloadManager.swift:404`
`downloadsDir/<id>.transcode.mp4` sits in the directory `loadCompleted()` enumerates every launch (creates a
`.completed` item for every file found); the only cleanup is the in-process catch that never runs on a kill.
→ ghost card backed by a truncated unplayable MP4 wasting GBs, never auto-cleaned.
**Fix:** write the transcode temp to `FileManager.default.temporaryDirectory` (preferred over Caches — OS can
purge tmp under pressure, and a purged in-progress transcode just fails cleanly). Add a `loadCompleted` sweep
that skips + deletes stray `*.transcode.mp4` (also cleans pre-existing orphans — important given no
server-side migration). `moveItem` at :439 stays a cheap same-volume rename regardless.

### 24. [M] stop() never removes sidecar meta → permanent disk leak per stopped download
`Services/DownloadManager.swift:372`
`stop()` calls cleanupParts/clearActive but never `cleanupMeta`; the sidecars (`<id>.json`,
`-thumb.jpg`, `-sprite.jpg` sprite sheets, `.vtt`) stay forever in Application Support (not OS-purgeable) —
loadInterrupted/loadCompleted both skip them.
**Fix:** call the existing `cleanupMeta(item.id)` in `stop()` (risk-free — same as `delete()` already does).
Add an init-time sweep deleting meta sets whose id has NEITHER a completed file in downloadsDir NOR a `.active`
marker. **Footgun:** the second discriminator is REQUIRED, not optional — completed items have no `.active`
marker but do have a downloadsDir file; an `.active`-only check would wipe every completed download's sidecar.
Sweep must run once at init before any download starts (else it races a fresh sidecar write). Key it EXACTLY
like `loadInterrupted`.

### 25. [M] serveMedia loads each HLS segment into memory twice
`Services/LoopbackServer.swift:174`
`serveMedia` reads a whole GOP fragment (~10–50 MB on 4K) then `send(box, Data(head.utf8) + data)` allocates a
SECOND full-size buffer for the concat. Overlapping AVPlayer segment fetches multiply the ~2×-segment spike.
**Fix:** send the header Data first, then the body separately (or chunk the body 1–2 MB from the FileHandle,
cancelling only after the last chunk's `.contentProcessed`).
**Gotcha (not "near-zero risk"):** the shared `send()` helper uses `.finalMessage`+cancel-on-completion; the
header send must NOT carry those semantics (or use `NWConnection.batch{}`) and only the body send may — get
this wrong and responses truncate/stall on the load-bearing HEVC playback path. Device-verify on an HEVC
source. Existing bounds (15s forward buffer, 75s pace-lead for ≥200 MB) already cap in-flight segments, so
treat full chunked streaming as a separate follow-up only if 4K shows pressure.

---

## Confirmed but deferred (low severity — batch opportunistically)

- **[L] diskBytes counter drift** — `ImageCache.swift:73`: duplicate same-key writes double-count; never
  resynced → eviction churn over a long session. Fix: `diskBytes = entries.reduce(0){$0+$1.size}` before the
  eviction loop in `enforceLimit`. (Fixing #15 removes the main drift source.)
- **[L] Disk-hit lazy decode** — `ImageCache.swift:58`: `UIImage(data:)` defers JPEG decode to the main-thread
  render commit. Fix: `image.preparingForDisplay() ?? image` inside the actor before returning. Couples with
  #16 (decoded bitmaps cost more) — land together. Worse on originalImage sprite sheets (:91).
- **[L] Per-scroll-frame @State writes** — `ScenePreview.swift:94`: GeometryReader tracks each cell's global
  frame every scroll tick; value used once at long-press. Fix: capture the rect at trigger time via the
  `CoordinateSpaceConverter` already threaded into `LongPressTrigger.makeCoordinator` (currently discarded).
- **[L] deadline data race** — `FFmpegRemuxer.swift:62`: `deadline` written from main (`abort()`) and the
  remux utility queue with no sync. Benign in practice (aligned 8-byte writes). Fix: route through the
  existing `progressLock`. Note the interrupt reads from a `@convention(c)` trampoline — NSLock/os_unfair_lock
  are safe there.

## Refuted (do NOT spend time on)

- `finalizeIfComplete` reentrancy — no live re-entry path exists today (the guard would be pure hardening).
- `pump()` continuation "wedge" on writer failure — AVFoundation's ready/failure callback contract prevents it.
- AppLock Face-ID unlock race — MainActor serialization + LocalAuthentication's auto-cancel already prevent it.

---

*Method: 7 subsystem reviewers over ~10.4k lines → adversarial verifier per significant finding (default
REFUTE). Verifier corrected 4 severities down and killed 3 findings. Not device-tested — magnitudes are
code-reasoned estimates.*
