# Integration: dev-cli-context

Refines cleanup context so dictating into a terminal or an AI coding assistant
(e.g. Claude Code CLI) cleans the prose while preserving technical tokens.

## What changed (all within scope)

- `Core/Cleanup/ContextDetector.swift`
  - `ContextSnapshot` gains **`isAIPromptOrCode: Bool`** alongside the existing
    `isCodeEditor`. Terminals (Terminal, iTerm2, Warp, Ghostty, Alacritty, kitty,
    Hyper) and AI-prompt surfaces (Claude desktop, ChatGPT, Cursor, VS Code) set
    it `true`. `DictationContext` still maps all of these to `.work` (enum
    unchanged, per docs/CONTRACTS.md).
  - New static helpers: `ContextDetector.isCodeEditor(bundleId:)` and
    `ContextDetector.isAIPromptOrCode(bundleId:)` — shared source of truth so the
    prompt can classify from a bundle id alone.
- `Core/Cleanup/DevJargon.swift` (new) — a static seed list of dev product names
  plus `DevJargon.augment(_ userTerms:)` (user terms first, case-insensitive
  dedupe, seed appended). Not part of any struct.
- `Core/Cleanup/PromptBuilder.swift` — for technical-prose contexts, adds a
  "TECHNICAL CONTEXT" preserve-tokens clause, augments the glossary with
  `DevJargon`, and distinguishes a literal code editor (stay verbatim) from
  terminal/AI-prompt prose (clean the prose, keep tokens). Existing few-shot and
  faithfulness rules are untouched.

## Wiring notes for AppState / DictationCoordinator

- **No required changes.** `CleanupContext` signature is unchanged (frozen per
  contract). `PromptBuilder` derives the technical-prose decision from the
  context's existing `bundleId` + `isCodeEditor`, so the current construction in
  `DictationCoordinator.runPipeline()` already produces the correct prompt.
- **`ContextSnapshot.isAIPromptOrCode` is now available** if any caller wants the
  flag directly (e.g. to show a "dev mode" indicator). It is additive; nothing
  consumes it yet. `ContextSnapshot` is constructed only inside
  `ContextDetector.snapshot()`, so no other call sites need updating.
- If a future change wants to pass the flag through to cleanup explicitly rather
  than re-deriving from `bundleId`, that would require adding a field to
  `CleanupContext` — a contract change (out of scope here).

## Behavior summary

| Surface | context | isCodeEditor | isAIPromptOrCode | Prompt effect |
|---|---|---|---|---|
| Terminal / iTerm2 / Warp / Ghostty / Alacritty | work | false | true | Clean prose + preserve tokens + DevJargon seed |
| Claude / ChatGPT desktop | work | false | true | Clean prose + preserve tokens + DevJargon seed |
| Cursor / VS Code | work | true | true | Literal (stay verbatim) + preserve tokens + DevJargon |
| Notion / Linear | work | false | false | Normal work cleanup, no tech clause/seed |
| Messages / Mail / other | casual/email/other | false | false | Unchanged |
