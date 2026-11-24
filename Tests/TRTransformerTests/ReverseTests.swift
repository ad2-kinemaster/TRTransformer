import AVFoundation
@testable import TRTransformer
import XCTest

/// ILABReverseVideoExportSession output, measured from the produced file. Source: `Fixture.multiStream` unless noted.
final class ReverseTests: TRTestCase {

    // MARK: stream selection

    /// Legacy init `init(asset:timeRange:outputURL:)` (what the app calls): video stream 0 reversed, audio stream 0 ONLY (never mixed).
    func testLegacyInit_reversesVideo0_andUsesAudioStream0Only() throws {
        let src = try makeSource(Fixture.multiStream)
        let (o, out) = reverse(src)
        log("R legacy", out)
        XCTAssertTrue(o.succeeded, describe(o)); XCTAssertEqual(o.completionCount, 1)

        let v = try XCTUnwrap(Measure.videoTracks(out).first)
        XCTAssertEqual(Measure.videoTracks(out).count, 1)
        XCTAssertEqual(v.naturalSize, CGSize(width: 320, height: 240))
        XCTAssertEqual(v.codec, "avc1")
        assertColor(out, Fixture.red)
        assertReversedFrames(out, count: 60)
        XCTAssertEqual(Measure.duration(out), 3.0, accuracy: 0.02, "60 frames @ 20 fps")

        XCTAssertEqual(Measure.audioTrackCount(out), 1)
        let a = try XCTUnwrap(Measure.audio(out))
        XCTAssertEqual(a.amp440, 0.2, accuracy: 0.05, "stream 0")
        XCTAssertLessThan(a.amp1000, 0.02, "stream 1 not mixed in")
    }

    func testIndexedInit_video1_audio1_usesOnlyThoseStreams() throws {
        let src = try makeSource(Fixture.multiStream)
        let (o, out) = reverse(src, video: 1, audio: 1)
        log("R v1 a1", out)
        XCTAssertTrue(o.succeeded, describe(o)); XCTAssertEqual(o.completionCount, 1)

        let v = try XCTUnwrap(Measure.videoTracks(out).first)
        XCTAssertEqual(v.naturalSize, CGSize(width: 240, height: 160))
        XCTAssertEqual(v.rotationDegrees, 90, "preferredTransform of the selected stream is kept")
        assertColor(out, Fixture.green)
        assertReversedFrames(out, count: 60)

        XCTAssertEqual(Measure.audioTrackCount(out), 1)
        let a = try XCTUnwrap(Measure.audio(out))
        XCTAssertLessThan(a.amp440, 0.02, "stream 0 absent")
        XCTAssertGreaterThan(a.amp1000, 0.3, "stream 1 only")
    }

    func testIndexedInit_video2_audio0() throws {
        let src = try makeSource(Fixture.multiStream)
        let (o, out) = reverse(src, video: 2, audio: 0)
        log("R v2 a0", out)
        XCTAssertTrue(o.succeeded, describe(o))
        XCTAssertEqual(Measure.videoTracks(out).first?.naturalSize, CGSize(width: 160, height: 96))
        assertColor(out, Fixture.blue)
        let a = try XCTUnwrap(Measure.audio(out))
        XCTAssertEqual(a.amp440, 0.2, accuracy: 0.05)
        XCTAssertLessThan(a.amp1000, 0.02)
    }

    /// ILABAudioTrackIndexAll is treated as stream 0 for reverse (no mixing).
    func testIndexedInit_audioAll_usesStream0() throws {
        let src = try makeSource(Fixture.multiStream)
        let (o, out) = reverse(src, video: 0, audio: ILABAudioTrackIndexAll)
        log("R all", out)
        XCTAssertTrue(o.succeeded, describe(o))
        XCTAssertEqual(Measure.audioTrackCount(out), 1)
        let a = try XCTUnwrap(Measure.audio(out))
        XCTAssertEqual(a.amp440, 0.2, accuracy: 0.05)
        XCTAssertLessThan(a.amp1000, 0.02)
    }

    // MARK: invalid indexes / no audio

