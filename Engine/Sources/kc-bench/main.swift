// Measures the real path through the engine, on real audio hardware.
//
//   kc-bench latency <pack> [count] [buffer frames]   latency, cold start and CPU (volume is 0: silent)
//   kc-bench render <pack> <out.wav> [profile] [--ding] [--mouse]
//                                     renders a typing passage offline, for listening
//   kc-bench acoustic-selftest        checks the click detector, with no permissions needed
//   kc-bench calibrate <pack> [count] compares what the mic hears with what the engine reports
//   kc-bench acoustic <app> [count] [dir]  times the named key-sound app, by microphone
import CKeycadence
import Darwin
import Foundation

func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
}

func rssMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return Double(info.resident_size) / 1_048_576
}

func stats(_ engine: OpaquePointer) -> kc_stats {
    var s = kc_stats()
    kc_engine_get_stats(engine, &s)
    return s
}

func runLatency(pack: String, count: Int, frames: UInt32) {
    guard let engine = kc_engine_create(), kc_engine_load_pack(engine, pack) else { fatalError("cannot load \(pack)") }
    kc_engine_set_buffer_frames(engine, frames)
    kc_engine_set_volume(engine, 0) // silent: the render path still runs in full
    usleep(300_000)

    print("resident memory after load: \(String(format: "%.1f", rssMB())) MB")

    // Cold start: the first key after the output has been stopped.
    kc_engine_key_event(engine, 0, true)
    var waited = 0
    while stats(engine).count == 0 && waited < 2000 { usleep(1000); waited += 1 }
    let first = stats(engine)
    print(String(format: "first key (output stopped):  %.2f ms to first sample; start call %.2f ms",
                 first.last_ms, first.last_cold_start_ms))
    usleep(200_000)
    let baseline = first.count

    var hot: [Double] = []
    let cpu0 = cpuSeconds()
    let wall0 = Date()
    for i in 0..<count {
        let before = stats(engine).count
        kc_engine_key_event(engine, UInt16(i % 50), true)
        var spin = 0
        while stats(engine).count == before && spin < 200 { usleep(100); spin += 1 }
        hot.append(stats(engine).last_ms)
        usleep(UInt32(15_000 + (i * 7_919) % 25_000)) // uneven, like typing
        kc_engine_key_event(engine, UInt16(i % 50), false)
        usleep(5_000)
    }
    let wall = Date().timeIntervalSince(wall0)
    let cpu = cpuSeconds() - cpu0
    hot.sort()
    let s = stats(engine)
    print("samples: \(hot.count) (engine counted \(s.count - baseline))")
    print(String(format: "hot latency, key event to first sample at device: p50 %.2f  p99 %.2f  max %.2f ms",
                 hot[hot.count / 2], hot[hot.count * 99 / 100], hot.last ?? 0))
    print(String(format: "device-reported output latency on top of that: %.2f ms", s.device_ms))
    print(String(format: "output: %.0f Hz, %u frame buffer (%.2f ms)",
                 s.sample_rate, s.buffer_frames, Double(s.buffer_frames) / s.sample_rate * 1000))
    print(String(format: "CPU while typing: %.2f%% of one core", cpu / wall * 100))
    print(String(format: "resident memory: %.1f MB", rssMB()))

    print("waiting for idle stop...")
    var idle = 0
    while kc_engine_is_running(engine) && idle < 40 { sleep(1); idle += 1 }
    print("output stopped after \(idle) s idle: \(!kc_engine_is_running(engine))")
    let idleCpu0 = cpuSeconds()
    sleep(5)
    print(String(format: "CPU while idle: %.3f%% of one core", (cpuSeconds() - idleCpu0) / 5 * 100))

    // Warm restart: unit built, output stopped. This is what a typist hits after a pause.
    var restarts: [Double] = []
    for i in 0..<8 {
        let before = stats(engine).count
        kc_engine_key_event(engine, UInt16(i), true)
        var spin = 0
        while stats(engine).count == before && spin < 2000 { usleep(100); spin += 1 }
        restarts.append(stats(engine).last_ms)
        kc_engine_key_event(engine, UInt16(i), false)
        usleep(100_000)
        break
    }
    print(String(format: "first key after idle: %.2f ms to first sample", restarts.first ?? -1))
    kc_engine_destroy(engine)
}

