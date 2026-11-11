import AVFoundation
import XCTest

/// A flat measurement record: ordered key → value, each value either compared exactly (by its description)
/// or numerically within a tolerance. Two records match when they have the same keys and every value matches.
struct Fields {
    enum Value {
        case exact(String)
        case num(Double, tol: Double)
    }
    private(set) var items: [(key: String, value: Value)] = []

    mutating func exact(_ key: String, _ value: Any?) {
        items.append((key, .exact(value.map { "\($0)" } ?? "nil")))
    }

    /// nil is recorded as an exact "nil" so nil vs value is a mismatch.
    mutating func num(_ key: String, _ value: Double?, tol: Double) {
        guard let v = value else { return exact(key, nil) }
        items.append((key, .num(v, tol: tol)))
    }

    mutating func merge(_ prefix: String, _ other: Fields) {
        for (k, v) in other.items { items.append((prefix + k, v)) }
    }

    /// (number of keys compared, human-readable mismatches)
    static func compare(_ a: Fields, _ b: Fields, names: (String, String) = ("current", "oracle")) -> (Int, [String]) {
        let (a, divergenceMismatches) = reconcileReverseLastFrame(a, b)
        var mismatches: [String] = divergenceMismatches
        let bByKey = Dictionary(b.items.map { ($0.key, $0.value) }, uniquingKeysWith: { x, _ in x })
        let aKeys = Set(a.items.map(\.key))
        for (k, va) in a.items {
            guard let vb = bByKey[k] else { mismatches.append("\(k): only in \(names.0) (\(va))"); continue }
            switch (va, vb) {
            case let (.exact(x), .exact(y)) where x == y: break
            case let (.num(x, t1), .num(y, t2)) where abs(x - y) <= max(t1, t2): break
            default: mismatches.append("\(k): \(names.0)=\(va) \(names.1)=\(vb)")
            }
        }
        for (k, vb) in b.items where !aKeys.contains(k) { mismatches.append("\(k): only in \(names.1) (\(vb))") }
        // the ±1 per-frame index tolerance is decode noise; a whole sequence off by one frame moves the mean to about ±1
        var shift: [Double] = []
        for (k, va) in a.items where index(k, prefix: "out.frames[", suffix: "].index") != nil {
            if case let .num(x, _) = va, case let .num(y, _)? = bByKey[k] { shift.append(x - y) }
        }
        if !shift.isEmpty {
            let mean = shift.reduce(0, +) / Double(shift.count)
            if abs(mean) > 0.5 { mismatches.append("out.frames[*].index: mean \(names.0) - \(names.1) = \(mean) (sequence shifted by a frame)") }
        }
        return (a.items.count, mismatches)
    }

    // MARK: intended divergence from the oracle

    static let reverseKind = "reverse"

    /// KIOS-10596: the frozen ObjC oracle never writes the source's last frame when reversing (its last pass reads the
    /// half-open range [lastPassStart, lastSamplePTS)); the current implementation does. For a reverse record (`kind`)
    /// whose output has exactly one frame more than the oracle's, this checks the expected deltas and rewrites `a`
    /// into the oracle's shape so every other key is still compared unchanged:
    /// - output frame 0 is one source frame later than the oracle's first (the source's last frame); the rest line up after dropping it,
    /// - one more "Reversing Video" progress step, the last one at 1.0 (oracle: N-1 of N),
    /// - video track and last frame PTS one frame (1 / fps) longer; file duration either equal (longer audio) or one frame longer.
    /// Returns the rewritten record and any violated expectation (as mismatches). Records that don't fit are returned as is.
    static func reconcileReverseLastFrame(_ a: Fields, _ b: Fields) -> (Fields, [String]) {
        guard a.exactValue("kind") == reverseKind, b.exactValue("kind") == reverseKind,
              let an = a.exactValue("out.frames.count").flatMap(Int.init),
              let bn = b.exactValue("out.frames.count").flatMap(Int.init) else { return (a, []) }
        guard an == bn + 1 else {
            // both succeeded with output: the extra frame must be there (catches the old drop coming back)
            let bothOk = a.exactValue("ok") == "true" && b.exactValue("ok") == "true" && an > 0
            return (a, bothOk ? ["KIOS-10596 expected divergence: frames.count current=\(an) oracle=\(bn) (want oracle + 1)"] : [])
        }
        var problems: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { problems.append("KIOS-10596 expected divergence: \(what)") } }

