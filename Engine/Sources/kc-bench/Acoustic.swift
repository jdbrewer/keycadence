// Measures real key-to-sound delay for any app, from outside it: press a key, and time
// how long until the microphone hears the click.
//
// The mic and speakers add their own delay, and that delay is the same for every app on
// the same setup. So gaps between apps are reliable, while absolute numbers include the
// mic. `calibrate` estimates the mic's share using our own engine, which reports its timing.
import ApplicationServices
import AVFoundation
import CKeycadence
import Darwin
import Foundation

private let testKey: CGKeyCode = 79 // F18: types nothing, and has no system shortcut by default

// MARK: - Onset detection (pure, so it can be self-tested)

struct OnsetResult {
    var sampleOffset: Int? // from `start`
    var noisePeak: Float
}

/// The first sample after `start` that clearly stands out from the noise just before it.
/// Works on the sample-to-sample difference, which favours clicks over hum and rumble.
func detectOnset(_ samples: UnsafeBufferPointer<Float>, start: Int, rate: Double, searchSeconds: Double = 0.2) -> OnsetResult {
    let pre = Int(0.06 * rate)
    let first = max(1, start - pre)
    var noise: Float = 0
    if first < start {
        for i in first..<min(start, samples.count) { noise = max(noise, abs(samples[i] - samples[i - 1])) }
    }
    let threshold = max(noise * 4, 0.002)
    let end = min(samples.count, start + Int(searchSeconds * rate))
    var i = max(1, start)
    while i < end {
        if abs(samples[i] - samples[i - 1]) > threshold { return OnsetResult(sampleOffset: i - start, noisePeak: noise) }
        i += 1
    }
    return OnsetResult(sampleOffset: nil, noisePeak: noise)
}

/// Checks the detector against synthetic clicks at known times. Needs no permissions.
func runAcousticSelfTest() -> Bool {
    let rate = 48_000.0
    var rng = SystemRandomNumberGenerator()
    var worst = 0
    var missed = 0
    var falseHits = 0
    for trial in 0..<500 {
        var signal = [Float](repeating: 0, count: Int(rate))
        let hum = Float.random(in: 0.0002...0.01, using: &rng)
        let hiss = Float.random(in: 0.0001...0.001, using: &rng)
        for i in signal.indices {
            signal[i] = hum * sin(Float(i) * 2 * .pi * 60 / Float(rate)) + Float.random(in: -hiss...hiss, using: &rng)
        }
        let start = 10_000
        let silent = trial % 10 == 0
        let delay = Int.random(in: 240...3_000, using: &rng) // 5 to 62 ms
        if !silent {
            let level = Float.random(in: 0.03...0.6, using: &rng)
            for i in 0..<2_000 where start + delay + i < signal.count {
                let decay = exp(-Float(i) / 200)
                signal[start + delay + i] += level * decay * Float.random(in: -1...1, using: &rng)
            }
        }
        let result = signal.withUnsafeBufferPointer { detectOnset($0, start: start, rate: rate) }
        if silent {
            if result.sampleOffset != nil { falseHits += 1 }
        } else if let found = result.sampleOffset {
            worst = max(worst, abs(found - delay))
        } else {
            missed += 1
        }
    }
    let worstMs = Double(worst) / rate * 1000
    print(String(format: "self-test: 500 synthetic trials, worst timing error %.2f ms, %d missed, %d false hits", worstMs, missed, falseHits))
    let ok = worstMs < 1.0 && missed == 0 && falseHits == 0
    print(ok ? "self-test passed" : "self-test FAILED")
    return ok
}

// MARK: - Microphone

/// Keeps every mic sample in memory, along with the host time of each chunk.
private final class MicRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var chunks: [(index: Int, host: UInt64)] = []
    private(set) var rate = 0.0

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        rate = format.sampleRate
        samples.reserveCapacity(Int(rate) * 300)
        input.installTap(onBus: 0, bufferSize: 256, format: format) { [self] buffer, time in
            guard let channel = buffer.floatChannelData?[0], time.isHostTimeValid else { return }
            lock.lock()
            chunks.append((samples.count, time.hostTime))
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            lock.unlock()
        }
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Converts a host time to a sample index, using the chunk that contains it.
    func index(ofHost host: UInt64, timebase: mach_timebase_info_data_t) -> Int? {
        guard let chunk = chunks.last(where: { $0.host <= host }) else { return nil }
        let seconds = Double(host - chunk.host) * Double(timebase.numer) / Double(timebase.denom) / 1e9
        return chunk.index + Int(seconds * rate)
    }

    func withSamples<T>(_ body: (UnsafeBufferPointer<Float>) -> T) -> T {
        samples.withUnsafeBufferPointer(body)
    }

    var peak: Float { samples.reduce(0) { max($0, abs($1)) } }
    var seconds: Double { Double(samples.count) / max(rate, 1) }
}

private func requestMic() -> Bool {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var granted = false
    AVCaptureDevice.requestAccess(for: .audio) { ok in
        granted = ok
        done.signal()
    }
    done.wait()
    return granted
}

