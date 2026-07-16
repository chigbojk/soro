import Foundation

/// Minimal canonical WAV (RIFF) encoder for 16 kHz mono audio (brief §3a).
/// Writes 16-bit signed PCM — small on disk and universally playable by
/// AVAudioPlayer / QuickTime, which the History UI uses for playback.
enum WAVEncoder {

    /// Encode mono Float samples (range roughly -1…1) as a 16-bit PCM WAV blob.
    static func encode(samples: [Float], sampleRate: Int = 16_000) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let byteRate = sampleRate * channels * bytesPerSample
        let blockAlign = channels * bytesPerSample
        let dataSize = samples.count * bytesPerSample
        let chunkSize = 36 + dataSize

        var data = Data(capacity: 44 + dataSize)

        func appendString(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func appendU32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func appendU16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }

        // RIFF header
        appendString("RIFF")
        appendU32(UInt32(chunkSize))
        appendString("WAVE")

        // fmt chunk
        appendString("fmt ")
        appendU32(16)                       // PCM fmt chunk size
        appendU16(1)                        // audio format = PCM
        appendU16(UInt16(channels))
        appendU32(UInt32(sampleRate))
        appendU32(UInt32(byteRate))
        appendU16(UInt16(blockAlign))
        appendU16(UInt16(bitsPerSample))

        // data chunk
        appendString("data")
        appendU32(UInt32(dataSize))
        data.reserveCapacity(data.count + dataSize)
        for s in samples {
            let clamped = max(-1, min(1, s))
            let scaled = clamped < 0 ? clamped * 32768 : clamped * 32767
            appendU16(UInt16(bitPattern: Int16(scaled.rounded())))
        }
        return data
    }
}