        if bn > 0, let a0 = a.numValue("out.frames[0].index"), let b0 = b.numValue("out.frames[0].index") {
            expect(abs(a0 - (b0 + 1)) <= Tol.frameIndex, "frames[0].index current=\(a0) oracle=\(b0) (want oracle + 1)")
        }

        // progress: the extra "Reversing Video" step
        var dropProgress: Int? = nil
        let aRev = a.progressIndexes(op: "Reversing Video"), bRev = b.progressIndexes(op: "Reversing Video")
        if !aRev.isEmpty || !bRev.isEmpty {
            expect(aRev.count == bRev.count + 1, "Reversing Video steps current=\(aRev.count) oracle=\(bRev.count) (want oracle + 1)")
            if aRev.count == bRev.count + 1, let j = aRev.last {
                expect(abs((a.numValue("progress[\(j)].value") ?? -1) - 1.0) <= Tol.progress, "last Reversing Video value is not 1.0")
                dropProgress = j
            }
        }

        let fps = a.numValue("out.video[0].fps") ?? 0
        let frame = fps > 0 ? 1 / fps : 0
        var replace: [String: Double] = [:]
        for (k, strict) in [("out.frames.last.pts", true), ("out.video[0].trackDuration", true), ("out.duration", false)] {
            guard let x = a.numValue(k), let y = b.numValue(k) else { continue }
            if abs(x - y - frame) <= Tol.seconds {
                replace[k] = y
            } else {
                expect(!strict && abs(x - y) <= Tol.seconds, "\(k) current=\(x) oracle=\(y) (want oracle + \(frame))")
            }
        }

        var out = Fields()
        for (k, v) in a.items {
            if k == "out.frames.count" { out.items.append((k, .exact("\(bn)"))); continue }
            if let i = Self.index(k, prefix: "out.frames[", suffix: "].index") {
                if i > 0 { out.items.append(("out.frames[\(i - 1)].index", v)) }
                continue
            }
            if let j = dropProgress {
                if k == "progress.count", let n = a.exactValue(k).flatMap(Int.init) { out.items.append((k, .exact("\(n - 1)"))); continue }
                if let i = Self.index(k, prefix: "progress[", suffix: "].op") ?? Self.index(k, prefix: "progress[", suffix: "].value") {
                    if i == j { continue }
                    if i > j { out.items.append((k.replacingOccurrences(of: "progress[\(i)]", with: "progress[\(i - 1)]"), v)); continue }
                }
            }
            if let y = replace[k], case let .num(_, tol) = v { out.items.append((k, .num(y, tol: tol))); continue }
            out.items.append((k, v))
        }
        return (out, problems)
    }

    private static func index(_ key: String, prefix: String, suffix: String) -> Int? {
        guard key.hasPrefix(prefix), key.hasSuffix(suffix) else { return nil }
        return Int(key.dropFirst(prefix.count).dropLast(suffix.count))
    }

    private func exactValue(_ key: String) -> String? {
        guard let v = items.first(where: { $0.key == key })?.value, case let .exact(s) = v else { return nil }
        return s
    }

    private func numValue(_ key: String) -> Double? {
        guard let v = items.first(where: { $0.key == key })?.value, case let .num(x, _) = v else { return nil }
        return x
    }

    private func progressIndexes(op: String) -> [Int] {
        items.compactMap { k, v in
            guard let i = Self.index(k, prefix: "progress[", suffix: "].op"), case let .exact(s) = v, s == op else { return nil }
            return i
        }
    }
}

extension Fields.Value: CustomStringConvertible {
    var description: String {
        switch self {
        case .exact(let s): return s
        case .num(let v, _): return String(format: "%.5g", v)
        }
    }
}

/// Tolerances between two runs of (supposedly) identical code. Tighter than the absolute expectations of the
/// pinned tests; they only absorb decoder / encoder noise.
enum Tol {
    static let seconds = 0.02
    static let edge = 0.03          // onset / offset
    static let amplitude = 0.03
    static let level = 0.02         // rms
    static let peak = 0.05
    static let pixel = 12.0
    static let frameIndex = 1.0     // ±1 decode noise, same as the pinned tests
    static let fps = 0.5
    static let progress = 1e-4
}

