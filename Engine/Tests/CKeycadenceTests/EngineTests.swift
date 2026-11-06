import CKeycadence
import XCTest

final class EngineTests: XCTestCase {
    private var engine: OpaquePointer!

    private static var packPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Resources/sounds.kcpack").path
    }

    override func setUp() {
        engine = kc_engine_create()
        XCTAssertTrue(kc_engine_load_pack(engine, Self.packPath), "run tools/build_pack.py first")
        kc_engine_set_volume(engine, 1)
        kc_engine_set_pitch_variation(engine, false)
    }

    override func tearDown() {
        kc_engine_destroy(engine)
    }

    private func render(seconds: Double = 0.2, rate: Double = 48_000) -> (l: [Float], r: [Float]) {
        let n = Int(seconds * rate)
        var l = [Float](repeating: 0, count: n), r = l
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                kc_engine_render_offline(engine, lp.baseAddress, rp.baseAddress, UInt32(n), rate)
            }
        }
        return (l, r)
    }

    private func energy(_ x: [Float]) -> Float { x.reduce(0) { $0 + $1 * $1 } }
    private func peak(_ x: [Float]) -> Float { x.map(abs).max() ?? 0 }

    func testRejectsBadPacks() throws {
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID()).kcpack")
        try Data(repeating: 7, count: 256).write(to: bad)
        defer { try? FileManager.default.removeItem(at: bad) }
        let fresh = kc_engine_create()
        XCTAssertFalse(kc_engine_load_pack(fresh, bad.path))
        XCTAssertFalse(kc_engine_load_pack(fresh, "/no/such/file"))
        kc_engine_destroy(fresh)
    }

    func testPackHasAllProfiles() {
        XCTAssertEqual(kc_engine_profile_count(engine), 9)
    }

    func testKeyDownMakesSoundAndSilenceIsSilent() {
        XCTAssertEqual(peak(render().l), 0)
        kc_engine_key_event(engine, 0, true)
        let out = render()
        XCTAssertGreaterThan(peak(out.l), 0.01)
    }

    func testEveryProfileAndClassSounds() {
        for p in 0..<kc_engine_profile_count(engine) {
            kc_engine_set_profile(engine, p)
            for key: UInt16 in [0, 49, 36, 51, 56] {
                kc_engine_key_event(engine, key, true)
                XCTAssertGreaterThan(peak(render(seconds: 0.3).l), 0.01, "profile \(p) key \(key)")
                kc_engine_key_event(engine, key, false)
                XCTAssertGreaterThan(peak(render(seconds: 0.3).l), 0.001, "profile \(p) key \(key) up")
            }
        }
    }

    func testDisabledIsSilentButStillCounts() {
        kc_engine_set_enabled(engine, false)
        kc_engine_key_event(engine, 0, true)
        XCTAssertEqual(peak(render().l), 0)
        XCTAssertEqual(kc_engine_key_count(engine), 1)
    }

    func testQuietGainScalesAndZeroSkips() {
        kc_engine_set_quiet_gain(engine, 0)
        kc_engine_key_event(engine, 0, true)
        XCTAssertEqual(peak(render().l), 0)
    }

    func testPanFollowsKeyPosition() {
        kc_engine_set_spatial(engine, false)
        kc_engine_key_event(engine, 0x35, true) // esc: far left
        let left = render(seconds: 0.3)
        XCTAssertGreaterThan(energy(left.l), energy(left.r) * 1.5)
        kc_engine_key_event(engine, 0x33, true) // delete: far right
        let right = render(seconds: 0.3)
        XCTAssertGreaterThan(energy(right.r), energy(right.l) * 1.5)
    }

    func testPanOffIsCentred() {
        kc_engine_set_pan(engine, false)
        kc_engine_set_spatial(engine, false)
        kc_engine_key_event(engine, 0x35, true)
        let out = render(seconds: 0.3)
        XCTAssertEqual(energy(out.l), energy(out.r), accuracy: energy(out.l) * 0.001)
    }

    func testSpatialDelaysFarEar() {
        kc_engine_set_pan(engine, false)
        kc_engine_key_event(engine, 0x35, true) // left: right ear hears it later
        let out = render(seconds: 0.1)
        let threshold: Float = 0.0005
        let l = out.l.firstIndex { abs($0) > threshold }!
        let r = out.r.firstIndex { abs($0) > threshold }!
        XCTAssertGreaterThan(r, l)
    }

    func testSpatialAddsNoEcho() {
        // One voice ends and nothing follows it: no delayed copies of the sound.
        kc_engine_set_spatial(engine, true)
        kc_engine_key_event(engine, 0, true)
        _ = render(seconds: 0.5) // longer than any alpha sound in the pack
        XCTAssertEqual(peak(render(seconds: 0.1).l), 0)
    }

    func testMuteModifiers() {
        kc_engine_set_mute_modifiers(engine, true)
        kc_engine_key_event(engine, 56, true)
        XCTAssertEqual(peak(render().l), 0)
        kc_engine_key_event(engine, 0, true)
        XCTAssertGreaterThan(peak(render().l), 0)
    }

    func testIgnoreRapidDropsSecondPressAndItsRelease() {
        kc_engine_set_ignore_rapid(engine, true)
        kc_engine_set_spatial(engine, false)
        usleep(40_000)
        kc_engine_key_event(engine, 1, true)
        XCTAssertGreaterThan(peak(render(seconds: 0.5).l), 0)
        kc_engine_key_event(engine, 2, true) // inside the window: silent
        XCTAssertEqual(peak(render(seconds: 0.01).l), 0)
        kc_engine_key_event(engine, 2, false) // and so is its release
        XCTAssertEqual(peak(render(seconds: 0.01).l), 0)
        XCTAssertEqual(kc_engine_key_count(engine), 2)
    }

    func testMashingIsLimitedAndNeverExplodes() {
        for i in 0..<200 {
            kc_engine_key_event(engine, UInt16(i % 50), true)
            let out = render(seconds: 0.002)
            XCTAssertLessThanOrEqual(peak(out.l), 1.0)
            XCTAssertLessThanOrEqual(peak(out.r), 1.0)
            XCTAssertFalse(out.l.contains { $0.isNaN })
        }
    }

    func testToneChangesSpectrumAndStaysStable() {
        kc_engine_set_spatial(engine, false)
        kc_engine_key_event(engine, 49, true)
        let flat = energy(render(seconds: 0.3).l)
        for (x, y): (Float, Float) in [(1, 1), (-1, -1), (1, -1), (-1, 1)] {
            kc_engine_set_tone(engine, x, y)
            kc_engine_key_event(engine, 49, true)
            let out = render(seconds: 0.3)
            XCTAssertFalse(out.l.contains { $0.isNaN || abs($0) > 1 })
            XCTAssertNotEqual(energy(out.l), flat, accuracy: flat * 0.01)
        }
    }

    func testOtherSampleRates() {
        for rate in [44_100.0, 96_000.0, 192_000.0] {
            kc_engine_key_event(engine, 0, true)
            XCTAssertGreaterThan(peak(render(seconds: 0.2, rate: rate).l), 0.01, "\(rate)")
        }
    }

    func testEffectsUseEffectsVolume() {
        kc_engine_preview_effect(engine, KC_EFFECT_DING)
        XCTAssertGreaterThan(peak(render(seconds: 0.2).l), 0.01)
        _ = render(seconds: 1)
        kc_engine_set_effects_volume(engine, 0)
        kc_engine_preview_effect(engine, KC_EFFECT_DING)
        XCTAssertEqual(peak(render(seconds: 0.2).l), 0)
    }

    func testReturnDingPlaysOnlyWhenOn() {
        kc_engine_set_mute_modifiers(engine, false)
        kc_engine_set_effects_volume(engine, 1)
        kc_engine_set_spatial(engine, false)
        kc_engine_set_return_ding(engine, true)
        kc_engine_key_event(engine, 36, true)
        XCTAssertGreaterThan(peak(Array(render(seconds: 0.25).l.suffix(2400))), 0.001) // the bell outlasts the key
        _ = render(seconds: 1)
        kc_engine_set_return_ding(engine, false)
        kc_engine_key_event(engine, 36, true)
        XCTAssertEqual(peak(Array(render(seconds: 0.25).l.suffix(2400))), 0)
    }

    func testPreviewIgnoresEnabledAndQuiet() {
        kc_engine_set_enabled(engine, false)
        kc_engine_set_quiet_gain(engine, 0)
        kc_engine_preview_profile(engine, 1)
        XCTAssertGreaterThan(peak(render().l), 0.01)
    }

    func testBufferSettingIsAcceptedAndHarmless() {
        kc_engine_set_buffer_frames(engine, 64)
        kc_engine_set_buffer_frames(engine, 0) // ignored
        kc_engine_key_event(engine, 0, true)
        XCTAssertGreaterThan(peak(render().l), 0.01)
    }

    func testKeyMapBounds() {
        for code in UInt16(0)..<140 {
            let p = kc_key_position_for_keycode(code)
            XCTAssertTrue((-1...1).contains(p), "\(code)")
        }
        XCTAssertLessThan(kc_key_position_for_keycode(0x35), -0.8)
        XCTAssertGreaterThan(kc_key_position_for_keycode(0x33), 0.8)
        XCTAssertEqual(kc_key_class_for_keycode(0x31), KC_CLASS_SPACE)
        XCTAssertEqual(kc_key_class_for_keycode(0x24), KC_CLASS_RETURN)
    }
}