    func testOutOfRangeIndexes_failWithInvalidTrackIndex_once() throws {
        let src = try makeSource(Fixture.multiStream)
        for (v, a) in [(3, 0), (-1, 0), (0, 2), (0, -2), (0, 5)] {
            let (o, out) = reverse(src, video: v, audio: a, out: "bad-\(v)-\(a).mov")
            XCTAssertFalse(o.succeeded, "v=\(v) a=\(a)")
            XCTAssertEqual(o.error?.code, ILABSessionErrorInvalidTrackIndex.rawValue, "v=\(v) a=\(a): \(describe(o))")
            XCTAssertEqual(o.completionCount, 1, "v=\(v) a=\(a)")
            XCTAssertTrue(o.completedSynchronously)
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        }
    }

    func testSourceWithoutAudio_ignoresAudioIndex() throws {
        let src = try makeSource(Fixture.videoOnly)
        for a in [0, 5, ILABAudioTrackIndexAll, -7] {
            let (o, out) = reverse(src, video: 0, audio: a, out: "noaudio\(a).mov")
            XCTAssertTrue(o.succeeded, "a=\(a): \(describe(o))")
            XCTAssertEqual(o.completionCount, 1)
            XCTAssertEqual(Measure.audioTrackCount(out), 0, "a=\(a)")
            assertReversedFrames(out, count: 60)
        }
    }

    // MARK: time range

