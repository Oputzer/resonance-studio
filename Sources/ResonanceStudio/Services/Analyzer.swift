import Accelerate
import Foundation

/// Tempo and musical key of a song, worked out from the audio itself.
struct AudioAnalysis: Codable, Hashable {
    var bpm: Double
    var camelot: String        // e.g. "8A"
    var keyName: String        // e.g. "A minor"
    var keyConfidence: Double  // 0...1, how clearly one key stood out
    /// The tempo as detected, before the BPM range setting is applied.
    var autoBPM: Double?
}

/// Which octave BPMs are shown in. Half and double tempo are the same pulse, so DJ software
/// lets you pick the range, e.g. a 65 BPM lofi song can read as 65 or 130.
enum TempoRange: String, CaseIterable, Identifiable {
    case automatic, slow, standard, fast
    var id: String { rawValue }

    static var current: TempoRange {
        TempoRange(rawValue: UserDefaults.standard.string(forKey: "tempoRange") ?? "") ?? .automatic
    }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .slow: return "60–120 (hip-hop, lofi, downtempo)"
        case .standard: return "78–156 (house, techno)"
        case .fast: return "88–176 (techno, drum & bass)"
        }
    }

    var bounds: (low: Double, high: Double)? {
        switch self {
        case .automatic: return nil
        case .slow: return (60, 120)
        case .standard: return (78, 156)
        case .fast: return (88, 176)
        }
    }

    func fold(_ bpm: Double) -> Double {
        guard let (low, high) = bounds, bpm > 0 else { return bpm }
        var b = bpm
        while b < low { b *= 2 }
        while b >= high { b /= 2 }
        return b == b.rounded() ? b : (b * 10).rounded() / 10
    }
}

/// BPM and key detection.
///
/// BPM: spectral-flux onset envelope → autocorrelation comb over 1–4 beats to find the
/// tempo family → a long-range pulse alignment over the whole excerpt for precision.
/// Key: chromagram matched against major/minor key profiles.
enum Analyzer {
    /// Bump when the algorithm changes so existing songs get re-analyzed.
    static let version = 1

    static let sampleRate: Float = 22_050
    /// Long songs and DJ mixes: analyze an 8-minute excerpt instead of the whole file.
    static let maxSeconds = 480.0

    static func analyze(file: URL, duration: Double?, ffmpeg: URL) async throws -> AudioAnalysis {
        var args = ["-v", "error", "-nostdin"]
        if let d = duration, d > maxSeconds + 30 {
            args += ["-ss", String(format: "%.1f", min(d * 0.1, d - maxSeconds))]
        }
        args += ["-i", file.path, "-t", String(Int(maxSeconds)), "-vn", "-ac", "1",
                 "-ar", String(Int(sampleRate)), "-f", "f32le", "-"]
        let r = try await Shell.run(ffmpeg, args, env: ProcessInfo.processInfo.environment)
        guard r.status == 0, r.out.count >= Int(sampleRate) * 4 * 8 else {
            throw AppError("Couldn't read the audio for analysis.")
        }
        let samples: [Float] = r.out.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return await Task.detached(priority: .utility) { compute(samples) }.value
    }

    static func compute(_ samples: [Float]) -> AudioAnalysis {
        let bpm = detectBPM(samples)
        let key = detectKey(samples)
        return AudioAnalysis(bpm: TempoRange.current.fold(bpm), camelot: key.camelot, keyName: key.name,
                             keyConfidence: key.confidence, autoBPM: bpm)
    }

    // MARK: - BPM

