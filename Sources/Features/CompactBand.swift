import AppKit
import SwiftUI
import Combine

@MainActor
final class CompactBandController {
    let model = NotchViewModel()
    let history = BandHistory()
    var signInItems: [(title: String, action: () -> Void)] = []
    var onOpenSettings: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onRefreshProvider: ((String) -> Void)?
    private var panel: NSPanel?
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private var hidden = false
    func show() {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let panel = NSPanel(contentRect: NSRect(x: screen.maxX - 360, y: screen.maxY - 58, width: 340, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        _ = panel.setFrameUsingName("SpenthaBandPosition")
        panel.setFrameAutosaveName("SpenthaBandPosition")
        panel.contentView = NSHostingView(rootView: CompactBand(model: model, history: history,
                                                              settings: { [weak self] in self?.onOpenSettings?() },
                                                              refresh: { [weak self] in self?.onRefresh?() }))
        self.panel = panel
        model.$snapshots.receive(on: RunLoop.main).sink { [weak self] snapshots in
            guard let self else { return }
            self.history.record(snapshots)
            let count = snapshots.filter { $0.hasReading || $0.block != nil }.count
            let width = CGFloat(max(1, count) * 104 + 50)
            if let panel = self.panel {
                var frame = panel.frame
                frame.origin.x += frame.width - width
                frame.size = CGSize(width: width, height: 44)
                if let bounds = panel.screen?.visibleFrame {
                    frame.origin.x = max(bounds.minX, min(frame.origin.x, bounds.maxX - width))
                    frame.origin.y = max(bounds.minY, min(frame.origin.y, bounds.maxY - 44))
                }
                panel.setFrame(frame, display: true)
            }
        }.store(in: &subscriptions)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.now = Date() }
        }
        if !hidden { panel.orderFrontRegardless() }
    }
    func apply(_ visibility: NotchVisibility) {
        hidden = visibility == .hidden
        if hidden { panel?.orderOut(nil) } else { panel?.orderFrontRegardless() }
    }
    func apply(edge: NotchEdge) { model.edge = edge }
    func stop() { timer?.invalidate(); panel?.close(); subscriptions.removeAll() }
}

struct CompactBand: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var history: BandHistory
    var settings: () -> Void
    var refresh: () -> Void
    @State private var selected: String?
    private var visible: [ProviderSnapshot] { model.snapshots.filter { $0.hasReading || $0.block != nil } }
    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "line.3.horizontal").font(.system(size: 9)).foregroundStyle(.gray)
                .frame(width: 18).help("Arrastrá la banda para moverla")
            if visible.isEmpty {
                Button("Conectar IA", action: settings).font(.system(size: 11)).frame(width: 104)
            }
            ForEach(visible) { snapshot in
                Button { selected = selected == snapshot.id ? nil : snapshot.id } label: {
                    HStack(spacing: 8) {
                        BandRings(usage: snapshot.ringFraction,
                                  forecast: snapshot.headline.flatMap { history.forecast(snapshot, window: $0, now: model.now) },
                                  glyph: snapshot.glyph)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.headlineText).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                            Text(snapshot.status.isStale ? "sin actualizar" : activity(snapshot))
                                .font(.system(size: 9)).foregroundStyle(snapshot.block != nil ? Color.orange : Color.gray)
                                .lineLimit(1)
                        }
                    }.frame(width: 104, height: 44)
                }.buttonStyle(.plain)
                    .help("\(snapshot.displayName) · consumo y proyección. Clic para detalle")
                    .popover(isPresented: Binding(get: { selected == snapshot.id }, set: { if !$0 { selected = nil } }), arrowEdge: .bottom) {
                        BandDetail(snapshot: snapshot, history: history, now: model.now,
                                   sessions: model.sessions[snapshot.id] ?? [])
                    }
            }
            Button(action: settings) { Image(systemName: "slider.horizontal.3").font(.system(size: 11)).frame(width: 32, height: 36) }
                .buttonStyle(.plain).foregroundStyle(.gray).help("Ajustes")
        }
        .foregroundStyle(.white).background(Color(hex: 0x16191D))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.09), lineWidth: 1))
        .contextMenu { Button("Actualizar", action: refresh); Button("Ajustes", action: settings); Divider(); Button("Salir") { NSApp.terminate(nil) } }
        .preferredColorScheme(.dark)
    }
    private func activity(_ snapshot: ProviderSnapshot) -> String {
        if snapshot.block != nil { return "límite alcanzado" }
        let sessions = model.sessions[snapshot.id] ?? []
        let waiting = sessions.filter { $0.state == .waiting }.count
        let busy = sessions.filter { $0.state == .busy }.count
        if waiting > 0 { return "\(waiting) pendiente" }
        if busy > 0 { return "\(busy) en curso" }
        return snapshot.headline?.label.lowercased().contains("week") == true ? "semanal" : "consumido"
    }
}

