import CKeycadence
import Foundation
import Observation

/// Daily keystroke totals, kept on this Mac only. Off by default.
/// Counts how many keys were pressed, never which ones.
@MainActor
@Observable
final class KeyStats {
    private(set) var days: [String: Int]
    private(set) var liveToday = 0

    @ObservationIgnored private let engine: OpaquePointer
    @ObservationIgnored private let store = UserDefaults.standard
    @ObservationIgnored private var lastCount: UInt64 = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored var onChange: (() -> Void)?

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init(engine: OpaquePointer) {
        self.engine = engine
        days = store.dictionary(forKey: "keyDays") as? [String: Int] ?? [:]
        lastCount = kc_engine_key_count(engine)
        liveToday = days[Self.key(for: Date())] ?? 0
    }

    var isRunning: Bool { timer != nil }

    func setRunning(_ running: Bool) {
        lastCount = kc_engine_key_count(engine)
        timer?.invalidate()
        timer = nil
        guard running else { return }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func tick() {
        let count = kc_engine_key_count(engine)
        guard count != lastCount else { return }
        let key = Self.key(for: Date())
        days[key, default: 0] += Int(count - lastCount)
        lastCount = count
        liveToday = days[key] ?? 0
        store.set(days, forKey: "keyDays")
        onChange?()
    }

    func reset() {
        days = [:]
        liveToday = 0
        store.removeObject(forKey: "keyDays")
        onChange?()
    }

    var total: Int { days.values.reduce(0, +) }

    func recent(_ count: Int) -> [(date: Date, keys: Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<count).reversed().map { offset in
            let date = cal.date(byAdding: .day, value: -offset, to: today) ?? today
            return (date, days[Self.key(for: date)] ?? 0)
        }
    }

    private static func key(for date: Date) -> String { formatter.string(from: date) }
}