    static func detectBPM(_ x: [Float]) -> Double {
        let n = 1024, hop = 256
        let fps = Double(sampleRate) / Double(hop)
        let env = onsetEnvelope(x, n: n, hop: hop)
        guard env.count > Int(fps * 8) else { return 0 }

        // Autocorrelation up to 4 beats at 60 BPM.
        let maxLag = Int(fps * 4) + 4
        var acf = [Float](repeating: 0, count: maxLag + 2)
        env.withUnsafeBufferPointer { e in
            for lag in 1...maxLag + 1 where lag < env.count {
                var s: Float = 0
                vDSP_dotpr(e.baseAddress!, 1, e.baseAddress! + lag, 1, &s, vDSP_Length(env.count - lag))
                acf[lag] = s / Float(env.count - lag)
            }
        }
        func acfAt(_ lag: Double) -> Double {
            let i = Int(lag), f = lag - Double(i)
            guard i + 1 < acf.count else { return 0 }
            return Double(acf[i]) * (1 - f) + Double(acf[i + 1]) * f
        }
        func comb(_ bpm: Double) -> Double {
            let period = fps * 60 / bpm
            return (1...4).reduce(0) { $0 + acfAt(period * Double($1)) }
        }
        // A gentle preference for common dance-music tempos to settle half/double ambiguity.
        func prior(_ bpm: Double) -> Double { exp(-0.5 * pow(log2(bpm / 122) / 0.9, 2)) }

        var best = 120.0, bestScore = -Double.infinity
        var bpm = 70.0
        while bpm <= 185 {
            let s = comb(bpm) * prior(bpm)
            if s > bestScore { bestScore = s; best = bpm }
            bpm += 0.05
        }

        // Refine: the tempo whose beat grid lines up best with onsets across the whole excerpt.
        func alignment(_ bpm: Double) -> Double {
            let period = fps * 60 / bpm
            let steps = max(1, Int(period.rounded()))
            var bestPhase = 0.0
            env.withUnsafeBufferPointer { e in
                for p in 0..<steps {
                    var pos = Double(p), sum = 0.0
                    while pos < Double(e.count - 1) {
                        let i = Int(pos), f = pos - Double(i)
                        sum += Double(e[i]) * (1 - f) + Double(e[i + 1]) * f
                        pos += period
                    }
                    bestPhase = max(bestPhase, sum)
                }
            }
            return bestPhase / (Double(env.count) / period)
        }
        var refined = best, refinedScore = -Double.infinity
        var c = best - 1.0
        while c <= best + 1.0 {
            let s = alignment(c)
            if s > refinedScore { refinedScore = s; refined = c }
            c += 0.02
        }
        // Most produced music sits on a whole-number tempo.
        let whole = refined.rounded()
        if abs(refined - whole) <= 0.25 { return whole }
        return (refined * 10).rounded() / 10
    }