struct BandRings: View {
    let usage: Double?
    let forecast: BandForecast?
    let glyph: ProviderGlyph
    static func tint(_ forecast: BandForecast?) -> Color {
        guard let forecast else { return Color.gray.opacity(0.35) }
        return forecast.risk == 0 ? Color(hex: 0x66D6B0) : forecast.risk == 1 ? Color(hex: 0xE9BF66) : Color(hex: 0xEF837A)
    }
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.07), lineWidth: 2)
            Circle().trim(from: 0, to: min(1, max(0, forecast?.projected ?? 0)))
                .stroke(Self.tint(forecast), style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
            Circle().stroke(.white.opacity(0.1), lineWidth: 2.5).padding(5)
            Circle().trim(from: 0, to: min(1, max(0, usage ?? 0)))
                .stroke(Color(hex: 0xB8C8D8), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90)).padding(5)
            ProviderGlyphView(glyph: glyph, size: 12).frame(width: 12, height: 12).foregroundStyle(.white.opacity(0.85))
        }.frame(width: 32, height: 32)
    }
}

struct BandDetail: View {
    let snapshot: ProviderSnapshot
    @ObservedObject var history: BandHistory
    let now: Date
    let sessions: [AgentSession]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(snapshot.displayName).font(.system(size: 13, weight: .semibold))
            if snapshot.status.isStale { Text("Dato sin actualizar · proyección pausada").foregroundStyle(.orange) }
            if let block = snapshot.block { Text(block.summary(now: now)).foregroundStyle(.orange) }
            ForEach(snapshot.windows) { window in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(window.label).foregroundStyle(.secondary)
                        Spacer()
                        Text(window.usedFraction.map { "\(Int($0 * 100))%" } ?? window.summary).monospacedDigit()
                    }
                    if let reset = window.resetsAt { Text("Reinicia \(reset.formatted(.relative(presentation: .numeric).locale(Locale(identifier: "es"))))").foregroundStyle(.secondary) }
                    if let forecast = history.forecast(snapshot, window: window, now: now) {
                        TrendChart(points: forecast.points, projected: forecast.projected, tint: BandRings.tint(forecast))
                            .frame(height: 32)
                        Text(forecast.summary).foregroundStyle(BandRings.tint(forecast))
                    } else { Text("Tendencia: reuniendo historial fiable").foregroundStyle(.secondary) }
                }
            }
            if !sessions.isEmpty {
                Divider()
                ForEach(sessions.prefix(4)) { session in
                    HStack { Circle().fill(session.state == .waiting ? Color.orange : Color.gray).frame(width: 4, height: 4)
                        Text(session.name).lineLimit(1); Spacer()
                        Text(session.state == .busy ? "en curso" : session.state == .waiting ? "pendiente" : "inactivo").foregroundStyle(.secondary)
                    }
                }
            }
            Text("Interior: consumo · exterior: proyección").font(.system(size: 9)).foregroundStyle(.tertiary)
        }.font(.system(size: 11)).padding(16).frame(width: 300).preferredColorScheme(.dark)
    }
}

struct TrendChart: View {
    let points: [Double]
    let projected: Double
    let tint: Color
    var body: some View {
        Canvas { context, size in
            let ceiling = max(1, projected)
            func position(_ index: Int, _ value: Double) -> CGPoint {
                CGPoint(x: size.width * 0.7 * CGFloat(index) / CGFloat(max(1, points.count - 1)),
                        y: size.height * (1 - value / ceiling))
            }
            var observed = Path()
            for (i, value) in points.enumerated() {
                if i == 0 { observed.move(to: position(i, value)) }
                else { observed.addLine(to: position(i, value)) }
            }
            context.stroke(observed, with: .color(tint), lineWidth: 1.5)
            if let last = points.last {
                var projection = Path()
                projection.move(to: position(points.count - 1, last))
                projection.addLine(to: CGPoint(x: size.width, y: size.height * (1 - projected / ceiling)))
                context.stroke(projection, with: .color(tint.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
        }
    }
}