func writeWav(path: String, left: [Float], right: [Float], rate: Int) {
    var data = Data()
    func put<T>(_ v: T) { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
    let bytes = left.count * 4
    data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes).littleEndian)
    data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16).littleEndian)
    put(UInt16(1).littleEndian); put(UInt16(2).littleEndian); put(UInt32(rate).littleEndian)
    put(UInt32(rate * 4).littleEndian); put(UInt16(4).littleEndian); put(UInt16(16).littleEndian)
    data.append(contentsOf: Array("data".utf8)); put(UInt32(bytes).littleEndian)
    for i in left.indices {
        put(Int16(max(-1, min(1, left[i])) * 32767).littleEndian)
        put(Int16(max(-1, min(1, right[i])) * 32767).littleEndian)
    }
    FileManager.default.createFile(atPath: path, contents: data)
}

func runRender(pack: String, out: String, profile: Int32, ding: Bool, mouse: Bool) {
    guard let engine = kc_engine_create(), kc_engine_load_pack(engine, pack) else { fatalError("cannot load \(pack)") }
    kc_engine_set_volume(engine, 0.8)
    kc_engine_set_profile(engine, profile)
    kc_engine_set_return_ding(engine, ding)

    // "the quick brown fox" + space, shift, delete, return, in key codes.
    let keys: [UInt16] = [17, 4, 14, 49, 12, 32, 34, 8, 40, 49, 11, 15, 31, 13, 45, 49, 3, 31, 7, 49, 56, 51, 51, 36]
    let rate = 48_000
    var left: [Float] = [], right: [Float] = []
    func advance(_ seconds: Double) {
        let n = Int(seconds * Double(rate))
        var l = [Float](repeating: 0, count: n), r = l
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                kc_engine_render_offline(engine, lp.baseAddress, rp.baseAddress, UInt32(n), Double(rate))
            }
        }
        left += l; right += r
    }
    var rng = SystemRandomNumberGenerator()
    for key in keys {
        kc_engine_key_event(engine, key, true)
        advance(Double.random(in: 0.06...0.1, using: &rng))
        kc_engine_key_event(engine, key, false)
        advance(Double.random(in: 0.04...0.14, using: &rng))
    }
    advance(ding ? 1.0 : 0.3)
    writeWav(path: out, left: left, right: right, rate: rate)
    print("wrote \(out): \(left.count / rate) s, peak \(left.map(abs).max() ?? 0)")
    kc_engine_destroy(engine)
}

let args = CommandLine.arguments
if args.count >= 2 {
    switch args[1] {
    case "acoustic-selftest":
        exit(runAcousticSelfTest() ? 0 : 1)
    case "acoustic":
        guard args.count >= 3 else {
            print("usage: kc-bench acoustic <app name> [count] [dir]")
            exit(2)
        }
        exit(runAcoustic(app: args[2],
                         count: args.count > 3 ? Int(args[3]) ?? 120 : 120,
                         outDir: args.count > 4 ? args[4] : "latency-results"))
    case "calibrate":
        guard args.count >= 3 else { exit(2) }
        exit(runCalibration(pack: args[2], count: args.count > 3 ? Int(args[3]) ?? 60 : 60))
    default:
        break
    }
}
guard args.count >= 3 else {
    print("usage: kc-bench latency <pack> [count] | render <pack> <out.wav> [profile] [--ding]")
    exit(2)
}
switch args[1] {
case "latency":
    runLatency(pack: args[2], count: args.count > 3 ? Int(args[3]) ?? 500 : 500,
               frames: args.count > 4 ? UInt32(args[4]) ?? 128 : 128)
case "render":
    guard args.count >= 4 else { exit(2) }
    let profile = args.count > 4 ? Int32(args[4]) ?? 0 : 0
    runRender(pack: args[2], out: args[3], profile: profile, ding: args.contains("--ding"), mouse: args.contains("--mouse"))
default:
    exit(2)
}