enum Record {
    /// Callback contract of one run. `progress: false` skips the progress shape (for timing-dependent runs such as a
    /// cancel triggered from the first progress callback).
    static func outcome(_ o: Outcome, impl: Impl, progress: Bool = true) -> Fields {
        var f = Fields()
        f.exact("ok", o.succeeded)
        f.exact("error.domain", o.error.map { $0.domain == impl.errorDomain ? "<TR domain>" : $0.domain })
        f.exact("error.code", o.error?.code)
        f.exact("error.description", o.error?.localizedDescription)
        f.exact("completion.count", o.completionCount)
        f.exact("completion.onMain", o.completionOnMainThread)
        f.exact("completion.sync", o.completedSynchronously)
        guard progress else { return f }
        let p = o.progress
        f.exact("progress.count", p.count)
        f.exact("progress.allOnMain", p.allSatisfy(\.onMain))
        f.exact("progress.monotonic", zip(p, p.dropFirst()).allSatisfy { $0.value <= $1.value })
        var ops: [String] = []
        for x in p where ops.last != x.operation { ops.append(x.operation) }
        f.exact("progress.ops", ops)
        for (i, x) in p.enumerated() {
            f.exact("progress[\(i)].op", x.operation)
            f.num("progress[\(i)].value", Double(x.value), tol: Tol.progress)
        }
        return f
    }

    /// Everything the pinned tests measure on a produced file (and a bit more: every frame index, every track).
    static func file(_ url: URL) -> Fields {
        var f = Fields()
        let exists = FileManager.default.fileExists(atPath: url.path)
        f.exact("exists", exists)
        guard exists else { return f }
        f.num("duration", Measure.duration(url), tol: Tol.seconds)

        let videos = Measure.videoTracks(url)
        f.exact("video.count", videos.count)
        for (i, v) in videos.enumerated() {
            let k = "video[\(i)]."
            f.exact(k + "size", v.naturalSize)
            f.exact(k + "codec", v.codec)
            f.exact(k + "rotation", v.rotationDegrees)
            f.exact(k + "alpha", v.containsAlpha)
            f.num(k + "fps", Double(v.nominalFPS), tol: Tol.fps)
            f.num(k + "start", v.timeRange.start.seconds, tol: Tol.seconds)
            f.num(k + "trackDuration", v.timeRange.duration.seconds, tol: Tol.seconds)
        }
        let frames = Measure.frames(url)
        f.exact("frames.count", frames.count)
        for (i, fr) in frames.enumerated() {
            f.num("frames[\(i)].index", Double(fr.index), tol: Tol.frameIndex)
        }
        if let first = frames.first {
            f.num("frames.first.pts", first.pts, tol: 0.005)
            f.num("frames.first.r", first.top.r, tol: Tol.pixel)
            f.num("frames.first.g", first.top.g, tol: Tol.pixel)
            f.num("frames.first.b", first.top.b, tol: Tol.pixel)
            f.num("frames.first.a", first.top.a, tol: Tol.pixel)
            f.num("frames.first.topRightAlpha", first.topRightAlpha, tol: Tol.pixel)
        }
        if let last = frames.last { f.num("frames.last.pts", last.pts, tol: 0.005) }

        let audioCount = Measure.audioTrackCount(url)
        f.exact("audio.count", audioCount)
        for i in 0..<audioCount {
            let k = "audio[\(i)]."
            guard let a = Measure.audio(url, track: i) else { f.exact(k + "decoded", false); continue }
            f.num(k + "duration", a.duration, tol: Tol.seconds)
            f.num(k + "rms", a.rms, tol: Tol.level)
            f.num(k + "peak", a.peak, tol: Tol.peak)
            f.num(k + "onset", a.onset, tol: Tol.edge)
            f.num(k + "offset", a.offset, tol: Tol.edge)
            f.num(k + "amp440", a.amp440, tol: Tol.amplitude)
            f.num(k + "amp1000", a.amp1000, tol: Tol.amplitude)
        }
        return f
    }

    /// 440 / 1000 Hz amplitude in fixed windows of the decoded audio timeline (sample-order check).
    static func audioWindows(_ url: URL, windows: [(Double, Double)]) -> Fields {
        var f = Fields()
        guard let x = Measure.timeline(url) else { f.exact("timeline", nil); return f }
        let r = Measure.audioRate
        for (s, e) in windows {
            let lo = min(x.count, Int(s * r)), hi = min(x.count, Int(e * r))
            let seg = Array(x[lo..<hi])
            f.num("window[\(s)-\(e)].amp440", Measure.goertzelAmplitude(seg, frequency: 440, rate: r), tol: Tol.amplitude)
            f.num("window[\(s)-\(e)].amp1000", Measure.goertzelAmplitude(seg, frequency: 1000, rate: r), tol: Tol.amplitude)
        }
        return f
    }
}