    func testTimeRange_reversesOnlyTheRange() throws {
        let src = try makeSource(Fixture.multiStream)
        let range = CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: CMTime(value: 1, timescale: 1))
        let (o, out) = reverse(src, video: 0, audio: 0, range: range)
        log("R trim 1..2", out)
        XCTAssertTrue(o.succeeded, describe(o))
        XCTAssertEqual(Measure.duration(out), 1.0, accuracy: 0.1)
        assertReversedFrames(out, count: 20, firstSourceFrame: 20)
    }

    // MARK: last frame (KIOS-10596)

    /// Every source frame is written, the source's last frame first, across the 40-frame pass boundaries:
    /// 41 = a 1-frame last pass (was zero-length and skipped), 40 = exactly one full pass, 1 = single frame.
    func testWritesEverySourceFrame_acrossPassBoundaries() throws {
        for n in [41, 40, 1] {
            var spec = Fixture.videoOnly
            spec.frames = n
            let src = try makeSource(spec, name: "src\(n).mov")
            let (o, out) = reverse(src, out: "out\(n).mov")
            log("R \(n) frames", out)
            XCTAssertTrue(o.succeeded, "\(n) frames: \(describe(o))")
            assertReversedFrames(out, count: n, label: "\(n) frames")
        }
    }

    /// Same with a non-zero range start ending on a 1-frame last pass: source frames 10...50 (41 frames).
    func testWritesEverySourceFrame_trimmedRange_oneFrameLastPass() throws {
        let src = try makeSource(Fixture.videoOnly)
        let range = CMTimeRange(start: CMTime(value: 10, timescale: 20), duration: CMTime(value: 41, timescale: 20))
        let (o, out) = reverse(src, range: range)
        log("R trim 10..50", out)
        XCTAssertTrue(o.succeeded, describe(o))
        assertReversedFrames(out, count: 41, firstSourceFrame: 10)
    }

    /// Past the source video track's end the composition yields an empty (black) sample; it must never be written.
    /// Video 60 frames (3.0 s) with longer audio, full range: 10 ms (camera files) and 1 s longer.
    func testVideoShorterThanAudio_fullRange_noEmptyFrame() throws {
        for audio in [3.01, 4.0] {
            var spec = Fixture.videoOnly
            spec.audios = [Fixture.Audio(frequency: 440, amplitude: 0.2, duration: audio)]
            let src = try makeSource(spec, name: "short\(audio).mov")
            let (o, out) = reverse(src, out: "short\(audio).mov")
            log("R audio \(audio)", out)
            XCTAssertTrue(o.succeeded, describe(o))
            assertReversedFrames(out, count: 60, label: "audio \(audio) s")
        }
    }

    /// Range ending past the last frame's end (the app's ms rounding: 1 ms over) or exactly at it: source frames 20...59.
    func testRangeEndAtOrPastVideoEnd_noEmptyFrame() throws {
        var spec = Fixture.videoOnly
        spec.audios = [Fixture.Audio(frequency: 440, amplitude: 0.2, duration: 3.5)]
        let src = try makeSource(spec)
        for end in [3001, 3000] {
            let range = CMTimeRange(start: CMTime(value: 1000, timescale: 1000), end: CMTime(value: CMTimeValue(end), timescale: 1000))
            let (o, out) = reverse(src, range: range, out: "end\(end).mov")
            log("R 1.000-\(end)", out)
            XCTAssertTrue(o.succeeded, describe(o))
            assertReversedFrames(out, count: 40, firstSourceFrame: 20, label: "end \(end) ms")
        }
    }

    /// Video starting 0.5 s late (leading empty edit), ending at 3.5 s, audio to 4.0 s: the reversal starts at the last
    /// real frame. PINNED (pre-existing): the leading empty sample is still written, as the last output frame.
    func testLateVideo_startsAtLastRealFrame() throws {
        let src = try makeLateVideoSource()
        let (o, out) = reverse(src)
        log("R late video", out)
        XCTAssertTrue(o.succeeded, describe(o))
        let f = Measure.frames(out)
        XCTAssertEqual(f.count, 61, "60 frames + the pre-existing leading empty sample")
        guard f.count == 61 else { return }
        for (i, fr) in f.prefix(60).enumerated() {
            XCTAssertEqual(fr.index, 59 - i, accuracy: 1, "source frame of output frame \(i)")
            XCTAssertGreaterThan(fr.top.r, 100, "output frame \(i) is not an empty (black) sample")
        }
        let meanError = f.prefix(60).enumerated().map { Double($1.index - (59 - $0)) }.reduce(0, +) / 60
        XCTAssertEqual(meanError, 0, accuracy: 0.5, "output not shifted by a frame")
        XCTAssertLessThan(f[60].top.r, 40, "PINNED: leading empty sample written last")
    }

    /// `Fixture.videoOnly` placed at 0.5 s in a .mov (empty edit before it) with a 4 s tone, via a passthrough export.
    private func makeLateVideoSource() throws -> URL {
        var spec = Fixture.videoOnly
        spec.audios = [Fixture.Audio(frequency: 440, amplitude: 0.2, duration: 4.0)]
        let base = AVURLAsset(url: try makeSource(spec, name: "late-base.mov"))
        let comp = AVMutableComposition()
        let v = try XCTUnwrap(comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        let a = try XCTUnwrap(comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        let half = CMTime(value: 1, timescale: 2)
        let bv = base.tracks(withMediaType: .video)[0], ba = base.tracks(withMediaType: .audio)[0]
        try v.insertTimeRange(bv.timeRange, of: bv, at: half)
        try a.insertTimeRange(ba.timeRange, of: ba, at: .zero)
        let out = url("late-video.mov")
        try? FileManager.default.removeItem(at: out)
        let ex = try XCTUnwrap(AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough))
        ex.outputURL = out
        ex.outputFileType = .mov
        let done = DispatchSemaphore(value: 0)
        ex.exportAsynchronously { done.signal() }
        done.wait()
        XCTAssertEqual(ex.status, .completed, String(describing: ex.error))
        let t = try XCTUnwrap(AVURLAsset(url: out).tracks(withMediaType: .video).first)
        XCTAssertEqual(t.segments.first?.isEmpty, true, "fixture: leading empty edit")
        return out
    }

    // MARK: non-IDR sync sample

    /// stss also lists a non-IDR frame (decode sample 11, ~0.5 s; the only IDR is sample 1): a pass read that starts after
    /// it fails to decode (-11821 / -12137). The pass is re-read from an earlier start on a new reader and every frame is
    /// still written once, in order. 40/pass: [2.0, 3.0) retried from 0. 15/pass: the last pass steps back (doubling)
    /// until 0 works; every later failing pass then reuses that start on its first retry read.
    func testNonIDRSyncSample_passReadFails_isRetriedFromEarlierStart() throws {
        let src = try makeNonIDRSyncSource()
        for perPass in [40, 15] {
            var session: ILABReverseVideoExportSession?
            let (o, out) = reverse(src, out: "nonidr\(perPass).mov") { $0.samplesPerPass = perPass; session = $0 }
            log("R non-IDR sync \(perPass)/pass", out)
            XCTAssertTrue(o.succeeded, "\(perPass)/pass: \(describe(o))")
            XCTAssertEqual(o.completionCount, 1)
            assertReversedFrames(out, count: 60, label: "\(perPass)/pass")

            let reads = try XCTUnwrap(session).retryReads
            print("[TRT] retry reads \(perPass)/pass: \(reads.map { String(format: "%.2f:%@", $0.start.seconds, $0.ok ? "ok" : "fail") })")
            guard let firstOK = reads.firstIndex(where: { $0.ok }) else { XCTFail("\(perPass)/pass: no retry succeeded"); continue }
            XCTAssertEqual(reads[firstOK].start.seconds, 0, accuracy: 0.001, "\(perPass)/pass: only 0 is before the fake sync")
            XCTAssertTrue(reads[..<firstOK].allSatisfy { !$0.ok && $0.start.seconds > 0 }, "\(perPass)/pass: earlier starts tried first")
            let later = reads[(firstOK + 1)...]
            XCTAssertTrue(later.allSatisfy { $0.ok && $0.start.seconds == 0 },
                          "\(perPass)/pass: later failing passes recover on the remembered start, one read each")
            if perPass == 15 {
                // passes start at 0, 0.75, 1.5, 2.25: 2.25 tries 1.5, 0.75, 0; then 1.5 and 0.75 retry from 0 once each
                XCTAssertEqual(reads.count, 5, "\(perPass)/pass")
            }
        }
    }

    /// 5/pass = 12 passes starting every 0.25 s; only 0 and 0.25 lie before the fake sync (0.5 s). The last pass (2.75)
    /// must step back by 1, 2, 4, 8 passes (2.5, 2.25, 1.75, 0.75) and then 0 — one pass at a time would read 2.0 third.
    func testNonIDRSyncSample_retryStepsBackByDoublingPassCount() throws {
        let src = try makeNonIDRSyncSource()
        var session: ILABReverseVideoExportSession?
        let (o, out) = reverse(src, out: "nonidr5.mov") { $0.samplesPerPass = 5; session = $0 }
        XCTAssertTrue(o.succeeded, describe(o))
        XCTAssertEqual(o.completionCount, 1)
        assertReversedFrames(out, count: 60, label: "5/pass")

        let reads = try XCTUnwrap(session).retryReads
        print("[TRT] retry reads 5/pass: \(reads.map { String(format: "%.2f:%@", $0.start.seconds, $0.ok ? "ok" : "fail") })")
        let first = Array(reads.prefix(5))
        XCTAssertEqual(first.count, 5)
        for (read, (start, ok)) in zip(first, [(2.5, false), (2.25, false), (1.75, false), (0.75, false), (0.0, true)]) {
            XCTAssertEqual(read.start.seconds, start, accuracy: 0.001, "doubling back from 2.75: \(reads)")
            XCTAssertEqual(read.ok, ok, "read from \(start)")
        }
        let later = reads.dropFirst(5)
        XCTAssertTrue(later.allSatisfy { $0.ok && $0.start.seconds == 0 }, "later passes reuse the remembered start: \(reads)")
        // passes 2.5 ... 0.75 fail (8); the one starting on the fake sync itself (0.5) may or may not
        XCTAssertTrue((8...9).contains(later.count), "one retry read per later failing pass: \(later.count)")
    }

    /// Real IDRs at 0 / 0.95 / 1.9 / 2.85 s and a fake sync at 1.5 s (decode sample 31). 5/pass: the 1.75 pass fails and recovers
    /// from a NON-zero start (1.25, on the 0.95 IDR), so the new reader's timeRange begins at 1.25 and every earlier pass
    /// (1.0 ... 0) is read by reset(forReadingTimeRanges:) outside that range. None may come back empty.
    func testNonIDRSyncSample_midFile_recoversFromNonZeroStart_earlierPassesStillRead() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("needs the hardware decoder (device or Mac Catalyst)")
        #endif
        var spec = Fixture.videoOnly
        spec.videos[0].keyFrameInterval = 20
        let src = try makeSource(spec, name: "nonidr-mid.mov")
        XCTAssertEqual(try syncFrames(src), [0, 19, 38, 57], "fixture: the encoder puts IDRs 19 frames apart")
        try Fixture.addSyncSample(31, to: src)

        var session: ILABReverseVideoExportSession?
        let (o, out) = reverse(src, out: "nonidr-mid5.mov") { $0.samplesPerPass = 5; session = $0 }
        XCTAssertTrue(o.succeeded, describe(o))
        XCTAssertEqual(o.completionCount, 1)
        assertReversedFrames(out, count: 60, label: "mid fake sync 5/pass")

        let reads = try XCTUnwrap(session).retryReads
        print("[TRT] retry reads mid 5/pass: \(reads.map { String(format: "%.2f:%@", $0.start.seconds, $0.ok ? "ok" : "fail") })")
        let firstOK = try XCTUnwrap(reads.first(where: { $0.ok }), "no retry succeeded: \(reads)")
        XCTAssertEqual(firstOK.start.seconds, 1.25, accuracy: 0.001, "recovered on a non-zero start: \(reads)")
        XCTAssertFalse(reads.contains { $0.start.seconds < 1.25 }, "never had to go back to 0: \(reads)")
    }

    /// Display-order frame indices of the first video track's sync samples (20 fps).
    private func syncFrames(_ url: URL) throws -> [Int] {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(asset.tracks(withMediaType: .video).first), outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frames: [Int] = []
        while let s = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(s) > 0 else { continue }
            let att = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: false) as? [[CFString: Any]]
            if !((att?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false) {
                frames.append(Int((CMSampleBufferGetPresentationTimeStamp(s).seconds * 20).rounded()))
            }
        }
        return frames.sorted()
    }

    /// Trimmed range [1.025, 2.5) (starts inside frame 20) after the non-IDR sync (~0.5 s): even composition time 0
    /// decodes from that sync and the analysis read fails. A lead-in composition from earlier in the source is read
    /// instead; the output must equal reversing the same range of the unpatched file, which itself takes no lead-in.
    func testNonIDRSyncSample_beforeTrimStart_leadIn_matchesCleanSource() throws {
        let clean = url("clean.mov")
        let src = try makeNonIDRSyncSource(cleanCopy: clean)
        let range = CMTimeRange(start: CMTime(value: 41, timescale: 40), end: CMTime(value: 5, timescale: 2))
        for perPass in [40, 15] {
            var cleanSession: ILABReverseVideoExportSession?
            let (co, cleanOut) = reverse(clean, range: range, out: "clean\(perPass).mov") { $0.samplesPerPass = perPass; cleanSession = $0 }
            log("R clean trim \(perPass)/pass", cleanOut)
            XCTAssertTrue(co.succeeded, "clean \(perPass)/pass: \(describe(co))")
            XCTAssertNil(try XCTUnwrap(cleanSession).leadIn, "clean source: no lead-in")
            XCTAssertTrue(try XCTUnwrap(cleanSession).retryReads.isEmpty, "clean source: no pass retry")

            var session: ILABReverseVideoExportSession?
            let (o, out) = reverse(src, range: range, out: "leadin\(perPass).mov") { $0.samplesPerPass = perPass; session = $0 }
            log("R non-IDR trim \(perPass)/pass", out)
            XCTAssertTrue(o.succeeded, "\(perPass)/pass: \(describe(o))")
            XCTAssertEqual(o.completionCount, 1)
            XCTAssertNotNil(try XCTUnwrap(session).leadIn, "\(perPass)/pass: lead-in used")
            XCTAssertTrue(o.progressValues.allSatisfy { $0 >= 0 && $0 <= 1 }, "\(perPass)/pass: progress in 0...1")

            let want = Measure.frames(cleanOut), got = Measure.frames(out)
            XCTAssertEqual(want.count, 30, "clean: straddling frame 20 + frames 21...49")
            XCTAssertEqual(got.count, want.count, "\(perPass)/pass: frame count")
            guard got.count == want.count, let first = got.first else { continue }
            XCTAssertEqual(first.pts, 0, accuracy: 0.0001, "\(perPass)/pass: starts at 0")
            XCTAssertEqual(first.index, 49, accuracy: 1, "\(perPass)/pass: last frame of the range first")
            for (i, (g, w)) in zip(got, want).enumerated() {
                XCTAssertEqual(g.pts, w.pts, accuracy: 0.0001, "\(perPass)/pass: pts of output frame \(i)")
                XCTAssertEqual(g.index, w.index, accuracy: 1, "\(perPass)/pass: source frame of output frame \(i)")
            }
            XCTAssertEqual(Measure.duration(out), Measure.duration(cleanOut), accuracy: 0.0001, "\(perPass)/pass: duration")
            assertNonIncreasing(got.map(\.index))
        }
    }

    /// `Fixture.videoOnly` with one IDR (key frame interval > clip) and decode sample 11 added to stss.
    /// Checks that a plain read from 1.0 s really fails to decode, so the tests above exercise the retry.
    private func makeNonIDRSyncSource(cleanCopy: URL? = nil) throws -> URL {
        #if targetEnvironment(simulator)
        // the simulator's software decoder conceals the missing references (garbage frames) instead of failing the read
        throw XCTSkip("needs the hardware decoder (device or Mac Catalyst)")
        #endif
        var spec = Fixture.videoOnly
        spec.videos[0].keyFrameInterval = 120
        let src = try makeSource(spec, name: "nonidr.mov")
        if let clean = cleanCopy { try FileManager.default.copyItem(at: src, to: clean) }
        try Fixture.addSyncSample(11, to: src)
        let asset = AVURLAsset(url: src)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(asset.tracks(withMediaType: .video).first),
                                              outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: CMTime(value: 1, timescale: 1))
        XCTAssertTrue(reader.startReading())
        while output.copyNextSampleBuffer() != nil {}
        XCTAssertEqual(reader.status, .failed, "fixture: a read starting after the non-IDR sync sample fails")
        XCTAssertEqual((reader.error as NSError?)?.code, AVError.Code.decodeFailed.rawValue, String(describing: reader.error))
        return src
    }

    // MARK: pinned bugs

    /// PINNED BUG (a): the late tone (0.5...1.5 s in a 3 s clip) should land at 1.5...2.5 s after reversing;
    /// the reversed audio is instead pulled to start at 0 s.
    func testPinnedBug_lateAudio_reversedAudioStartsAtZero() throws {
        let src = try makeSource(Fixture.lateAudio)
        let srcAudio = try XCTUnwrap(Measure.audio(src))
        XCTAssertEqual(try XCTUnwrap(srcAudio.onset), 0.5, accuracy: 0.06, "fixture: tone starts late")

        let (o, out) = reverse(src)
        log("R late audio", out)
        XCTAssertTrue(o.succeeded, describe(o))
        XCTAssertEqual(Measure.duration(out), 3.0, accuracy: 0.02)
        let a = try XCTUnwrap(Measure.audio(out))
        XCTAssertEqual(a.duration, 1.45, accuracy: 0.06, "audio track only as long as the stream's media end (1.5 s), not the clip")
        XCTAssertEqual(try XCTUnwrap(a.onset), 0.0, accuracy: 0.06, "PINNED BUG: correct would be 1.5 s")
        XCTAssertEqual(try XCTUnwrap(a.offset), 1.0, accuracy: 0.08, "PINNED BUG: correct would be 2.5 s")
        XCTAssertGreaterThan(a.amp1000, 0.3)
    }

    /// Same pinned bug through the multi-stream index path (audio 1 is the late tone).
    func testPinnedBug_lateAudio_indexedStream_startsAtZero() throws {
        let src = try makeSource(Fixture.multiStream)
        let (o, out) = reverse(src, video: 0, audio: 1)
        log("R late audio idx", out)
        XCTAssertTrue(o.succeeded, describe(o))
        let a = try XCTUnwrap(Measure.audio(out))
        XCTAssertEqual(try XCTUnwrap(a.onset), 0.0, accuracy: 0.06, "PINNED BUG: correct would be 1.5 s")
    }

    /// PINNED BUG (b) in reverse: a failing M4A conversion stage is swallowed even WITH an NSError
    /// (that step never stores lastError) → success, output without audio.
    func testPinnedBug_failingM4AStage_withError_stillCompletesAsSuccess_withoutAudio() throws {
        let src = try makeSource(Fixture.multiStream)
        let (o, out) = withFailingM4AExport { reverse(src, video: 0, audio: 0) }
        log("R audio-fail", out)
        XCTAssertTrue(o.succeeded, "PINNED: audio failure is swallowed: \(describe(o))")
        XCTAssertEqual(o.completionCount, 1)
        XCTAssertEqual(Measure.audioTrackCount(out), 0)
        assertReversedFrames(out, count: 60)
    }

    /// When the WAV reversal stage fails WITH an NSError, that error is stored and the final completion reports it,
    /// after the video-only output has already been written (file left behind).
    func testFailingWavReverseStage_withError_failsWithAudioError_butLeavesVideoOnlyOutput() throws {
        let src = try makeSource(Fixture.multiStream)
        let (o, out) = withFailingReverseAudioExport { reverse(src, video: 0, audio: 0) }
        log("R wav-fail error", out)
        XCTAssertFalse(o.succeeded, describe(o))
        XCTAssertEqual(o.error?.domain, AVFoundationErrorDomain)
        XCTAssertEqual(o.error?.code, AVError.Code.exportFailed.rawValue)
        XCTAssertEqual(o.completionCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "PINNED: output file left behind on failure")
        XCTAssertEqual(Measure.audioTrackCount(out), 0)
    }

    /// WAV reversal stage failing WITHOUT an NSError → swallowed, success without audio.
    func testPinnedBug_failingWavReverseStage_withoutError_completesAsSuccess() throws {
        let src = try makeSource(Fixture.multiStream)
        let (o, out) = withFailingReverseAudioExport(error: nil) { reverse(src, video: 0, audio: 0) }
        XCTAssertTrue(o.succeeded, describe(o))
        XCTAssertEqual(o.completionCount, 1)
        XCTAssertEqual(Measure.audioTrackCount(out), 0)
    }

    // MARK: helpers

    func assertColor(_ out: URL, _ c: Fixture.RGB, file: StaticString = #filePath, line: UInt = #line) {
        guard let f = Measure.frames(out).first else { return XCTFail("no frames", file: file, line: line) }
        XCTAssertEqual(f.top.r, Double(c.r), accuracy: 40, "r", file: file, line: line)
        XCTAssertEqual(f.top.g, Double(c.g), accuracy: 40, "g", file: file, line: line)
        XCTAssertEqual(f.top.b, Double(c.b), accuracy: 40, "b", file: file, line: line)
    }

    /// The reversal writes every frame of the reversed range exactly once, the range's last frame first (KIOS-10596:
    /// it used to drop it), at the source frame times from 0 (fixture: 20 fps).
    func assertReversedFrames(_ out: URL, count: Int, firstSourceFrame: Int = 0, label: String = "",
                              file: StaticString = #filePath, line: UInt = #line) {
        let f = Measure.frames(out)
        XCTAssertEqual(f.count, count, "\(label) every source frame written", file: file, line: line)
        guard f.count == count else { return }
        let expected = Array((firstSourceFrame..<(firstSourceFrame + count)).reversed())
        for (i, fr) in f.enumerated() {
            XCTAssertEqual(fr.index, expected[i], accuracy: 1, "\(label) source frame of output frame \(i)", file: file, line: line)
            XCTAssertEqual(fr.pts, Double(i) / 20, accuracy: 0.005, "\(label) pts of output frame \(i)", file: file, line: line)
            XCTAssertGreaterThan(max(fr.top.r, fr.top.g, fr.top.b), 100, "\(label) output frame \(i) is not an empty (black) sample",
                                 file: file, line: line)
        }
        // ±1 above is decode noise on single frames; a whole sequence shifted by one (a repeated frame in front, the
        // range's first frame cut off) moves the mean error to about -1.
        let meanError = zip(f, expected).map { Double($0.index - $1) }.reduce(0, +) / Double(count)
        XCTAssertEqual(meanError, 0, accuracy: 0.5, "\(label) output not shifted by a frame", file: file, line: line)
        assertNonIncreasing(f.map(\.index), file: file, line: line)
    }
}