    /// Positive change in log-magnitude spectrum per frame, with the slow trend removed.
    static func onsetEnvelope(_ x: [Float], n: Int, hop: Int) -> [Float] {
        let fft = MagnitudeFFT(size: n)
        let bins = n / 2
        let maxBin = min(bins, Int(8_000 / (sampleRate / Float(n))))
        let frames = (x.count - n) / hop
        guard frames > 2 else { return [] }
        var prev = [Float](repeating: 0, count: bins)
        var cur = [Float](repeating: 0, count: bins)
        var diff = [Float](repeating: 0, count: bins)
        var env = [Float](repeating: 0, count: frames)
        x.withUnsafeBufferPointer { xp in
            for f in 0..<frames {
                fft.magnitudes(xp.baseAddress! + f * hop, into: &cur)
                var count = Int32(bins)
                vvlog1pf(&cur, cur, &count)
                vDSP_vsub(prev, 1, cur, 1, &diff, 1, vDSP_Length(maxBin))   // cur - prev
                var zero: Float = 0
                vDSP_vthres(diff, 1, &zero, &diff, 1, vDSP_Length(maxBin))
                var s: Float = 0
                vDSP_sve(diff, 1, &s, vDSP_Length(maxBin))
                env[f] = f == 0 ? 0 : s
                swap(&prev, &cur)
            }
        }
        // Subtract a ~0.5 s moving average and keep only the peaks above it.
        let w = max(1, Int(Float(sampleRate) / Float(hop) * 0.5))
        var cumulative = [Double](repeating: 0, count: frames + 1)
        for i in 0..<frames { cumulative[i + 1] = cumulative[i] + Double(env[i]) }
        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let a = max(0, i - w / 2), b = min(frames, i + w / 2 + 1)
            let mean = (cumulative[b] - cumulative[a]) / Double(b - a)
            out[i] = max(0, env[i] - Float(mean))
        }
        var mean: Float = 0, sd: Float = 0
        vDSP_normalize(out, 1, nil, 1, &mean, &sd, vDSP_Length(frames))
        if sd > 0 { var s = 1 / sd; vDSP_vsmul(out, 1, &s, &out, 1, vDSP_Length(frames)) }
        return out
    }

    // MARK: - Key

    static let pitchNames = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    static let minorPitchNames = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "G#", "A", "Bb", "B"]
    /// Camelot number for a major key, indexed by its tonic pitch class.
    static let camelotMajor = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1]

    // Temperley key profiles.
    static let majorProfile: [Double] = [0.748, 0.060, 0.488, 0.082, 0.670, 0.460, 0.096, 0.715, 0.104, 0.366, 0.057, 0.400]
    static let minorProfile: [Double] = [0.712, 0.084, 0.474, 0.618, 0.049, 0.460, 0.105, 0.747, 0.404, 0.067, 0.133, 0.330]

    static func detectKey(_ x: [Float]) -> (camelot: String, name: String, confidence: Double) {
        let chroma = chromagram(x)
        var scores: [(score: Double, pc: Int, minor: Bool)] = []
        for pc in 0..<12 {
            scores.append((pearson(chroma, rotated(majorProfile, by: pc)), pc, false))
            scores.append((pearson(chroma, rotated(minorProfile, by: pc)), pc, true))
        }
        scores.sort { $0.score > $1.score }
        let top = scores[0], second = scores[1]
        let number = top.minor ? camelotMajor[(top.pc + 3) % 12] : camelotMajor[top.pc]
        let name = top.minor ? "\(minorPitchNames[top.pc]) minor" : "\(pitchNames[top.pc]) major"
        let confidence = max(0, min(1, (top.score - second.score) * 5))
        return ("\(number)\(top.minor ? "A" : "B")", name, confidence)
    }

    static func chromagram(_ x: [Float]) -> [Double] {
        let n = 8192, hop = 4096
        let fft = MagnitudeFFT(size: n)
        let bins = n / 2
        let binHz = Double(sampleRate) / Double(n)
        // Precompute each bin's pitch class and how close it sits to a semitone centre.
        var pcOf = [Int](repeating: -1, count: bins)
        var weight = [Double](repeating: 0, count: bins)
        for k in 1..<bins {
            let f = Double(k) * binHz
            guard f >= 55, f <= 1_760 else { continue }
            let midi = 69 + 12 * log2(f / 440)
            let nearest = midi.rounded()
            pcOf[k] = ((Int(nearest) % 12) + 12) % 12
            weight[k] = exp(-pow(midi - nearest, 2) / (2 * 0.25 * 0.25))
        }
        var mags = [Float](repeating: 0, count: bins)
        var total = [Double](repeating: 0, count: 12)
        let frames = (x.count - n) / hop
        guard frames > 0 else { return total }
        x.withUnsafeBufferPointer { xp in
            for f in 0..<frames {
                fft.magnitudes(xp.baseAddress! + f * hop, into: &mags)
                var frame = [Double](repeating: 0, count: 12)
                for k in 1..<bins where pcOf[k] >= 0 {
                    frame[pcOf[k]] += Double(mags[k]).squareRoot() * weight[k]
                }
                let peak = frame.max() ?? 0
                guard peak > 1e-6 else { continue }
                for i in 0..<12 { total[i] += frame[i] / peak }
            }
        }
        return total
    }

    private static func rotated(_ p: [Double], by k: Int) -> [Double] {
        (0..<12).map { p[(($0 - k) % 12 + 12) % 12] }
    }

    private static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let ma = a.reduce(0, +) / 12, mb = b.reduce(0, +) / 12
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<12 {
            num += (a[i] - ma) * (b[i] - mb)
            da += (a[i] - ma) * (a[i] - ma)
            db += (b[i] - mb) * (b[i] - mb)
        }
        return da > 0 && db > 0 ? num / (da * db).squareRoot() : 0
    }

    // MARK: - Harmonic mixing

    /// Keys that mix smoothly: same key, one step around the Camelot wheel, or the relative major/minor.
    static func isCompatible(_ a: String?, _ b: String?) -> Bool {
        guard let a = parseCamelot(a), let b = parseCamelot(b) else { return false }
        if a == b { return true }
        if a.number == b.number { return true }
        guard a.minor == b.minor else { return false }
        let d = abs(a.number - b.number)
        return d == 1 || d == 11
    }

    static func parseCamelot(_ s: String?) -> (number: Int, minor: Bool)? {
        guard let s, let last = s.last, last == "A" || last == "B", let n = Int(s.dropLast()), (1...12).contains(n) else { return nil }
        return (n, last == "A")
    }

    /// Sort position around the wheel: 1A, 1B, 2A, 2B…
    static func camelotOrder(_ s: String?) -> Int {
        guard let c = parseCamelot(s) else { return 999 }
        return c.number * 2 + (c.minor ? 0 : 1)
    }
}

/// Windowed real FFT returning magnitudes for bins 0..<size/2.
final class MagnitudeFFT {
    let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]
    private var buffer: [Float]
    private var real: [Float]
    private var imag: [Float]

    init(size: Int) {
        self.size = size
        log2n = vDSP_Length(log2(Double(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        buffer = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imag = [Float](repeating: 0, count: size / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func magnitudes(_ samples: UnsafePointer<Float>, into out: inout [Float]) {
        vDSP_vmul(samples, 1, window, 1, &buffer, 1, vDSP_Length(size))
        let half = size / 2
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                buffer.withUnsafeBufferPointer { bp in
                    bp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                split.imagp[0] = 0   // packed Nyquist value, not part of bin 0
                out.withUnsafeMutableBufferPointer { op in
                    vDSP_zvabs(&split, 1, op.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }
    }
}
