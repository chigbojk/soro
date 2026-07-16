import Foundation

/// Per-context writing-style settings, mirroring
/// `Preferences/personalization_preferences.json` (brief §6/§5).
struct PersonalizationPreferences: Codable, Equatable {
    var workMessagingStyle: String
    var emailStyle: String
    var casualMessagingStyle: String
    var otherStyle: String

    var workScribeWritingStyle: String
    var emailScribeWritingStyle: String
    var casualScribeWritingStyle: String
    var otherScribeWritingStyle: String

    var workPersonalTweak: String
    var emailPersonalTweak: String
    var casualPersonalTweak: String
    var otherPersonalTweak: String

    static let `default` = PersonalizationPreferences(
        workMessagingStyle: "formal",
        emailStyle: "formal",
        casualMessagingStyle: "casual",
        otherStyle: "formal",
        workScribeWritingStyle: "natural",
        emailScribeWritingStyle: "natural",
        casualScribeWritingStyle: "natural",
        otherScribeWritingStyle: "natural",
        workPersonalTweak: "",
        emailPersonalTweak: "",
        casualPersonalTweak: "",
        otherPersonalTweak: ""
    )
}