private func summarize(_ label: String, values: [Double], total: Int, csvPath: String?) {
    guard !values.isEmpty else {
        print("\(label): no clicks heard in \(total) presses. Is the app on, and the volume up?")
        return
    }
    let sorted = values.sorted()
    let p = { (q: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
    print(String(format: "%@: %d of %d heard. median %.1f ms, p10 %.1f, p90 %.1f, min %.1f, max %.1f",
                 label, values.count, total, p(0.5), p(0.1), p(0.9), sorted.first ?? 0, sorted.last ?? 0))
    if let csvPath {
        let text = "ms\n" + values.map { String(format: "%.3f", $0) }.joined(separator: "\n") + "\n"
        try? text.write(toFile: csvPath, atomically: true, encoding: .utf8)
        print("raw values: \(csvPath)")
    }
}

private func isRunning(_ name: String) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-x", name]
    task.standardOutput = FileHandle.nullDevice
    try? task.run()
    task.waitUntilExit()
    return task.terminationStatus == 0
}

private func press(_ key: CGKeyCode, down: Bool) {
    CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)?.post(tap: .cghidEventTap)
}

// MARK: - Modes

/// Times the named key-sound app, from outside it. Any other key-sound app has to be quit
/// first, or the mic can't tell which one it heard.
func runAcoustic(app: String, count: Int, outDir: String) -> Int32 {
    guard isRunning(app) else {
        print("\(app) isn't running. Open it, and quit any other key-sound app, then run this again.")
        return 2
    }
    guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
        print("This terminal needs Accessibility so the test can press F18. Allow it in System Settings, then run this again.")
        return 2
    }
    guard requestMic() else {
        print("This terminal needs Microphone access. Allow it in System Settings, then run this again.")
        return 2
    }

    let mic = MicRecorder()
    do { try mic.start() } catch {
        print("Couldn't start the microphone: \(error)")
        return 1
    }
    print("Timing \(app): \(count) presses, about \(count * 55 / 100) seconds. Keep the room quiet, and don't type.")
    usleep(500_000)

    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    var presses: [UInt64] = []
    let warmup = 6 // wakes the app's audio output: these aren't counted
    for i in 0..<(count + warmup) {
        let now = mach_absolute_time()
        press(testKey, down: true)
        if i >= warmup { presses.append(now) }
        usleep(60_000)
        press(testKey, down: false)
        usleep(UInt32.random(in: 400_000...580_000)) // uneven, and long enough for the tail to fade
    }
    usleep(300_000)
    mic.stop()

    if mic.peak < 0.0005 {
        print("The mic recorded silence. Check Microphone permission for this terminal.")
        return 1
    }
    var values: [Double] = []
    mic.withSamples { samples in
        for host in presses {
            guard let start = mic.index(ofHost: host, timebase: timebase) else { continue }
            if let offset = detectOnset(samples, start: start, rate: mic.rate).sampleOffset {
                values.append(Double(offset) / mic.rate * 1000)
            }
        }
    }
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let stamp = Int(Date().timeIntervalSince1970)
    summarize(app, values: values, total: presses.count, csvPath: "\(outDir)/\(app.lowercased())-\(stamp).csv")
    return 0
}

/// Plays through our engine, which reports its own timing. What the mic adds beyond that
/// is the mic's share, plus the trip through the air. Needs Microphone only: no key presses.
func runCalibration(pack: String, count: Int) -> Int32 {
    guard !isRunning("Keycadence") else {
        print("Quit Keycadence and any other key-sound app first.")
        return 2
    }
    guard requestMic() else {
        print("This terminal needs Microphone access. Allow it in System Settings, then run this again.")
        return 2
    }
    guard let engine = kc_engine_create(), kc_engine_load_pack(engine, pack) else {
        print("Couldn't load \(pack)")
        return 1
    }
    defer { kc_engine_destroy(engine) }
    kc_engine_set_volume(engine, 0.5)
    kc_engine_set_pitch_variation(engine, false)
    kc_engine_set_spatial(engine, false)
    kc_engine_set_pan(engine, false)
    kc_engine_set_profile(engine, 4) // Clicky: a sharp attack, so the onset is easy to time

    let mic = MicRecorder()
    do { try mic.start() } catch {
        print("Couldn't start the microphone: \(error)")
        return 1
    }
    print("Calibrating: \(count) clicks through our engine, about \(count * 5 / 10) seconds. Keep the room quiet.")
    usleep(500_000)

    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    var presses: [UInt64] = []
    var reported: [Double] = []
    for i in 0..<(count + 6) {
        let now = mach_absolute_time()
        var before = kc_stats()
        kc_engine_get_stats(engine, &before)
        kc_engine_key_event(engine, 0, true)
        var after = kc_stats()
        var spin = 0
        repeat {
            usleep(200)
            kc_engine_get_stats(engine, &after)
            spin += 1
        } while after.count == before.count && spin < 2_000
        if i >= 6 {
            presses.append(now)
            reported.append(after.last_ms + after.device_ms)
        }
        usleep(UInt32.random(in: 400_000...520_000))
    }
    usleep(300_000)
    mic.stop()

    var heard: [Double] = []
    var heardReported: [Double] = []
    mic.withSamples { samples in
        for (host, engineMs) in zip(presses, reported) {
            guard let start = mic.index(ofHost: host, timebase: timebase),
                  let offset = detectOnset(samples, start: start, rate: mic.rate).sampleOffset else { continue }
            heard.append(Double(offset) / mic.rate * 1000)
            heardReported.append(engineMs)
        }
    }
    summarize("heard by mic", values: heard, total: presses.count, csvPath: nil)
    summarize("reported by engine + device", values: heardReported, total: presses.count, csvPath: nil)
    if !heard.isEmpty {
        let gap = zip(heard, heardReported).map { $0 - $1 }.sorted()[heard.count / 2]
        print(String(format: "difference: %+.1f ms. A negative or very large value means the mic's clock is off from what we assume.", gap))
    }
    return 0
}
