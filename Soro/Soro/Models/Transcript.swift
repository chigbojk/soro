import Foundation

/// One dictation record. Mirrors `Transcripts/<UUID>.json` (brief §6).
/// `date` is Cocoa epoch (seconds since 2001-01-01), `audioURL` a file:// URL string.
struct Transcript: Codable, Identifiable, Sendable {
    let id: UUID
    var text: String                  // "ERROR_TRANSCRIBING" sentinel on failure
    var audioURL: URL?                // nil when privacy mode deleted the audio
    var recordingDuration: TimeInterval
    var date: Double                  // Cocoa epoch: Date.timeIntervalSinceReferenceDate

    /// Sentinel `text` value written when transcription fails (Willow does this).
    static let errorSentinel = "ERROR_TRANSCRIBING"

    init(id: UUID = UUID(),
         text: String,
         audioURL: URL? = nil,
         recordingDuration: TimeInterval,
         date: Double = Date().timeIntervalSinceReferenceDate) {
        self.id = id
        self.text = text
        self.audioURL = audioURL
        self.recordingDuration = recordingDuration
        self.date = date
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, audioURL, recordingDuration, date
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        recordingDuration = try c.decode(TimeInterval.self, forKey: .recordingDuration)
        date = try c.decode(Double.self, forKey: .date)
        // audioURL encoded as a file:// URL *string*, matching Willow's schema.
        if let s = try c.decodeIfPresent(String.self, forKey: .audioURL), !s.isEmpty {
            audioURL = URL(string: s)
        } else {
            audioURL = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        try c.encode(recordingDuration, forKey: .recordingDuration)
        try c.encode(date, forKey: .date)
        // Encode as absolute file:// string (or omit when nil).
        try c.encodeIfPresent(audioURL?.absoluteString, forKey: .audioURL)
    }

    /// The Cocoa-epoch `date` converted to a `Date`.
    var timestamp: Date { Date(timeIntervalSinceReferenceDate: date) }
}
