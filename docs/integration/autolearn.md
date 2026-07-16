# Auto-Learn Dictionary — Integration Notes

**Task key:** `autolearn`
**Files touched:**
- `Soro/Soro/Stores/AutoDictionaryStore.swift`
- `Soro/Soro/UI/Dashboard/DictionaryView.swift`
- `Soro/SoroTests/AutoDictionaryStoreTests.swift` (new)

---

## What changed

### AutoDictionaryStore

**`observe(transcript:)`** — no signature change. Now preserves the best-cased form of a token
(jargon form wins over lowercased form) so the suggestion word carries correct casing.

**`suggestions() -> [String]`** — no signature change. Now applies a second-pass filter using
`looksLikeJargonOrProperNoun(_:)` before returning candidates, so only tokens that look like
proper nouns or technical jargon are surfaced. Common English words, even if capitalized at
sentence start, are suppressed.

**`looksLikeJargonOrProperNoun(_ word: String) -> Bool`** — new **public** method (needed for
unit tests). Returns `true` when a token is likely a proper noun or jargon term. Four accepted
forms, checked in order:

| Form | Example | Rule |
|------|---------|------|
| snake_case | `user_id`, `AUTH_TOKEN` | contains `_` and at least one letter |
| ALL-CAPS acronym | `API`, `JSON`, `WWDC` | all letter chars uppercase, ≥ 2 letters |
| camelCase | `SwiftUI`, `iPhone`, `openAI` | uppercase letter after position 0 |
| Capitalized proper noun | `Anthropic`, `Supabase` | starts uppercase, no apostrophe, not in `commonWords` |

**`commonWords`** — expanded from ~60 to ~150 entries, covering articles, conjunctions,
prepositions, pronouns, auxiliaries, common verbs, adverbs, adjectives, sentence starters,
and disfluency fillers.

**Contractions** (tokens containing `'`) are always rejected — they are never proper nouns.
This eliminates false positives like `It's`, `Don't`, `I'm` that appear capitalized at sentence
start after tokenization.

### DictionaryView — AutoLearnedSuggestionsRow

No API or wiring changes. The section is now a more prominent card:
- Purple-accented border (`SoroTheme.accent`, 1.5 pt) with a subtle shadow.
- Header row with an accent pill icon, title **"Suggested from your speech"**, subtitle
  **"Tap + to add a term, × to dismiss"**, and a count badge showing pending suggestions.
- Chips unchanged (`SuggestionChip` with Add / Dismiss buttons).
- Shown only in the **Terms** tab, above the chip grid, when suggestions exist.

---

## Wiring required from AppState / DictionaryView

No changes needed. The existing wiring is correct:

```swift
// AppState sets up the glossary exclusion closure after both stores are created:
autoDict.isInGlossary = { [weak glossary] word in
    glossary?.entries.contains { $0.term.lowercased() == word } ?? false
}
```

`DictionaryView` injects both stores via `@EnvironmentObject`:
```swift
DictionaryView()
    .environmentObject(glossaryStore)
    .environmentObject(autoDictStore)
```

`DictationCoordinator` calls `autoDict.observe(transcript:)` after each successful insertion
(existing pipeline, unchanged).

---

## Unit tests

`SoroTests/AutoDictionaryStoreTests.swift` — class `AutoDictionarySuggestionFilterTests`:

- `testProperNounCapitalized` / `testAllCapsAcronym` / `testCamelCase` / `testSnakeCase` —
  verify the four jargon forms are accepted by `looksLikeJargonOrProperNoun`.
- `testSingleCharacterRejected` — length guard.
- `testCommonWordsRejected` / `testContractionsRejected` / `testLowercaseCommonWordsRejected` —
  confirm false-positive suppression.
- `testSuggestionThresholdGate` — occurrence count must reach threshold (2) before suggestion.
- `testCommonWordsNeverSuggested` — end-to-end: common words never appear in `suggestions()`.
- `testProperNounsAreSuggested` / `testCamelCaseJargonSuggested` / `testAcronymsSuggested` —
  end-to-end: correct tokens do appear.
- `testGlossaryTermsExcludedFromSuggestions` / `testNonGlossaryTermSuggested` — `isInGlossary`
  closure wiring.
- `testDismissedWordExcluded` / `testDismissCaseInsensitive` — dismiss gate.
- `testSuggestionsOrderedByFrequency` — sort order.
- `testMixedTranscriptOnlySurfacesProperNouns` — mixed transcript filters correctly.
- `testErrorSentinelNotObserved` — error-sentinel guard.
