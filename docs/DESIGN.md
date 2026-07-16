# Design Document: Soro — a fully-local on-device dictation app (macOS)

> This is the original design brief for Soro. It was written with AI assistance and
> handed to an AI build agent as the complete spec. Soro is a native macOS app in
> Swift/SwiftUI. Everything runs **on-device** — no accounts, no servers, no telemetry,
> no team features. It is designed to be shareable to a second Mac as an unsigned `.app`.
>
> Historical note: the app was originally code-named "Whispaa" during development and
> later renamed to **Soro** (Yoruba: *to speak / to shout*). Some sections below describe
> the design as a fully-local, independent reimplementation inspired by Willow Voice and
> Wispr Flow — no code, assets, or resources from those apps are used.

---

## How the build was organized

The build was run by an AI orchestrator that planned, sequenced, reviewed, and delegated
the actual coding to subagents (see **Appendix E** for the model-per-task strategy): a
stronger model on the OS-integration/correctness core (hotkey state machine, audio→whisper,
text insertion, notch bar, Ollama cleanup prompt), and a lighter model on the SwiftUI
screens, JSON persistence, history UI, and packaging.

Build order:
1. Pin the module interface contracts implied by §1/§4/§6 before any fan-out.
2. Walk the §9 build order: foundation first (skeleton + data model) → core serial → the four
   dashboard screens as bounded-parallel agents with worktree isolation → cleanup/style (M7).
3. After each milestone run the applicable **Appendix D** checks + a compile before proceeding.
   Do a dedicated adversarial review of the double-tap/hold disambiguation and the event-tap
   re-enable path.

Fully local — no accounts, sync, telemetry, or team features.

