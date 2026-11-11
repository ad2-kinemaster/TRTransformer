import AVFoundation
import TRTransformer
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
