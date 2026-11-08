import Foundation
import Combine

/// Only quota readings are persisted. Each provider/window/reset is an independent series.
struct BandSample: Codable {
    let key: String
    let time: Date
    let reset: Date
    let usage: Double
}

struct BandForecast {
    let projected: Double
    let points: [Double]
    var risk: Int { projected < 0.85 ? 0 : projected < 1 ? 1 : 2 }
    var summary: String {
        projected < 1
            ? "Al reinicio: ≈\(Int((1 - projected) * 100))% disponible"
            : "A este ritmo, agotás la cuota antes del reinicio"
    }
}

enum BandAnalytics {
    static func forecast(samples: [BandSample], key: String, window: LimitWindow,
                         now: Date) -> BandForecast? {
        guard let reset = window.resetsAt, reset > now, let usage = window.usedFraction,
              usage.isFinite else { return nil }
        let points = samples.filter {
            $0.key == key && abs($0.reset.timeIntervalSince(reset)) < 60
                && $0.time <= now && now.timeIntervalSince($0.time) <= 86400
        }.sorted { $0.time < $1.time }
        guard let first = points.first, let last = points.last, points.count >= 2,
              last.time.timeIntervalSince(first.time) >= 3600,
              now.timeIntervalSince(last.time) < 900 else { return nil }
        // A falling quota indicates a rolling window/account change; a linear forecast is unsafe.
        guard zip(points, points.dropFirst()).allSatisfy({ $1.usage >= $0.usage - 0.005 }) else { return nil }
        let weighted = points.map { p in
            (x: p.time.timeIntervalSince(first.time) / 3600, y: p.usage,
             w: exp(-log(2) * now.timeIntervalSince(p.time) / 21600))
        }
        let weight = weighted.reduce(0) { $0 + $1.w }
        let mx = weighted.reduce(0) { $0 + $1.x * $1.w } / weight
        let my = weighted.reduce(0) { $0 + $1.y * $1.w } / weight
        let denominator = weighted.reduce(0) { $0 + $1.w * pow($1.x - mx, 2) }
        guard denominator > 0 else { return nil }
        let slope = max(0, weighted.reduce(0) { $0 + $1.w * ($1.x - mx) * ($1.y - my) } / denominator)
        let cycleSlope = max(0, (last.usage - first.usage) / (last.time.timeIntervalSince(first.time) / 3600))
        let rate = 0.72 * slope + 0.28 * cycleSlope
        return BandForecast(projected: usage + rate * reset.timeIntervalSince(now) / 3600,
                            points: points.map(\.usage))
    }
}

@MainActor
final class BandHistory: ObservableObject {
    @Published private(set) var samples: [BandSample] = []
    private let url: URL
    init() {
        url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpenthaBand/history.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([BandSample].self, from: data) {
            samples = saved.filter { Date().timeIntervalSince($0.time) < 10 * 86400 }
        }
    }
    func record(_ snapshots: [ProviderSnapshot], now: Date = Date()) {
        var next = samples.filter { now.timeIntervalSince($0.time) < 10 * 86400 }
        for snapshot in snapshots where snapshot.status == .ok {
            for window in snapshot.windows {
                guard let usage = window.usedFraction, usage.isFinite,
                      let reset = window.resetsAt, reset > now else { continue }
                let key = snapshot.id + "/" + window.id
                if let last = next.last(where: { $0.key == key }), now.timeIntervalSince(last.time) < 60 { continue }
                next.append(BandSample(key: key, time: now, reset: reset, usage: usage))
            }
        }
        guard next.count != samples.count || next.last?.time != samples.last?.time else { return }
        samples = next
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(next) { try? data.write(to: url, options: .atomic) }
    }
    func forecast(_ snapshot: ProviderSnapshot, window: LimitWindow, now: Date) -> BandForecast? {
        guard snapshot.status == .ok else { return nil }
        return BandAnalytics.forecast(samples: samples, key: snapshot.id + "/" + window.id, window: window, now: now)
    }
}
