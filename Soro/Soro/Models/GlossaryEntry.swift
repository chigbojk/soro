import Foundation

/// One personal-dictionary entry. Mirrors an element of `Preferences/glossary.json` (brief §6/§3c).
/// `isReplacement:false` → a term to recognize/case-correct.
/// `isReplacement:true`  → a spoken-phrase → expanded-text shortcut (uses `replacement`).
struct GlossaryEntry: Codable, Identifiable, Sendable {
    let id: UUID
    var term: String
    var tag: String                   // "My Terms" | "Auto-Learned"
    var isEnabled: Bool
    var isReplacement: Bool
    var replacement: String?          // present when isReplacement == true

    init(id: UUID = UUID(),
         term: String,
         tag: String = "My Terms",
         isEnabled: Bool = true,
         isReplacement: Bool = false,
         replacement: String? = nil) {
        self.id = id
        self.term = term
        self.tag = tag
        self.isEnabled = isEnabled
        self.isReplacement = isReplacement
        self.replacement = replacement
    }
}
