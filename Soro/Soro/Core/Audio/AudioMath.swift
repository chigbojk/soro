import Foundation

/// Pure, testable DSP helpers for capture (brief §3a). No AVFoundation here so
/// these can be unit-tested headless (no mic).
enum AudioMath {

    /// Linear-interpolation resample of mono Float samples from `sourceRate` to
    /// `targetRate`. Deterministic and allocation-light; good enough for speech
    /// (whisper is tolerant, and we only ever downsample device rates → 16 kHz).
    ///
    /// - Returns the resampled buffer. Empty in → empty out. If the rates match
    ///   (or input has a single sample) the input is returned unchanged.
    static func resampleLinear(_ input: [Float],
                               from sourceRate: Double,
                               to targetRate: Double) -> [Float] {
        guard !input.isEmpty else { return [] }
        guard sourceRate > 0, targetRate > 0 else { return input }
        if sourceRate == targetRate || input.count == 1 { return input }

        let ratio = sourceRate / targetRate                 // input samples per output sample
        let outCount = Int((Double(input.count) / ratio).rounded(.down))
        guard outCount > 0 else { return [] }

        var out = [Float](repeating: 0, count: outCount)
        let lastIndex = input.count - 1
        for i in 0..<outCount {
            let srcPos = Double(i) * ratio
            let i0 = Int(srcPos.rounded(.down))
            if i0 >= lastIndex {
                out[i] = input[lastIndex]
            } else {
                let frac = Float(srcPos - Double(i0))
                out[i] = input[i0] * (1 - frac) + input[i0 + 1] * frac
            }
        }
        return out
    }

    /// Downmix an interleaved multi-channel Float buffer to mono by averaging
    /// channels. `channelCount == 1` returns the input unchanged.
    static func downmixToMono(_ interleaved: [Float], channels: Int) -> [Float] {
        guard channels > 1 else { return interleaved }
        let frames = interleaved.count / channels
        guard frames > 0 else { return [] }
        var out = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var sum: Float = 0
            let base = f * channels
            for c in 0..<channels { sum += interleaved[base + c] }
            out[f] = sum / Float(channels)
        }
        return out
    }

    /// RMS of a buffer, in linear amplitude (0…1-ish for normalized Float audio).
    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSq: Float = 0
        for s in samples { sumSq += s * s }
        return (sumSq / Float(samples.count)).squareRoot()
    }

    static func rms(_ samples: [Float]) -> Float { rms(samples[...]) }

    /// Map an RMS amplitude to a 0…1 mic level suitable for the waveform UI.
    /// Uses a dBFS mapping over a `floorDB…0` window so quiet/whispered speech
    /// still moves the meter (brief §5A "whisper-quiet input").
    static func micLevel(rms: Float, floorDB: Float = -60) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)                 // ≤ 0 dBFS
        if db <= floorDB { return 0 }
        if db >= 0 { return 1 }
        return (db - floorDB) / (0 - floorDB)     // linear in dB → 0…1
    }
}