**Environment prerequisites (surface to the user if missing, don't silently skip):**
- Xcode + CLT present: `xcodebuild -version` must succeed (needed to compile between milestones).
- Ollama for M7 and App D checks 5–9: `brew install ollama && ollama pull llama3.2:3b`, daemon running.
- Microphone + Accessibility grants are manual; Accessibility re-prompts on each unsigned rebuild
  (App C) — expect to re-grant during development.

---

## 0. What we're cloning

Willow Voice (`com.seewillow.WillowMac`, v2.3.2) is a macOS menu-bar dictation app: you hold/tap a
hotkey, speak into any focused text field in any app, and cleaned-up, style-matched text is inserted
at your cursor. It shows a floating "dynamic island"-style bar near the notch while recording.

We are rebuilding it **fully offline**:
- Speech-to-text via **whisper.cpp** running locally (Willow itself bundles `whisper.framework`).
- Cleanup + style-matching via a **local LLM through Ollama** (Willow does this server-side; we do it
  on-device).
- Local file storage that mirrors Willow's layout so behavior/history feels identical.

Soro is an independent reimplementation inspired by the general behavior of apps in this
category. It uses **no** code, assets, names, or icons from any other app — it has its own
identity. Any references to Willow Voice or Wispr Flow below describe the general product
category and UX conventions only.

**Explicitly OUT of scope:** user accounts / Google sign-in,
cloud sync, the Team / Collaboration / Team Members features, referrals, subscription/paywall, Sentry
+ PostHog telemetry, "Learning Center" gamification. Keep the app self-contained.

---

## 1. Target & stack

| Concern | Decision |
|---|---|
| Language / UI | Swift + SwiftUI (menu-bar `MenuBarExtra` + separate windows). AppKit where needed (global event tap, floating panel). |
| Min OS | macOS 14 (Sonoma) or newer. Apple Silicon only is fine. |
| STT | whisper.cpp via Swift package **[whisper.cpp SwiftUI / `libwhisper`]** (e.g. `ggerganov/whisper.cpp` SPM target or `WhisperKit`). Use Core ML / Metal acceleration. |
| Cleanup + style LLM | Local **Ollama** HTTP API (`http://127.0.0.1:11434`). Default model `llama3.2:3b` (fast) with a settings dropdown to pick any installed model. Degrade gracefully to raw transcript if Ollama isn't running. |
| Audio | `AVAudioEngine` capture → 16 kHz mono PCM for whisper; also persist an `.opus` (or `.wav`) copy per recording. |
| Storage | Plain JSON files on disk (mirror Willow's schema, see §6). No database engine required. |
| Distribution | Unsigned `.app` in a `.dmg` or zip; user right-click-opens / `xattr -dr com.apple.quarantine` on the second Mac. Provide a short install note. |

**Recommendation for the STT library:** prefer **WhisperKit** (argmaxinc/WhisperKit) if Fable finds it
simplest — it's pure-Swift, Core ML, handles model download/management, and streams partial results.
Fall back to raw whisper.cpp SPM if WhisperKit is unsuitable. Either is acceptable; pick one and note it.

---

## 2. The core interaction (get this exactly right — it's the whole product)

Primary trigger key: **Left Option** (configurable). It is a *modifier-only* hotkey — pressed alone,
not as part of a combo. Two gestures, matching how the user runs Willow today:

1. **Push-to-talk (hold):** Press and hold Left Option → recording starts. Release → recording stops,
   transcription + cleanup runs, text is inserted. Used for quick one-liners.
2. **Locked / hands-free (double-tap):** Tap Left Option **twice quickly** (within ~300 ms) → recording
   starts and **locks on**. It keeps recording until you tap Left Option **once** again to stop. Used
   for long-form dictation without holding the key.

Edge cases to handle:
- Double-tap detection must not fire a spurious push-to-talk. Debounce: on first key-down start a
  timer; if a second key-down arrives within the window, enter locked mode; otherwise the first
  press behaves as push-to-talk (recording while held).
- If already locked and the user holds instead of taps, treat any Left-Option down as "stop".
- Escape / clicking the bar's X cancels recording and discards (no insertion).
- The trigger must be **global** (works when the app is unfocused). Requires a `CGEventTap` on
  `flagsChanged`/`keyDown`, which needs **Accessibility** permission.

**Secondary hotkeys (all configurable, all optional — ship with sensible defaults):**
- **Paste last transcript** (Willow default: Left Cmd + a key): re-inserts the most recent transcript.
- **Cancel:** Esc while recording.
- (Optional, can defer) **Command mode** — a separate hotkey (Willow uses Left Ctrl) that sends the
  spoken text to the LLM as an *instruction* rather than dictation ("make this a bulleted list"). Nice
  to have; put behind a settings toggle, build last.

Store hotkey config the way Willow does — as a struct with `keyCode`, `keyName`, `isModifierOnlyTrigger`,
`additionalModifiers`, `nonModifierKeys` (see the real `preferences.json` shape in §6).

---

## 3. The dictation pipeline

```
[hotkey down] → start capture (AVAudioEngine, 16kHz mono)
             → show recording bar (live mic-level waveform)
[hotkey up / stop] → stop capture, write recording file
             → whisper.cpp transcribe → raw text
             → glossary pass (spelling replacements + term biasing)
             → Ollama cleanup+style pass (filler removal, punctuation, style match)
             → insert text at cursor
             → save transcript record + update stats
             → play completion sound, hide bar
```

### 3a. Audio capture
- `AVAudioEngine` input tap → resample to 16 kHz mono `Float`. Feed streaming buffers to whisper for
  low latency (target first text fast; Willow claims ~200 ms but on-device whisper realistically
  finishes shortly after you stop — that's fine).
- Persist each recording to `Recordings/recording_<ISO8601>.opus` (or `.wav` if opus encoding is a
  hassle — WAV is acceptable). Respect a **privacy mode** setting that deletes the audio right after
  transcription (Willow has `privacyMode: true`).
- Play short start/stop sounds (settings-toggleable, Willow has `audioRecordingSounds`).

### 3b. Transcription (whisper.cpp)
- Bundle no model by default; on first run, prompt to **download a Whisper model** (default
  `ggml-base.en` or WhisperKit's `base`/`small`; let the user pick `small`/`medium` for accuracy in
  settings). Store under `~/Library/Application Support/<bundle>/Models/`.
- Language: default English; support a language picker and an "auto-detect" toggle (Willow:
  `selectedLanguages`, `isAutoDetectLanguage`).
- Pass the glossary terms to whisper as an `initial_prompt` to bias recognition of names/jargon.

### 3c. Glossary / Personal Dictionary pass
Two kinds of entries (both live in `glossary.json`, distinguished by `isReplacement`):
- **Terms** (`isReplacement:false`): vocabulary to recognize correctly (names, brands, acronyms).
  Used to bias whisper + to case-correct output (e.g. force "Supabase", "Y Combinator").
- **Shortcuts / replacements** (`isReplacement:true`): spoken-phrase → expanded-text (e.g. say "my
  email" → inserts the address). Applied as literal find/replace on the transcript.
- **Auto-learned terms:** track word frequency in `auto_dictionary_cache.json`; when a novel
  capitalized/proper term recurs, surface it as a suggested dictionary term (tag `Auto-Learned`).
  Keep this simple — frequency counter + a suggestions surface in the Dictionary UI.

### 3d. Cleanup + style pass (Ollama)
- Send raw (glossary-corrected) transcript to Ollama with a system prompt that:
  - removes filler words ("um", "uh", "like", false starts, repetitions),
  - fixes punctuation/capitalization,
  - **infers structure without explicit commands** — this is the single most-praised Willow
    behavior. If the user starts enumerating ("first… second… also… another thing…" or "one, two,
    three…"), format it as a **numbered or bulleted list**. Detect natural paragraph breaks. Keep
    prose as prose. Don't over-format short messages. See §5A for the exact rules.
  - **honors spoken formatting commands** when given explicitly ("new line", "new paragraph",
    "bullet point", "next point", "dash", "period", "comma", "question mark") — see §5A.
  - **applies mid-speech self-corrections** — if the user says "no wait", "scratch that", "I mean",
    "change that to…", "actually make it…", resolve the correction and emit only the final intended
    text (never the retracted words or the correction phrase itself). See §5A.
  - **matches the user's style** for the current context (see §5),
  - returns ONLY the cleaned text, no preamble, no quotes, no explanation.
- Determine **context** from the frontmost app's bundle id (see §5). E.g. Messages/WhatsApp/Slack →
  casual; Mail/Gmail → email; everything else → work/other.
- Respect a global toggle: if cleanup is off, or Ollama is unreachable, insert the raw glossary-
  corrected transcript and show a subtle "raw" indicator. Never block insertion on the LLM for more
  than a short timeout (e.g. 4 s) — fall back to raw.
- Keep the prompt short and deterministic (`temperature` low). Include the personal "tweak" text and
  the user's recent style samples if present.

### 3e. Text insertion
- Insert at the current cursor in the frontmost app. Primary method: synthesize a paste —
  put text on the pasteboard, send ⌘V via `CGEvent`, then restore the previous pasteboard. This is
  what Willow's "smart text insertion" does and it's the most reliable across apps. Requires
  Accessibility.
- Fallback: type the characters via `CGEvent` keystrokes if paste fails (Willow has a "manual paste
  fallback").
- Optional trailing behavior: `cursorAutomaticEnter` (press Return after insert) as a setting.
- Some apps get an app-specific tweak (Willow lowercases in Messages via `messagesLowercase`, adds a
  file reference in Cursor). Implement a small per-app rules map; keep it minimal.

---

## 4. UI surfaces

### 4a. The recording bar (the "dynamic island" — highest-fidelity piece)
A small floating panel that appears **centered under the notch / top of screen** while recording
(Willow calls it Notch View / the "bar", `enableNotchView`). Requirements:
- Borderless, rounded, dark, always-on-top, non-activating `NSPanel` (doesn't steal focus), ignores
  clicks except its own controls, floats above full-screen apps.
- States: **idle/hidden** → **recording** (animated live waveform driven by mic level, elapsed timer,
  a lock indicator when in locked mode, an X to cancel) → **transcribing** (spinner/"thinking"
  shimmer) → brief **done** flash → hide.
- Setting `hideBarWhenIdle` / `hideBar`: when idle either fully hidden or a tiny dormant pill you can
  click to start. Match Willow: default hidden-when-idle, expands on record.
- The bar should be **draggable** to reposition and remember its location (Willow: `barEverMoved`,
  saved frame).
- Also show a **menu-bar icon** (`MenuBarExtra`, toggle via `showMenuBarIcon`) with: current mode,
  start/stop, open dashboard, settings, quit.

Look/feel reference: dark translucent capsule, subtle scale/opacity spring animations, waveform bars
that react to input level. Use SwiftUI animations or Lottie if convenient (Willow bundles Lottie).

### 4b. Main dashboard window
A normal resizable window with a left sidebar. Sidebar items (drop Willow's "Team" section entirely):
- **Home** — header "Hold [Opt] to dictate on [current app]"; stat cards: **Dictated words**,
  **Time saved**, **Day streak**, **Average speed (wpm)**; a **History** list below (searchable,
  grouped by day, each row = time + transcript text; click to copy / re-insert / delete; play the
  saved audio). This is the biggest screen — see screenshot 2 of the reference for layout.
- **Dictionary** — "Personal Dictionary". Two tabs: **Personal Terms** and **Personal Shortcuts**.
  Grid of term chips, search, **+ Add Term**. Terms map to `glossary.json` (§3c). Show auto-learned
  suggestions.
- **Style Matching** — configure per-context writing style (formal/casual), scribe writing style
  (natural/polished/etc.), and a freeform "personal tweak" instruction per context
  (work / email / casual / other). Maps to `personalization_preferences.json`.
- **Settings** — microphone picker, hotkey rebinding (all hotkeys from §2), Whisper model download/
  select, Ollama model select + cleanup on/off, language(s) + auto-detect, privacy mode (delete audio),
  recording sounds, launch-at-login, menu-bar icon toggle, bar behavior, auto-Return.

Match Willow's visual language: light theme, rounded cards, purple accent (`#4F46E5`-ish), generous
padding, SF Pro. Keep it clean; pixel-perfection not required, "clearly the same app" is.

### 4c. Onboarding (minimal)
A short first-run flow: request Microphone + Accessibility permissions (with the system prompts and a
"test it" step), pick/download a Whisper model, confirm Ollama is installed (link to install if not),
choose the trigger key, do one practice dictation. Skip Willow's account/role/source survey steps.

---

## 5. Style matching & context detection

- Detect the frontmost app via `NSWorkspace.frontmostApplication.bundleIdentifier` at record time.
- Map bundle id → context bucket: `casual` (Messages, WhatsApp, Slack, Discord, Instagram, iMessage),
  `email` (Mail, Gmail in browser — best-effort by window title/URL if feasible, else default), `work`
  (Cursor, VS Code, Notion, Linear, terminals), `other` (fallback).
- Each context has: a **messaging style** (formal/casual), a **scribe writing style**
  (natural/…), and a freeform **personal tweak** string. Feed these into the Ollama system prompt.
- (Nice-to-have, defer) learn style from the user's edits/history to auto-tune. Not required for v1;
  the manual per-context settings are enough.

---

## 5A. Delighters — the details that make people love Willow

These come from real user reviews (Product Hunt 4.9/5, independent reviews). They are what
separates "a whisper.cpp wrapper" from something people prefer over the original. Prioritize them.

### Implicit formatting intelligence (the #1 loved feature)
The LLM cleanup pass must format based on *intent*, not just literal words, with **no command words
required**:
- Enumeration → list. Triggers: ordinal words ("first/second/third", "one/two/three"), repeated
  "and then…", "another thing is…", "next…". Choose **numbered** for sequences/steps, **bulleted**
  for unordered items. Preserve the user's own numbering if they gave it.
- Natural paragraph breaks when the topic shifts or after "so anyway…", "moving on…".
- Leave short one-liners as plain sentences — do NOT bulletize a single thought.
- Code/technical context (Cursor, VS Code, terminal): be conservative — don't reflow into prose,
  keep it literal, don't invent Markdown the editor won't render.
- Match the destination: Markdown lists in Notion/Slack/docs; plain `- ` or `1.` where Markdown
  isn't rendered. Keep it simple and safe.

### Explicit voice formatting commands (when the user does say them)
Recognize and apply, then strip the command word from output: "new line" / "new paragraph",
"bullet point" / "next bullet", "numbered list" / "next point", "dash", "open/close quote",
literal "period", "comma", "question mark", "exclamation mark", "colon", "semicolon". If ambiguous
(did they mean the punctuation or the word?), prefer the natural reading — this is exactly what the
LLM pass is good at.

### Self-correction while speaking
People dictate the way they think — with false starts and mid-sentence fixes. Detect and resolve:
"no wait", "scratch that", "sorry, I mean", "actually change that to", "let me restart", "delete
that last bit". Emit only the final intended text; never echo the retracted words or the correction
phrase. This is also what makes it forgiving for stutters / disfluencies (a reviewer with a stutter
noted it "still works really well").

### Scribe / AI Mode (turn rough notes into a polished message)
A distinct mode (separate hotkey or a toggle in the bar) where the transcript is treated as *intent
to be expanded*, not verbatim dictation: "tell Sam the meeting's moved to Thursday and I'll send the
deck" → a complete, well-formed message in the user's style. Willow calls this **Scribe**; the Home
stats track `lifetimeScribeUses`. Contrast with normal mode, which stays faithful to the words.
Ship normal mode in v1; Scribe is a strong v1.1 (wire the stat + mode plumbing now).

### Adaptive style memory
Beyond the manual per-context style settings (§5), keep a small rolling sample of the user's
*accepted* outputs per context and feed 2–3 recent samples into the cleanup prompt as few-shot
style anchors, so tone drifts toward how they actually write over time. Lightweight; no training.
Reviewers specifically call out that Willow "learns from your edits." (Nice-to-have for v1, but the
plumbing — storing recent samples per context — is cheap; add it.)

### Small touches that add up
- **Undo/redo the last insertion** and a **re-insert last transcript** hotkey (§2) — reviewers love
  recovering a dictation without re-speaking.
- **Per-app tone** actually switching (casual in Messages/Slack, professional in Mail) — visibly
  demonstrate it works, it's a headline delighter.
- **Whisper-quiet input**: whisper.cpp handles low-volume speech reasonably; don't gate recording on
  a high input-level threshold, so quiet/whispered dictation still transcribes.
- **Zero network anxiety**: because we're fully local, there's *no* latency-from-bad-wifi and *no*
  "your dictation was sent to a server" — the top two Willow complaints. Surface "100% on-device" as
  a visible, reassuring point in onboarding and settings. This is our main edge over the original.
- **No nag notifications**: a specific Willow complaint is an un-disableable inactivity nag. Don't
  build nags at all.

---

## 6. Data model & on-disk layout

Mirror Willow's real layout under `~/Library/Application Support/<your-bundle-id>/`. Real schemas
observed in the reference install:

**`Transcripts/<UUID>.json`** — one file per dictation:
```json
{
  "id": "91286E6C-244A-4028-A947-36FA3E0FDA1B",
  "text": "the cleaned transcript text",
  "audioURL": "file:///…/Recordings/recording_2025-08-29T05:50:30.228Z.opus",
  "recordingDuration": 12.4,
  "date": 778139430.946161
}
```
- `date` is **Apple/Cocoa epoch** (seconds since 2001-01-01). Use `Date.timeIntervalSinceReferenceDate`.
- Reserve a sentinel like `"ERROR_TRANSCRIBING"` for `text` on failure (Willow does this).
- 9,700+ of these exist in the reference; the History UI must page/virtualize and search efficiently.

**`Recordings/recording_<ISO8601>.opus`** — the saved audio (or `.wav`). Deleted immediately if
privacy mode is on.

**`Preferences/preferences.json`** — app settings. Real Willow keys worth mirroring:
`selectedMicrophoneUID`, `appLanguage`, `selectedLanguages`, `isAutoDetectLanguage`, `privacyMode`,
`contextAwareness`, `enableAutoDictionary`, `smartTextInsertion`, `enableNotchView`, `hideBar`,
`hideBarWhenIdle`, `audioRecordingSounds`, `launchAtLogin`, `showMenuBarIcon`, `cursorAutomaticEnter`,
`messagesLowercase`, `offlineMode`/`alwaysUseOfflineMode` (in our clone: always offline),
`selectedHotkey`, and the hotkey arrays:
```json
"hotkeyData": {"keyCode":58,"keyName":"Left Option","isModifierOnlyTrigger":true,
  "additionalModifiers":[],"nonModifierKeys":[],"isRightModifier":false,"modifiers":0,
  "isMouseButton":false,"mouseButton":0}
```
Plus `handsFreeModeHotkeyDataArray`, `pasteTranscriptHotkeyDataArray`, `commandModeHotkeyDataArray`.

**`Preferences/glossary.json`** — dictionary array:
```json
[
  {"id":"…","term":"Willow","tag":"My Terms","isEnabled":true,"isReplacement":false},
  {"id":"…","term":"Apple","tag":"Auto-Learned","isEnabled":true,"isReplacement":false}
]
```
Shortcuts add `"isReplacement":true` with a replacement value field (add `"replacement":"…"`).

**`Preferences/personalization_preferences.json`** — style settings:
```json
{"workMessagingStyle":"formal","emailStyle":"formal","casualMessagingStyle":"casual",
 "otherStyle":"formal","workScribeWritingStyle":"natural","emailScribeWritingStyle":"natural",
 "casualScribeWritingStyle":"natural","otherScribeWritingStyle":"natural",
 "workPersonalTweak":"","emailPersonalTweak":"","casualPersonalTweak":"","otherPersonalTweak":""}
```

**`Preferences/auto_dictionary_cache.json`** — auto-learn frequency map:
```json
{"supabase":{"word":"Supabase","firstSeen":791503919.9,"lastSeen":794655944.8,"occurrenceCount":3}}
```

**`Preferences/feature_usage_stats.json`** — counters for the Home stats:
```json
{"lifetimeDictations":1208,"lifetimeScribeUses":0,"handsFreeEverUsed":true,"barEverMoved":false}
```
Derive "Dictated words", "Average speed (wpm)", "Time saved", "Day streak" from transcripts + these.

> The JSON schema is intentionally simple and self-contained, which makes an optional one-time
> **import** from a compatible on-disk layout straightforward to add later. Nice bonus, not required.

---

## 7. Permissions, entitlements, packaging

- **Info.plist usage strings:** `NSMicrophoneUsageDescription`, `NSAccessibilityUsageDescription`
  ("… needs accessibility access to insert text and detect the hotkey"), `NSAppleEventsUsageDescription`.
- **Accessibility** (AXIsProcessTrusted) required for the global event tap + paste — guide the user to
  System Settings > Privacy > Accessibility in onboarding; poll for grant.
- **Microphone** via `AVCaptureDevice` authorization.
- **App Sandbox: OFF** (a global event tap + arbitrary-app paste won't work sandboxed). Hardened
  runtime optional; since we're distributing unsigned this is fine.
- **Launch at login** via `SMAppService`.
- Build a Release `.app`, wrap in `.dmg`. Provide install instructions for the 2nd Mac:
  `xattr -dr com.apple.quarantine "/Applications/<App>.app"`, then grant Mic + Accessibility.
- Sparkle auto-update is **optional** — skip for v1; manual re-copy is fine for two machines.

---

## 8. Dependency on Ollama

- The clone assumes **Ollama** is installed and running locally. On first launch and on cleanup calls,
  check `GET http://127.0.0.1:11434/api/tags`. If down: show a one-time banner with install guidance
  (`brew install ollama` / ollama.com) and a "pull default model" button (`ollama pull llama3.2:3b`),
  and fall back to raw transcripts until it's available.
- Cleanup call: `POST /api/generate` (or `/api/chat`) with `stream:false`, low temperature, the system
  prompt from §3d, and a hard timeout with raw-fallback.

---

## 9. Build order (milestones)

1. **Skeleton:** menu-bar app, windows shell, permissions onboarding, settings persistence to JSON.
2. **Capture + whisper:** AVAudioEngine → whisper.cpp → print transcript. Model download flow.
3. **Insertion:** pasteboard-paste at cursor + fallback typing. Verify across Mail/Slack/Notion/Cursor.
4. **Hotkey engine:** global CGEventTap; push-to-talk + double-tap-lock gestures (§2). This is the
   trickiest correctness piece — write it carefully and test the timing.
5. **Recording bar:** floating notch panel with live waveform + states + drag/persist.
6. **Glossary pass** + Dictionary UI (terms, shortcuts, auto-learn suggestions).
7. **Ollama cleanup + style pass** + Style Matching UI + context detection.
8. **History + Home dashboard:** transcript store, search, stats, re-insert/copy/delete, audio playback.
9. **Polish:** sounds, animations, privacy mode, launch-at-login, package unsigned `.dmg`.
10. (Optional) Command mode, Willow-history import, Sparkle updates.

---

## 10. Definition of done (v1)

- Hold Left Option anywhere → speak → cleaned, style-matched text lands at the cursor, fully offline.
- Double-tap Left Option → locked recording until tapped again.
- Floating notch bar shows recording/transcribing states with a live waveform.
- Dictionary terms/shortcuts affect output; per-context style settings change tone.
- History of every dictation with search, stats on Home, audio saved (unless privacy mode).
- No network calls except localhost Ollama; no accounts, telemetry, or team features.
- Builds to an unsigned `.app` that runs on a second Mac after granting Mic + Accessibility.

---

## Appendix A — Concrete dependencies & Xcode project config

Don't deliberate over these; use them and move on.

- **Project type:** macOS App, SwiftUI lifecycle. Set **`LSUIElement` / `NSApplication.setActivationPolicy(.accessory)`** so it's a menu-bar app with no Dock icon. Windows (dashboard/settings) open on demand.
- **App Sandbox: OFF.** Hardened Runtime optional (we ship unsigned). Add entitlement notes only if needed for a dev build.
- **STT (pick one, prefer the first):**
  - `WhisperKit` — SPM `https://github.com/argmaxinc/WhisperKit` — pure Swift, Core ML, manages model download, streams. Default model `openai_whisper-base.en`; expose `small`/`medium` in settings.
  - Fallback: `whisper.cpp` — SPM `https://github.com/ggerganov/whisper.cpp` (has a `swift` target). Download `ggml-base.en.bin` from `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin` into `…/Models/`.
- **Global hotkey:** raw `CGEvent.tapCreate` on `.cgSessionEventTap` for `flagsChanged`+`keyDown` (needed because the trigger is a bare modifier). Don't use a combo-only library like HotKey/MASShortcut for the main trigger — they can't do modifier-only. A helper lib is fine for the *secondary* combo hotkeys.
- **Launch at login:** `SMAppService.mainApp`.
- **Ollama:** plain `URLSession` to `http://127.0.0.1:11434`. No SDK needed.
- **Icon/assets:** if none provided, generate a simple placeholder app icon (a mic/waveform glyph on the purple accent) — don't block on design.

## Appendix B — Ready-to-use Ollama cleanup prompt

Use this as the system prompt for the normal-mode cleanup pass (§3d/§5A). Fill the bracketed vars from the current context. Keep `temperature` ~0.2, `stream:false`, and a ~4 s timeout with raw-text fallback.

```
You clean up raw voice-dictation transcripts. Output ONLY the cleaned text — no quotes, no preamble, no commentary, no explanation.

Rules:
- Remove filler words and disfluencies: um, uh, er, like, you know, sort of, false starts, repeated words.
- Apply self-corrections: if the speaker retracts or changes something ("no wait", "scratch that", "I mean", "actually change that to", "delete that"), output ONLY the final intended text. Never include the retracted words or the correction phrase.
- Fix capitalization, punctuation, and obvious transcription errors. Do not change the meaning or add content the speaker did not say.
- Infer structure from intent, without needing explicit commands:
  - If the speaker enumerates items (first/second/third, one/two/three, "another thing is", repeated "and then"), format as a list — numbered for sequences/steps, bulleted for unordered items.
  - Start a new paragraph when the topic clearly shifts.
  - Leave a single short thought as one plain sentence. Do NOT over-format.
- Honor explicit spoken formatting commands and then remove the command word: "new line", "new paragraph", "bullet point", "next point", "dash", literal "period/comma/question mark/colon".
- Preserve these exact terms/spellings if they appear (personal dictionary): [GLOSSARY_TERMS].

Destination app: [APP_NAME] (context: [CONTEXT: casual|email|work|other]).
Writing tone: [MESSAGING_STYLE: formal|casual]. Style: [SCRIBE_STYLE]. Extra instruction: [PERSONAL_TWEAK].
For casual contexts, keep it relaxed and brief. For email/work, be clear and appropriately polished. In code editors, stay literal — do not reflow into prose or add Markdown the editor won't render.

[STYLE_SAMPLES: 0–3 recent accepted outputs from this context, as tone anchors.]

Raw transcript:
"""
[RAW_TRANSCRIPT]
"""
```

(Scribe/AI mode, when built, swaps the first line for: "You turn rough spoken notes into a complete, polished message in the user's voice. Expand intent into well-formed text; keep it faithful to what they want to say." Same context/style block.)

## Appendix C — macOS gotchas the agent must handle

- **Event tap can be auto-disabled** by the system (timeout/user input overload). Listen for `.tapDisabledByTimeout`/`.tapDisabledByUserInput` and re-enable the tap immediately, or dictation silently dies.
- **Secure input fields** (password fields) block synthetic paste/keystrokes and can enable "secure input" globally. Detect failure and no-op gracefully; never spin trying to insert.
- **Pasteboard restore:** save the full pasteboard, set text, send ⌘V, then restore — but wait a beat (async, ~100–150 ms) before restoring so the target app finishes reading it. Losing the user's clipboard is a trust-killer.
- **Accessibility grant is per-build:** an unsigned app re-requests Accessibility whenever its binary changes. Expect to re-grant during development; document this for the 2nd-Mac install.
- **Double-tap vs hold timing:** tune the double-tap window (~250–300 ms). Ensure a slow single hold never registers as a double-tap, and a fast tap-then-hold is disambiguated correctly (§2).
- **Frontmost app at *record start*** determines context — capture it when recording begins, not when inserting (focus may change).

## Appendix D — Single-machine verification checklist

The agent can validate all of this on one Mac before we ever touch the second machine:

1. Build succeeds; app launches as a menu-bar item with no Dock icon; onboarding requests Mic + Accessibility.
2. Hold Left Option in TextEdit/Notes → speak → cleaned text inserted at cursor. Release stops it.
3. Double-tap Left Option → recording locks (bar shows lock) → tap once → stops and inserts.
4. Recording bar appears under the notch, shows a live waveform, transcribing state, then hides.
5. Say a list ("first do X, second do Y, third do Z") → output is a numbered list. Say one sentence → stays a sentence.
6. Say "add milk no wait add oat milk" → output contains "oat milk", not "milk" or "no wait".
7. Add a dictionary term (e.g. a name) → it's spelled correctly in output; add a shortcut → phrase expands.
8. Change Style Matching for casual vs work → tone visibly differs between Messages and Mail.
9. Kill Ollama → dictation still inserts raw text with a "raw" indicator (no hang).
10. History lists the dictation, search finds it, re-insert works, audio plays; Home stats increment.
11. Quit Ollama's model / pick a different model in settings → cleanup still works.
12. Archive a Release build, `xattr -dr com.apple.quarantine` a copy, confirm it opens.

---

## Appendix E — Build orchestration (Fable orchestrates, Opus/Sonnet implement)

This section is instructions to the **orchestrator** (the session/agent that picks up this goal), not
part of the app. If you are that orchestrator: coordinate, sequence, and review — delegate the actual
coding to implementation subagents with explicit per-task model overrides.

**Mechanism.** Spawn implementation agents with a model override:
- In a Workflow script: `agent(prompt, { model: 'opus' | 'sonnet' | 'haiku', isolation, agentType })`.
- Or via the Agent tool's `model` parameter.
The orchestrator itself runs on the session model (Fable). Only the *workers* get overridden.

**Model assignment — put the strong implementer on the correctness-critical, OS-integration core:**

| Use **Opus** for (hard reasoning / OS integration / gets-it-wrong-silently) | Use **Sonnet** for (well-specified, mostly mechanical) |
|---|---|
| Global hotkey engine: `CGEventTap`, push-to-talk **and** double-tap-lock state machine (§2) + the timing gotchas (App C) | SwiftUI screens: Home, Dictionary, Style Matching, Settings, onboarding (§4) |
| Audio capture → whisper streaming integration (§3a–b) | JSON persistence layer + data models mirroring the schemas (§6) |
| Text insertion: pasteboard save/paste/restore + secure-input handling (§3e, App C) | History list/search/virtualization + stats derivation (§4b) |
| Ollama cleanup prompt design, formatting-intelligence + self-correction tuning (§3d, §5A, App B) | Packaging: Release build, `.dmg`, quarantine-strip script (§7) |
| The non-activating notch `NSPanel` + live-waveform bar (§4a) | Glossary/dictionary CRUD + auto-learn frequency counter (§3c) |

Haiku is fine for trivial glue (asset wiring, string tables). When unsure, prefer Sonnet; escalate a
task to Opus if a Sonnet worker stalls or produces something that fails an App C / App D check.

**Sequencing — default to sequential-by-milestone, not blind parallelism.** This is ONE Xcode
project with shared state; parallel agents editing it collide. Two safe patterns:

1. **Sequential by milestone (default).** Orchestrator walks the §9 build order, delegating each
   milestone to a worker of the assigned model, then runs the relevant App D checks + a build before
   moving on. Do the **foundation first** (M1 skeleton, M2 capture, §6 data model) so later work has
   stable interfaces/contracts to build against.
2. **Bounded parallel — UI screens only, and only after the shell + data model exist.** The four
   dashboard screens (§4b) are largely independent once the data model is fixed; those may fan out to
   separate **Sonnet** agents using `isolation: 'worktree'` to avoid clobbering, then be integrated in
   a serial merge/build step. **Do not** parallelize the OS-integration core (hotkey, capture,
   insertion, bar) — it's too interdependent; keep it serial on Opus.

**Make parallelism safe by defining contracts up front.** Before any fan-out, the orchestrator should
have Opus (or itself) pin down the module boundaries and interfaces implied by §1/§4/§6 — the audio
service, transcription service, cleanup service, insertion service, hotkey manager, store, and the
view-models each screen binds to. Agents then code against those signatures.

**Review between milestones.** After each milestone, run the applicable App D checks and a compile.
For the hotkey state machine specifically, do an **adversarial review** (a separate Opus agent asked
to break the double-tap/hold disambiguation and the event-tap re-enable path) — it's the piece most
likely to be subtly wrong.

**Minimal orchestration sketch (illustrative):**
```js
// foundation first, serial, strong implementer
await agent('M1 skeleton: menu-bar accessory app, windows shell, JSON settings store (§6, App A)', { model: 'opus' })
await agent('M2 audio capture + whisper (§3a–b, App A)', { model: 'opus' })
// core OS integration — serial, Opus
await agent('M4 hotkey engine: push-to-talk + double-tap-lock (§2, App C)', { model: 'opus' })
await agent('M3 text insertion + secure-input handling (§3e, App C)', { model: 'opus' })
await agent('M5 notch bar panel + waveform (§4a)', { model: 'opus' })
// independent UI screens — bounded parallel, Sonnet, isolated
await parallel(['Home','Dictionary','StyleMatching','Settings'].map(s => () =>
  agent(`Build the ${s} screen (§4b/§4c) against the fixed view-model contracts`,
        { model: 'sonnet', isolation: 'worktree' })))
// cleanup+style, then review
await agent('M7 Ollama cleanup + style pass + context detection (§3d, §5A, App B)', { model: 'opus' })
await agent('Adversarially test the hotkey state machine + event-tap re-enable (§2, App C)', { model: 'opus' })
```

Whoever kicks this off can simply instruct the orchestrator: **"Build per FABLE_BUILD_BRIEF.md,
orchestrating per Appendix E."**
