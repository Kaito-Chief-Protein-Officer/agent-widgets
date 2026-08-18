// Desktop panel showing Claude Code / Codex remaining quota.
//
// Renders a borderless, click-through window pinned at the desktop-icon level,
// so it sits on the wallpaper and never steals focus or appears in the Dock.
// All data comes from ~/.config/agent-widgets/collect.py, which is the only
// thing that talks to the network.

import AppKit

// MARK: - Model

struct Meter: Decodable {
    let name: String
    let remaining: Int
    let resetsAt: Int?
    /// Text to show instead of "<remaining>%". Health readings are 0-100
    /// scores or raw counts, not percentages, even though the bar is a ratio.
    let display: String?

    var readout: String { display ?? "\(remaining)%" }

    enum CodingKeys: String, CodingKey {
        case name, remaining, display
        case resetsAt = "resets_at"
    }
}

struct ModelRow: Decodable {
    let label: String
    let value: Int
    let share: Int
    let slot: Int
}

struct Stat: Decodable {
    let label: String
    let value: String
}

struct Card: Decodable {
    let id: String
    let label: String
    let sub: String?
    let kind: String?
    let meters: [Meter]
    let rows: [ModelRow]
    let stats: [Stat]
    let note: String?
    let state: String

    var isModels: Bool { kind == "models" }
    var isHealth: Bool { kind == "health" }

    enum CodingKeys: String, CodingKey {
        case id, label, sub, kind, meters, rows, stats, note, state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        sub = try container.decodeIfPresent(String.self, forKey: .sub)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        meters = try container.decodeIfPresent([Meter].self, forKey: .meters) ?? []
        rows = try container.decodeIfPresent([ModelRow].self, forKey: .rows) ?? []
        stats = try container.decodeIfPresent([Stat].self, forKey: .stats) ?? []
        note = try container.decodeIfPresent(String.self, forKey: .note)
        state = try container.decode(String.self, forKey: .state)
    }
}

/// Optional ~/.config/agent-widgets/panel.json. Everything has a default, so a
/// missing or malformed file is not an error.
struct PanelConfig: Decodable {
    var screen: Int?
    var corner: String?
    var margin: CGFloat?
    var theme: String?

    static func load(_ path: String) -> PanelConfig {
        guard let data = FileManager.default.contents(atPath: path),
              let config = try? JSONDecoder().decode(PanelConfig.self, from: data)
        else { return PanelConfig() }
        return config
    }

    /// Defaults to the display holding the menu bar, which is stable — unlike
    /// NSScreen.main, which follows keyboard focus between displays.
    func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let index = screen, screens.indices.contains(index) { return screens[index] }
        return screens.first
    }

    func origin(in visible: NSRect, size: NSSize) -> NSPoint {
        let inset = margin ?? Style.screenMargin
        let top = visible.maxY - size.height - inset
        let bottom = visible.minY + inset
        let left = visible.minX + inset
        let right = visible.maxX - size.width - inset
        switch (corner ?? "topRight").lowercased() {
        case "topleft": return NSPoint(x: left, y: top)
        case "bottomleft": return NSPoint(x: left, y: bottom)
        case "bottomright": return NSPoint(x: right, y: bottom)
        default: return NSPoint(x: right, y: top)
        }
    }
}

struct Snapshot: Decodable {
    let fetchedAt: Int
    let stale: Bool
    let cards: [Card]

    enum CodingKeys: String, CodingKey {
        case fetchedAt = "fetched_at"
        case stale, cards
    }

    func card(_ id: String) -> Card? { cards.first { $0.id == id } }

    func meter(_ cardID: String, _ name: String) -> Meter? {
        card(cardID)?.meters.first { $0.name == name }
    }

    func stat(_ cardID: String, _ label: String) -> Stat? {
        card(cardID)?.stats.first { $0.label == label }
    }
}

// MARK: - Layout & style

enum Style {
    static let panelWidth: CGFloat = 236
    static let padding: CGFloat = 16
    static let topPadding: CGFloat = 14
    static let cornerRadius: CGFloat = 16

    static let cardGap: CGFloat = 14
    static let ruleGap: CGFloat = 13
    static let headGap: CGFloat = 9
    static let meterGap: CGFloat = 8

    static let trackHeight: CGFloat = 4
    static let labelGap: CGFloat = 4

    static let screenMargin: CGFloat = 24

    static let title = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let sub = NSFont.systemFont(ofSize: 9.5, weight: .medium)
    static let meterLabel = NSFont.systemFont(ofSize: 10, weight: .regular)
    static let pct = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

    static let primary = NSColor(white: 0.95, alpha: 1)
    static let secondary = NSColor(white: 0.95, alpha: 0.62)
    static let tertiary = NSColor(white: 0.95, alpha: 0.42)
    static let track = NSColor(white: 1, alpha: 0.11)
    static let rule = NSColor(white: 1, alpha: 0.07)
    static let warn = NSColor(red: 1, green: 0.84, blue: 0.48, alpha: 0.92)

    static let barHeight: CGFloat = 6
    static let barGap: CGFloat = 2      // surface gap between stacked segments
    static let swatch: CGFloat = 6
    static let rowGap: CGFloat = 6
    static let statCell: CGFloat = 23
    static let statValue = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

    /// Categorical slots, in fixed order, assigned per model and never by rank.
    /// These are the dataviz dark-mode steps; validated as a 5-set against this
    /// panel's surface (lightness band, chroma floor, adjacent CVD ΔE 8.4,
    /// normal-vision ΔE 19.3, contrast ≥ 3:1).
    static let series: [NSColor] = [
        NSColor(srgbRed: 0x39 / 255, green: 0x87 / 255, blue: 0xE5 / 255, alpha: 1),
        NSColor(srgbRed: 0xD9 / 255, green: 0x59 / 255, blue: 0x26 / 255, alpha: 1),
        NSColor(srgbRed: 0x19 / 255, green: 0x9E / 255, blue: 0x70 / 255, alpha: 1),
        NSColor(srgbRed: 0xC9 / 255, green: 0x85 / 255, blue: 0x00 / 255, alpha: 1),
        NSColor(srgbRed: 0xD5 / 255, green: 0x51 / 255, blue: 0x81 / 255, alpha: 1),
    ]
    static let other = NSColor(white: 0.56, alpha: 1)

    static func seriesColor(_ slot: Int) -> NSColor {
        series.indices.contains(slot) ? series[slot] : other
    }

    static func meterColor(_ remaining: Int) -> NSColor {
        if remaining > 40 { return NSColor(red: 0.35, green: 0.82, blue: 0.50, alpha: 1) }
        if remaining >= 15 { return NSColor(red: 0.96, green: 0.71, blue: 0.27, alpha: 1) }
        return NSColor(red: 1.0, green: 0.37, blue: 0.34, alpha: 1)
    }
}

func compactTokens(_ value: Int) -> String {
    if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
    if value >= 1_000 { return "\(value / 1000)K" }
    return "\(value)"
}

func countdown(_ resetsAt: Int?) -> String? {
    guard let resetsAt else { return nil }
    let secs = resetsAt - Int(Date().timeIntervalSince1970)
    if secs <= 0 { return "resetting" }
    let days = secs / 86400
    let hours = (secs % 86400) / 3600
    let mins = (secs % 3600) / 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(mins)m" }
    return "\(mins)m"
}

// MARK: - Seven-segment numerals
//
// Drawn as bezier paths rather than set in a font: macOS ships no segmented
// face, and paths let unlit segments show at low alpha the way a real VFD does.

enum SevenSegment {
    /// Segment order: a top, b upper-right, c lower-right, d bottom,
    /// e lower-left, f upper-left, g middle.
    private static let masks: [Character: [Bool]] = [
        "0": [true, true, true, true, true, true, false],
        "1": [false, true, true, false, false, false, false],
        "2": [true, true, false, true, true, false, true],
        "3": [true, true, true, true, false, false, true],
        "4": [false, true, true, false, false, true, true],
        "5": [true, false, true, true, false, true, true],
        "6": [true, false, true, true, true, true, true],
        "7": [true, true, true, false, false, false, false],
        "8": [true, true, true, true, true, true, true],
        "9": [true, true, true, true, false, true, true],
        "-": [false, false, false, false, false, false, true],
    ]

    struct Metrics {
        var width: CGFloat
        var height: CGFloat
        var thickness: CGFloat
        var gap: CGFloat = 1.5
        var slant: CGFloat = 0.08   // italic lean, as real clusters have
        var spacing: CGFloat = 5
    }

    /// Tapered bar, mitred at both ends — the classic segment silhouette.
    private static func bar(from start: NSPoint, to end: NSPoint,
                            thickness: CGFloat, horizontal: Bool) -> NSBezierPath {
        let half = thickness / 2
        let path = NSBezierPath()
        if horizontal {
            path.move(to: NSPoint(x: start.x, y: start.y))
            path.line(to: NSPoint(x: start.x + half, y: start.y - half))
            path.line(to: NSPoint(x: end.x - half, y: end.y - half))
            path.line(to: NSPoint(x: end.x, y: end.y))
            path.line(to: NSPoint(x: end.x - half, y: end.y + half))
            path.line(to: NSPoint(x: start.x + half, y: start.y + half))
        } else {
            path.move(to: NSPoint(x: start.x, y: start.y))
            path.line(to: NSPoint(x: start.x + half, y: start.y + half))
            path.line(to: NSPoint(x: end.x + half, y: end.y - half))
            path.line(to: NSPoint(x: end.x, y: end.y))
            path.line(to: NSPoint(x: end.x - half, y: end.y - half))
            path.line(to: NSPoint(x: start.x - half, y: start.y + half))
        }
        path.close()
        return path
    }

    /// Draws one glyph with its origin at the top-left, in a flipped view.
    static func draw(_ character: Character, at origin: NSPoint, metrics m: Metrics,
                     lit: NSColor, unlit: NSColor?) {
        // No entry means no glyph at all — not an all-unlit one. A blank cell
        // holds its width (the caller still advances x) but paints nothing, so
        // "blank, nothing to say" stays distinct from a dash meaning "no data".
        guard let mask = masks[character] else { return }
        let w = m.width, h = m.height, t = m.thickness, g = m.gap
        let mid = h / 2

        // Shear so the top of the glyph leans right, like a real cluster face.
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: origin.x + x + (h - y) * m.slant, y: origin.y + y)
        }

        // Verticals run almost the full half-height, stopping only a hair short
        // of the middle bar. Insetting them by a whole segment thickness (the
        // obvious-looking choice) leaves stubs, and the digits stop reading.
        let insetX = t / 2 + g
        let capY = t / 2 + g * 0.6
        let midGap = t / 2
        let segments: [(NSBezierPath, Bool)] = [
            (bar(from: point(insetX, t / 2), to: point(w - insetX, t / 2),
                 thickness: t, horizontal: true), mask[0]),
            (bar(from: point(w - t / 2, capY), to: point(w - t / 2, mid - midGap),
                 thickness: t, horizontal: false), mask[1]),
            (bar(from: point(w - t / 2, mid + midGap), to: point(w - t / 2, h - capY),
                 thickness: t, horizontal: false), mask[2]),
            (bar(from: point(insetX, h - t / 2), to: point(w - insetX, h - t / 2),
                 thickness: t, horizontal: true), mask[3]),
            (bar(from: point(t / 2, mid + midGap), to: point(t / 2, h - capY),
                 thickness: t, horizontal: false), mask[4]),
            (bar(from: point(t / 2, capY), to: point(t / 2, mid - midGap),
                 thickness: t, horizontal: false), mask[5]),
            (bar(from: point(insetX, mid), to: point(w - insetX, mid),
                 thickness: t, horizontal: true), mask[6]),
        ]

        for (path, isLit) in segments {
            if isLit {
                lit.setFill()
                path.fill()
            } else if let unlit {
                unlit.setFill()
                path.fill()
            }
        }
    }

    /// Unlit-segment alpha, scaled by digit height.
    ///
    /// A single constant cannot work: lit and unlit are the same hue, so at a
    /// large size the ghosts need to be visible enough to read as an unlit
    /// display, while at small sizes that same alpha closes the gaps and turns
    /// the digit into a blob. Big digits get 0.13, small ones 0.055.
    static func ghostAlpha(height: CGFloat) -> CGFloat {
        let t = max(0, min(1, (height - 24) / 28))
        return 0.055 + t * (0.13 - 0.055)
    }

    static func ghost(_ color: NSColor, metrics m: Metrics) -> NSColor {
        color.withAlphaComponent(ghostAlpha(height: m.height))
    }

    static func width(_ text: String, metrics m: Metrics) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return CGFloat(text.count) * m.width
            + CGFloat(text.count - 1) * m.spacing + m.height * m.slant
    }

    static func draw(_ text: String, at origin: NSPoint, metrics m: Metrics,
                     lit: NSColor, unlit: NSColor?) {
        var x = origin.x
        for character in text {
            draw(character, at: NSPoint(x: x, y: origin.y), metrics: m,
                 lit: lit, unlit: unlit)
            x += m.width + m.spacing
        }
    }
}

// MARK: - Cluster primitives
//
// The vocabulary a digital dash is built from: segmented bar graphs where the
// unlit segments stay faintly visible, hairline boxes, tick ramps, and tiny
// tracked-out caps labels.

enum Gauge {
    /// Segmented bar. `fraction` 0...1 lights that share of `segments`, always
    /// at least one segment once the value is above zero — a real gauge never
    /// reads as completely dead when it isn't.
    static func bar(in rect: NSRect, segments: Int, fraction: Double,
                    lit: NSColor, unlit: NSColor, gap: CGFloat = 2,
                    vertical: Bool = false) {
        guard segments > 0 else { return }
        let clamped = max(0, min(1, fraction))
        var litCount = Int((Double(segments) * clamped).rounded())
        if clamped > 0 { litCount = max(1, litCount) }

        let span = (vertical ? rect.height : rect.width) - CGFloat(segments - 1) * gap
        let size = span / CGFloat(segments)
        guard size > 0 else { return }

        for index in 0..<segments {
            let offset = CGFloat(index) * (size + gap)
            let cell: NSRect
            if vertical {
                // Vertical bars fill from the bottom up.
                cell = NSRect(x: rect.minX, y: rect.maxY - offset - size,
                              width: rect.width, height: size)
            } else {
                cell = NSRect(x: rect.minX + offset, y: rect.minY,
                              width: size, height: rect.height)
            }
            (index < litCount ? lit : unlit).setFill()
            cell.fill()
        }
    }

    /// Rising tick ramp, as on a Uno Turbo tacho: tick height grows across the
    /// span so the scale reads as acceleration even when standing still.
    static func ramp(in rect: NSRect, ticks: Int, fraction: Double,
                     lit: NSColor, unlit: NSColor, gap: CGFloat = 2) {
        guard ticks > 0 else { return }
        let clamped = max(0, min(1, fraction))
        var litCount = Int((Double(ticks) * clamped).rounded())
        if clamped > 0 { litCount = max(1, litCount) }

        let width = (rect.width - CGFloat(ticks - 1) * gap) / CGFloat(ticks)
        guard width > 0 else { return }

        for index in 0..<ticks {
            let progress = CGFloat(index) / CGFloat(max(1, ticks - 1))
            let height = rect.height * (0.28 + 0.72 * progress)
            let cell = NSRect(x: rect.minX + CGFloat(index) * (width + gap),
                              y: rect.maxY - height, width: width, height: height)
            (index < litCount ? lit : unlit).setFill()
            cell.fill()
        }
    }

    /// One-pixel box. Insetting by half a point keeps the stroke crisp rather
    /// than straddling the pixel grid.
    static func box(_ rect: NSRect, color: NSColor, radius: CGFloat = 3,
                    width: CGFloat = 1) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: width / 2, dy: width / 2),
                                xRadius: radius, yRadius: radius)
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }

    /// Tiny tracked-out caps, the label style every cluster in the world uses.
    @discardableResult
    static func label(_ text: String, at point: NSPoint, font: NSFont,
                      color: NSColor, tracking: CGFloat = 0.9,
                      alignRight: Bool = false) -> CGFloat {
        let string = NSAttributedString(string: text.uppercased(), attributes: [
            .font: font, .foregroundColor: color, .kern: tracking,
        ])
        let width = string.size().width
        string.draw(at: NSPoint(x: alignRight ? point.x - width : point.x, y: point.y))
        return width
    }
}

// MARK: - Themes

/// A theme is a view that knows its own size and chrome. The controller swaps
/// the whole view when `panel.json` names a different one.
class ThemeView: NSView {
    var snapshot: Snapshot? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    class var themeName: String { "" }
    var panelWidth: CGFloat { Style.panelWidth }
    var fittingHeight: CGFloat { 60 }
    /// HUD sits on a translucent blur; the cluster wants opaque near-black,
    /// the way a real instrument binnacle does.
    var usesBlur: Bool { true }
    var backdropColor: NSColor { .clear }
    var cornerRadius: CGFloat { Style.cornerRadius }
    var borderColor: NSColor { NSColor(white: 1, alpha: 0.09) }

    static func make(_ name: String?) -> ThemeView {
        switch (name ?? "hud").lowercased() {
        case "cluster": return ClusterView()
        default: return PanelView()
        }
    }
}

// MARK: - HUD theme

final class PanelView: ThemeView {
    override class var themeName: String { "hud" }

    /// Height this view needs for the current snapshot. Kept in step with draw().
    override var fittingHeight: CGFloat {
        guard let snapshot, !snapshot.cards.isEmpty else { return 60 }
        var height = Style.topPadding
        for (index, card) in snapshot.cards.enumerated() {
            if index > 0 { height += Style.cardGap + Style.ruleGap }
            height += cardHeight(card)
        }
        return height + Style.padding - 2
    }

    private func cardHeight(_ card: Card) -> CGFloat {
        var height = Style.title.capHeight + 6 + Style.headGap

        if card.isModels {
            if card.rows.isEmpty { return height + 14 }
            height += Style.barHeight + Style.headGap
            for (index, _) in card.rows.enumerated() {
                if index > 0 { height += Style.rowGap }
                height += Style.meterLabel.pointSize + 2
            }
            return height
        }

        let rows = visibleMeters(card)
        if rows.isEmpty {
            height += 14
        } else {
            for (index, _) in rows.enumerated() {
                if index > 0 { height += Style.meterGap }
                height += Style.meterLabel.pointSize + Style.labelGap + Style.trackHeight
            }
        }
        if card.isHealth, !card.stats.isEmpty, !rows.isEmpty {
            let gridRows = (card.stats.count + 1) / 2
            height += Style.headGap + CGFloat(gridRows) * Style.statCell
                + CGFloat(gridRows - 1) * Style.rowGap
        }
        if let note = noteText(card), !note.isEmpty, !rows.isEmpty {
            height += 6 + Style.meterLabel.pointSize
        }
        return height
    }

    private func visibleMeters(_ card: Card) -> [Meter] {
        card.state == "reauth" ? [] : card.meters
    }

    private func noteText(_ card: Card) -> String? {
        if let note = card.note, !note.isEmpty { return note }
        switch card.state {
        case "reauth": return "sign in again"
        case "blocked": return "rate limited · retrying"
        case "stale": return "stale"
        default: return nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let snapshot, !snapshot.cards.isEmpty else {
            drawText("collector unavailable", font: Style.meterLabel, color: Style.warn,
                     at: NSPoint(x: Style.padding, y: Style.topPadding))
            return
        }

        let left = Style.padding
        let right = bounds.width - Style.padding
        var y = Style.topPadding

        for (index, card) in snapshot.cards.enumerated() {
            if index > 0 {
                y += Style.cardGap
                Style.rule.setFill()
                NSRect(x: left, y: y, width: right - left, height: 1).fill()
                y += Style.ruleGap
            }

            let dim: CGFloat = card.state == "ok" ? 1.0 : 0.45

            drawText(card.label, font: Style.title, color: Style.primary.withAlphaComponent(dim),
                     at: NSPoint(x: left, y: y))
            if let sub = card.sub?.uppercased() {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: Style.sub,
                    .foregroundColor: Style.tertiary.withAlphaComponent(0.42 * dim),
                    .kern: 0.8,
                ]
                let text = NSAttributedString(string: sub, attributes: attrs)
                text.draw(at: NSPoint(x: right - text.size().width, y: y + 2))
            }
            y += Style.title.capHeight + 6 + Style.headGap

            if card.isModels {
                y = drawModels(card, left: left, right: right, y: y, dim: dim)
                continue
            }

            let rows = visibleMeters(card)
            if rows.isEmpty {
                let note = noteText(card) ?? "no data"
                drawText(note, font: Style.meterLabel, color: Style.warn, at: NSPoint(x: left, y: y))
                y += 14
                continue
            }

            for (rowIndex, meter) in rows.enumerated() {
                if rowIndex > 0 { y += Style.meterGap }

                drawText(meter.name, font: Style.meterLabel,
                         color: Style.secondary.withAlphaComponent(0.62 * dim),
                         at: NSPoint(x: left, y: y))

                let value = NSMutableAttributedString(
                    string: meter.readout,
                    attributes: [.font: Style.pct,
                                 .foregroundColor: Style.primary.withAlphaComponent(0.92 * dim)])
                if let reset = countdown(meter.resetsAt) {
                    value.append(NSAttributedString(
                        string: " · \(reset)",
                        attributes: [.font: Style.meterLabel,
                                     .foregroundColor: Style.secondary.withAlphaComponent(0.62 * dim)]))
                }
                value.draw(at: NSPoint(x: right - value.size().width, y: y))
                y += Style.meterLabel.pointSize + Style.labelGap

                let trackRect = NSRect(x: left, y: y, width: right - left, height: Style.trackHeight)
                Style.track.withAlphaComponent(0.11 * dim).setFill()
                NSBezierPath(roundedRect: trackRect, xRadius: 2, yRadius: 2).fill()

                let ratio = CGFloat(max(2, min(100, meter.remaining))) / 100
                let fillRect = NSRect(x: left, y: y, width: trackRect.width * ratio,
                                      height: Style.trackHeight)
                Style.meterColor(meter.remaining).withAlphaComponent(dim).setFill()
                NSBezierPath(roundedRect: fillRect, xRadius: 2, yRadius: 2).fill()
                y += Style.trackHeight
            }

            if card.isHealth, !card.stats.isEmpty {
                y += Style.headGap
                y = drawStatGrid(card.stats, left: left, right: right, y: y, dim: dim)
            }

            if let note = noteText(card) {
                y += 6
                drawText(note, font: Style.meterLabel,
                         color: card.state == "stale" ? Style.tertiary : Style.warn,
                         at: NSPoint(x: left, y: y))
                y += Style.meterLabel.pointSize
            }
        }
    }

    /// Two-column grid for readings with no natural 0-100 scale (bpm, HRV
    /// status), which would be misleading drawn as a meter.
    private func drawStatGrid(_ stats: [Stat], left: CGFloat, right: CGFloat,
                              y startY: CGFloat, dim: CGFloat) -> CGFloat {
        var y = startY
        let columnWidth = (right - left) / 2

        for index in stride(from: 0, to: stats.count, by: 2) {
            if index > 0 { y += Style.rowGap }
            for column in 0..<2 where index + column < stats.count {
                let stat = stats[index + column]
                let x = left + CGFloat(column) * columnWidth

                let label = NSAttributedString(string: stat.label.uppercased(), attributes: [
                    .font: Style.sub,
                    .foregroundColor: Style.tertiary.withAlphaComponent(0.42 * dim),
                    .kern: 0.6,
                ])
                label.draw(at: NSPoint(x: x, y: y))
                drawText(stat.value, font: Style.statValue,
                         color: Style.primary.withAlphaComponent(0.92 * dim),
                         at: NSPoint(x: x, y: y + Style.sub.pointSize + 2))
            }
            y += Style.statCell
        }
        return y
    }

    /// Share bar + ranked rows. Identity is carried by a swatch beside each
    /// name, never by the text colour, so the rows read as their own legend.
    private func drawModels(_ card: Card, left: CGFloat, right: CGFloat,
                            y startY: CGFloat, dim: CGFloat) -> CGFloat {
        var y = startY
        guard !card.rows.isEmpty else {
            drawText("no sessions yet", font: Style.meterLabel, color: Style.tertiary,
                     at: NSPoint(x: left, y: y))
            return y + 14
        }

        let total = max(1, card.rows.reduce(0) { $0 + $1.value })
        let gaps = CGFloat(max(0, card.rows.count - 1)) * Style.barGap
        let usable = (right - left) - gaps
        var x = left
        for row in card.rows {
            let width = max(2, usable * CGFloat(row.value) / CGFloat(total))
            let rect = NSRect(x: x, y: y, width: width, height: Style.barHeight)
            Style.seriesColor(row.slot).withAlphaComponent(dim).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            x += width + Style.barGap
        }
        y += Style.barHeight + Style.headGap

        for (index, row) in card.rows.enumerated() {
            if index > 0 { y += Style.rowGap }

            let swatch = NSRect(x: left, y: y + 2, width: Style.swatch, height: Style.swatch)
            Style.seriesColor(row.slot).withAlphaComponent(dim).setFill()
            NSBezierPath(roundedRect: swatch, xRadius: 2, yRadius: 2).fill()

            drawText(row.label, font: Style.meterLabel,
                     color: Style.primary.withAlphaComponent(0.85 * dim),
                     at: NSPoint(x: left + Style.swatch + 7, y: y))

            let value = NSMutableAttributedString(
                string: compactTokens(row.value),
                attributes: [.font: Style.meterLabel,
                             .foregroundColor: Style.secondary.withAlphaComponent(0.62 * dim)])
            value.append(NSAttributedString(
                string: "  \(row.share)%",
                attributes: [.font: Style.pct,
                             .foregroundColor: Style.primary.withAlphaComponent(0.92 * dim)]))
            value.draw(at: NSPoint(x: right - value.size().width, y: y))

            y += Style.meterLabel.pointSize + 2
        }
        return y
    }

    private func drawText(_ string: String, font: NSFont, color: NSColor, at point: NSPoint) {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
            .draw(at: point)
    }
}

// MARK: - Cluster theme
//
// A JDM digital instrument cluster. Filled in from the design spec.

enum VFD {
    // Self-luminous phosphor colours on near-black, in the cyan-teal family of
    // the 80s Nissan/Toyota clusters. Ordered so adjacent share-bar segments
    // stay separable: CVD ΔE 16.9, normal-vision ΔE 32.1, all ≥ 3:1 on #050505.
    // (These sit above the dataviz lightness band on purpose — a VFD is a lamp,
    // not ink on a surface, and dimming them kills the glow.)
    static let cyan = NSColor(srgbRed: 0x3F / 255, green: 0xF0 / 255, blue: 0xDC / 255, alpha: 1)
    static let magenta = NSColor(srgbRed: 0xFF / 255, green: 0x3D / 255, blue: 0xA5 / 255, alpha: 1)
    static let green = NSColor(srgbRed: 0xA8 / 255, green: 0xE8 / 255, blue: 0x5C / 255, alpha: 1)
    static let blue = NSColor(srgbRed: 0x5A / 255, green: 0xA9 / 255, blue: 0xFF / 255, alpha: 1)
    static let amber = NSColor(srgbRed: 0xFF / 255, green: 0xB0 / 255, blue: 0x00 / 255, alpha: 1)
    /// Critical only. Magenta is spoken for by `reauth`, and the LOW lamp sits
    /// beside the source lamps — so the two would collide on the same surface.
    static let red = NSColor(srgbRed: 0xFF / 255, green: 0x4A / 255, blue: 0x3D / 255, alpha: 1)

    /// Model-mix palette. Deliberately contains no amber and no magenta: those
    /// two carry status here, and a model colour that looks like an alarm is a
    /// bug. Validated on #050505 — CVD ΔE 12.1, normal-vision 16.0, all ≥ 3:1.
    /// (Only the lightness band fails, which is the VFD-brightness departure.)
    static let series = [
        NSColor(srgbRed: 0x3B / 255, green: 0xE8 / 255, blue: 0xD8 / 255, alpha: 1),
        NSColor(srgbRed: 0x9B / 255, green: 0xE8 / 255, blue: 0x4F / 255, alpha: 1),
        NSColor(srgbRed: 0x5A / 255, green: 0x8C / 255, blue: 0xFF / 255, alpha: 1),
        // Teal sits at index 3 on purpose. Slots are assigned to models on first
        // sight and persisted, and this machine's slot 3 holds a model that
        // never charts — so the four hues that actually appear together are the
        // widely-separated ones, and teal never has to sit beside cyan.
        NSColor(srgbRed: 0x40 / 255, green: 0xB0 / 255, blue: 0xA0 / 255, alpha: 1),
        NSColor(srgbRed: 0xD9 / 255, green: 0xA8 / 255, blue: 0xFF / 255, alpha: 1),
    ]
    /// Only the "Other" bucket, never a named model.
    static let otherGrey = NSColor(srgbRed: 0x7A / 255, green: 0x8A / 255, blue: 0x90 / 255, alpha: 1)
    static let label = NSColor(srgbRed: 0x49 / 255, green: 0xC2 / 255, blue: 0xD4 / 255, alpha: 1)
    static let hairline = NSColor(srgbRed: 0x1B / 255, green: 0x5E / 255, blue: 0x66 / 255, alpha: 1)

    static func ghost(_ color: NSColor) -> NSColor { color.withAlphaComponent(0.11) }

    /// Gauge colour by how much is left. Same semantics as the HUD theme, in
    /// cluster phosphors: healthy cyan, warning amber, critical magenta.
    static func level(_ remaining: Int) -> NSColor {
        if remaining > 40 { return cyan }
        if remaining >= 15 { return amber }
        return red
    }

    static func slot(_ index: Int) -> NSColor {
        series.indices.contains(index) ? series[index] : otherGrey
    }
}

final class ClusterView: ThemeView {
    override class var themeName: String { "cluster" }

    override var panelWidth: CGFloat { 700 }
    override var usesBlur: Bool { false }
    override var backdropColor: NSColor { NSColor(srgbRed: 0.02, green: 0.02, blue: 0.024, alpha: 0.97) }
    override var cornerRadius: CGFloat { 8 }
    override var borderColor: NSColor { VFD.hairline.withAlphaComponent(0.5) }
    override var fittingHeight: CGFloat { 340 }

    private let pad: CGFloat = 12

    // Condensed caps: the silkscreen label face both reference clusters use.
    private static func condensed(_ size: CGFloat) -> NSFont {
        NSFont(name: "AvenirNextCondensed-DemiBold", size: size)
            ?? NSFont.systemFont(ofSize: size, weight: .semibold)
    }
    private let capsTiny = ClusterView.condensed(9)
    private let capsSmall = ClusterView.condensed(10)

    private let hero = SevenSegment.Metrics(width: 40, height: 66, thickness: 8.5,
                                            gap: 2.2, slant: 0.09, spacing: 9)
    private let rowSeg = SevenSegment.Metrics(width: 18, height: 30, thickness: 4.1,
                                              gap: 1.2, slant: 0.09, spacing: 4.5)
    private let midSeg = SevenSegment.Metrics(width: 18, height: 30, thickness: 3.9,
                                              gap: 1.1, slant: 0.09, spacing: 4.5)
    private let tinySeg = SevenSegment.Metrics(width: 12, height: 21, thickness: 2.8,
                                               gap: 0.9, slant: 0.09, spacing: 3)
    // Sized so a three-digit reading plus its unit clears the readings cell.
    private let readSeg = SevenSegment.Metrics(width: 16, height: 27, thickness: 3.4,
                                               gap: 1.0, slant: 0.09, spacing: 3.8)

    override func draw(_ dirtyRect: NSRect) {
        guard let snapshot else {
            Gauge.label("no signal", at: NSPoint(x: pad, y: pad),
                        font: capsSmall, color: VFD.amber)
            return
        }

        // Boxed panels, as on the 80s Nissan/Toyota faces: every instrument
        // lives inside its own hairline frame with a tiny caps title.
        // Left column is budget; right side is body and model mix.
        let heroBox = NSRect(x: 12, y: 14, width: 280, height: 158)
        let rampBox = NSRect(x: 304, y: 14, width: 384, height: 158)
        let quotaBox = NSRect(x: 12, y: 186, width: 280, height: 140)
        let vitalsBox = NSRect(x: 304, y: 186, width: 180, height: 140)
        let readBox = NSRect(x: 496, y: 186, width: 192, height: 140)

        for box in [heroBox, rampBox, quotaBox, vitalsBox, readBox] {
            Gauge.box(box, color: VFD.hairline.withAlphaComponent(0.85), radius: 4)
        }

        drawSpeedo(snapshot, in: heroBox)
        drawModelRamp(snapshot, in: rampBox)
        drawQuota(snapshot, in: quotaBox)
        drawGauges(snapshot, in: vitalsBox)
        drawReadouts(snapshot, in: readBox)
    }

    /// Panel title, sitting on the box's top edge the way a real face does.
    /// It knocks a hole in the stroke by painting `backdropColor` opaquely, so
    /// this only works on an opaque theme — a blurred theme would need the gap
    /// cut from the box path instead.
    private func title(_ text: String, in box: NSRect, dim: CGFloat, tag: String? = nil,
                       tagColor: NSColor? = nil) {
        let width = Gauge.label(text, at: NSPoint(x: 0, y: -200), font: capsTiny,
                                color: .clear)
        backdropColor.withAlphaComponent(1).setFill()
        NSRect(x: box.minX + 9, y: box.minY - 5, width: width + 9, height: 10).fill()
        Gauge.label(text, at: NSPoint(x: box.minX + 13, y: box.minY - 5),
                    font: capsTiny, color: VFD.label.withAlphaComponent(0.85 * dim))

        if let tag {
            let tagWidth = Gauge.label(tag, at: NSPoint(x: 0, y: -200), font: capsTiny,
                                       color: .clear)
            backdropColor.withAlphaComponent(1).setFill()
            NSRect(x: box.maxX - 13 - tagWidth - 5, y: box.minY - 5,
                   width: tagWidth + 9, height: 10).fill()
            Gauge.label(tag, at: NSPoint(x: box.maxX - 13, y: box.minY - 5),
                        font: capsTiny,
                        color: (tagColor ?? VFD.label).withAlphaComponent(dim),
                        alignRight: true)
        }
    }

    private func alpha(_ card: Card?) -> CGFloat {
        (card?.state ?? "ok") == "ok" ? 1 : 0.42
    }

    /// The state word a box wears in its title rail. `nil` when healthy.
    private func stateTag(_ card: Card?) -> (String, NSColor)? {
        switch card?.state {
        case "stale": return ("stale", VFD.amber)
        case "blocked": return ("limit", VFD.amber)
        case "reauth": return ("auth", VFD.magenta)
        default: return nil
        }
    }

    /// Hero numeral: the Claude 5h window, the number checked most often.
    private func drawSpeedo(_ snapshot: Snapshot, in box: NSRect) {
        let card = snapshot.card("claude")
        let dim = alpha(card)
        let meter = snapshot.meter("claude", "5h")
        let state = stateTag(card)
        title("claude code", in: box, dim: dim, tag: state?.0 ?? "5h window",
              tagColor: state?.1)

        let x = box.minX + 16
        // Leading blanks stay unlit rather than padded with zeros — that is how
        // a real cluster reads, and it keeps the digits in a fixed position.
        let text = meter.map { String(format: "%3d", $0.remaining) } ?? "---"
        let colour = meter.map { VFD.level($0.remaining) } ?? VFD.cyan
        SevenSegment.draw(text, at: NSPoint(x: x, y: box.minY + 22), metrics: hero,
                          lit: colour.withAlphaComponent(dim),
                          unlit: SevenSegment.ghost(VFD.cyan, metrics: hero))

        let numeralWidth = SevenSegment.width(text, metrics: hero)
        NSAttributedString(string: "%", attributes: [
            .font: NSFont.systemFont(ofSize: 26, weight: .light),
            .foregroundColor: colour.withAlphaComponent(0.9 * dim),
        ]).draw(at: NSPoint(x: x + numeralWidth + 5, y: box.minY + 52))

        Gauge.label("5h remaining", at: NSPoint(x: x, y: box.minY + 100),
                    font: capsTiny, color: VFD.label.withAlphaComponent(0.7 * dim))

        // Hero bar: the same figure as a shape, for when the digits are too far
        // away to read.
        Gauge.bar(in: NSRect(x: x, y: box.minY + 116, width: box.maxX - 16 - x, height: 11),
                  segments: 24, fraction: Double(meter?.remaining ?? 0) / 100,
                  lit: colour.withAlphaComponent(dim),
                  unlit: VFD.cyan.withAlphaComponent(0.10), gap: 2.4)

        Gauge.label("reset", at: NSPoint(x: x, y: box.minY + 136), font: capsTiny,
                    color: VFD.label.withAlphaComponent(0.55 * dim))
        Gauge.label((countdown(meter?.resetsAt) ?? "—"),
                    at: NSPoint(x: box.maxX - 16, y: box.minY + 136),
                    font: capsSmall, color: VFD.label.withAlphaComponent(dim),
                    alignRight: true)
    }

    /// Tacho ramp: the 7-day model mix. Ticks-per-model encodes share and tick
    /// height encodes share too — redundant on purpose, so the silhouette alone
    /// says whether you are mono-model or spread. Sorted descending, which is
    /// what makes a rank-ordered bar chart look like a tacho wedge.
    private func drawModelRamp(_ snapshot: Snapshot, in box: NSRect) {
        let card = snapshot.card("models")
        let dim = alpha(card)
        let rows = card?.rows ?? []
        title("model mix", in: box, dim: dim, tag: "7 day")

        let x = box.minX + 14
        let right = box.maxX - 14
        let rampRect = NSRect(x: x, y: box.minY + 20, width: right - x, height: 62)
        let ticks = 40
        let gap: CGFloat = 3.4
        let tickWidth = (rampRect.width - CGFloat(ticks - 1) * gap) / CGFloat(ticks)

        guard !rows.isEmpty else {
            for index in 0..<ticks {
                VFD.cyan.withAlphaComponent(0.10).setFill()
                NSRect(x: rampRect.minX + CGFloat(index) * (tickWidth + gap),
                       y: rampRect.maxY - 18, width: tickWidth, height: 18).fill()
            }
            Gauge.label("no data", at: NSPoint(x: box.midX - 20, y: box.minY + 96),
                        font: capsSmall, color: VFD.label.withAlphaComponent(0.4))
            return
        }

        // Tick runs, with the residual absorbed by the largest run so the ramp
        // always totals exactly 40.
        let total = max(1, rows.reduce(0) { $0 + $1.value })
        var counts = rows.map { max(1, Int((Double(ticks) * Double($0.value)
                                            / Double(total)).rounded())) }
        var residual = ticks - counts.reduce(0, +)
        if let largest = counts.indices.max(by: { counts[$0] < counts[$1] }) {
            counts[largest] = max(1, counts[largest] + residual)
            residual = 0
        }

        let maxShare = Double(rows.map(\.share).max() ?? 1)
        var index = 0
        var runCentres: [CGFloat] = []
        for (row, count) in zip(rows, counts) {
            let start = index
            // Height encodes share as well, so the leading model always reaches
            // full height and the ramp uses its whole range at any spread.
            let height = 16 + 46 * CGFloat(Double(row.share) / max(1, maxShare))
            for _ in 0..<count where index < ticks {
                let tickX = rampRect.minX + CGFloat(index) * (tickWidth + gap)
                VFD.slot(row.slot).withAlphaComponent(0.9 * dim).setFill()
                NSRect(x: tickX, y: rampRect.maxY - height,
                       width: tickWidth, height: height).fill()
                index += 1
            }
            let runWidth = CGFloat(index - start) * (tickWidth + gap) - gap
            runCentres.append(rampRect.minX + CGFloat(start) * (tickWidth + gap)
                              + runWidth / 2)
        }

        // Ruler under the ramp, unlabelled — the legend carries exact figures.
        VFD.hairline.withAlphaComponent(0.6 * dim).setFill()
        NSRect(x: x, y: rampRect.maxY + 3, width: right - x, height: 1).fill()

        // Legend in even columns, not proportional to run width: a 9% run is far
        // too narrow to hold a name, a count and a percent.
        let columns = min(rows.count, 4)
        let columnWidth = (right - x) / CGFloat(columns)
        for (offset, row) in rows.prefix(columns).enumerated() {
            let columnX = x + CGFloat(offset) * columnWidth
            let colour = VFD.slot(row.slot)

            // Leader tying the legend column back to its run on the ramp.
            if offset < runCentres.count {
                let leader = NSBezierPath()
                leader.move(to: NSPoint(x: runCentres[offset], y: rampRect.maxY + 4))
                leader.line(to: NSPoint(x: runCentres[offset], y: rampRect.maxY + 9))
                leader.line(to: NSPoint(x: columnX + 3, y: rampRect.maxY + 9))
                leader.line(to: NSPoint(x: columnX + 3, y: rampRect.maxY + 14))
                leader.lineWidth = 1
                colour.withAlphaComponent(0.45 * dim).setStroke()
                leader.stroke()
            }

            colour.withAlphaComponent(0.9 * dim).setFill()
            NSRect(x: columnX, y: box.minY + 96, width: 6, height: 6).fill()
            Gauge.label(row.label, at: NSPoint(x: columnX + 10, y: box.minY + 94),
                        font: capsTiny, color: colour.withAlphaComponent(dim))

            SevenSegment.draw(String(row.share), at: NSPoint(x: columnX, y: box.minY + 110),
                              metrics: tinySeg, lit: colour.withAlphaComponent(dim),
                              unlit: SevenSegment.ghost(VFD.cyan, metrics: tinySeg))
            let shareWidth = SevenSegment.width(String(row.share), metrics: tinySeg)
            Gauge.label("%", at: NSPoint(x: columnX + shareWidth + 4, y: box.minY + 118),
                        font: capsTiny, color: colour.withAlphaComponent(0.7 * dim))
            Gauge.label(compactTokens(row.value),
                        at: NSPoint(x: columnX, y: box.minY + 134), font: capsTiny,
                        color: VFD.label.withAlphaComponent(0.6 * dim))
        }
    }

    /// The two long-horizon windows, read deliberately rather than glanced —
    /// the odometer's job. Numeral and bar together so the shape is legible
    /// when the digits are not.
    private func drawQuota(_ snapshot: Snapshot, in box: NSRect) {
        title("week windows", in: box, dim: 1)

        let rows: [(String, Card?, Meter?, String?)] = [
            ("claude · week", snapshot.card("claude"), snapshot.meter("claude", "week"), nil),
            ("codex · week", snapshot.card("codex"), snapshot.meter("codex", "week"),
             snapshot.card("codex")?.sub),
        ]

        let x = box.minX + 14
        let right = box.maxX - 14
        for (index, row) in rows.enumerated() {
            let (label, card, meter, plan) = row
            let dim = alpha(card)
            let top = box.minY + 16 + CGFloat(index) * 62
            let colour = meter.map { VFD.level($0.remaining) } ?? VFD.cyan

            Gauge.label(label, at: NSPoint(x: x, y: top), font: capsTiny,
                        color: VFD.label.withAlphaComponent(dim))

            // The state word always wins the right-hand slot; the plan name only
            // shows when there is nothing more urgent to say.
            if let state = stateTag(card) {
                Gauge.label(state.0, at: NSPoint(x: right, y: top), font: capsTiny,
                            color: state.1, alignRight: true)
            } else if let plan {
                Gauge.label(plan, at: NSPoint(x: right, y: top), font: capsTiny,
                            color: VFD.label.withAlphaComponent(0.55), alignRight: true)
            }

            SevenSegment.draw(meter.map { String($0.remaining) } ?? "--",
                              at: NSPoint(x: x, y: top + 14), metrics: rowSeg,
                              lit: colour.withAlphaComponent(dim),
                              unlit: SevenSegment.ghost(VFD.cyan, metrics: rowSeg))
            let numeralWidth = SevenSegment.width(meter.map { String($0.remaining) } ?? "--",
                                                  metrics: rowSeg)
            Gauge.label("%", at: NSPoint(x: x + numeralWidth + 4, y: top + 32),
                        font: capsSmall, color: colour.withAlphaComponent(0.85 * dim))

            if let reset = countdown(meter?.resetsAt) {
                Gauge.label(reset, at: NSPoint(x: right, y: top + 30), font: capsSmall,
                            color: VFD.label.withAlphaComponent(0.85 * dim),
                            alignRight: true)
            }

            Gauge.bar(in: NSRect(x: x, y: top + 48, width: right - x, height: 9),
                      segments: 20, fraction: Double(meter?.remaining ?? 0) / 100,
                      lit: colour.withAlphaComponent(dim),
                      unlit: VFD.cyan.withAlphaComponent(0.10), gap: 2.4)
        }
    }

    /// Vertical bar gauges — the fuel/temp/oil row of a real dash. Three 0-100
    /// tanks that drain.
    private func drawGauges(_ snapshot: Snapshot, in box: NSRect) {
        let health = snapshot.card("garmin")
        let dim = alpha(health)
        let state = stateTag(health)
        title("vitals", in: box, dim: dim, tag: state?.0 ?? "garmin", tagColor: state?.1)

        let columns: [(String, Meter?)] = [
            ("body", snapshot.meter("garmin", "body battery")),
            ("sleep", snapshot.meter("garmin", "sleep")),
            ("steps", snapshot.meter("garmin", "steps")),
        ]

        // A shared rail: all three gauges are 0-100, so three sets of endpoint
        // numbers would be noise.
        let top = box.minY + 30
        let barHeight: CGFloat = 66
        Gauge.label("100", at: NSPoint(x: box.minX + 30, y: top - 4), font: capsTiny,
                    color: VFD.label.withAlphaComponent(0.4 * dim), alignRight: true)
        Gauge.label("0", at: NSPoint(x: box.minX + 30, y: top + barHeight - 8),
                    font: capsTiny, color: VFD.label.withAlphaComponent(0.4 * dim),
                    alignRight: true)

        for (index, column) in columns.enumerated() {
            let cx = box.minX + 42 + CGFloat(index) * 44
            let value = column.1?.remaining
            let colour = value.map { VFD.level($0) } ?? VFD.cyan

            Gauge.bar(in: NSRect(x: cx, y: top, width: 24, height: barHeight),
                      segments: 12, fraction: Double(value ?? 0) / 100,
                      lit: colour.withAlphaComponent(dim),
                      unlit: VFD.cyan.withAlphaComponent(0.10), gap: 2.2, vertical: true)

            // 7-seg for a short reading, condensed type for anything with a
            // separator — a five-cell numeral will not fit the column, and a
            // comma is not a segment shape.
            let text = column.1?.display ?? value.map(String.init) ?? "--"
            if text.count <= 3, !text.contains(",") {
                let width = SevenSegment.width(text, metrics: tinySeg)
                SevenSegment.draw(text, at: NSPoint(x: cx + 12 - width / 2, y: top + barHeight + 8),
                                  metrics: tinySeg, lit: colour.withAlphaComponent(dim),
                                  unlit: SevenSegment.ghost(VFD.cyan, metrics: tinySeg))
            } else {
                let string = NSAttributedString(string: text, attributes: [
                    .font: ClusterView.condensed(13),
                    .foregroundColor: colour.withAlphaComponent(dim),
                ])
                string.draw(at: NSPoint(x: cx + 12 - string.size().width / 2,
                                        y: top + barHeight + 12))
            }

            let caption = index == 2 ? "steps %g" : column.0
            let width = Gauge.label(caption, at: NSPoint(x: 0, y: -200), font: capsTiny,
                                    color: .clear)
            Gauge.label(caption, at: NSPoint(x: cx + 12 - width / 2, y: top + barHeight + 32),
                        font: capsTiny, color: VFD.label.withAlphaComponent(dim))
        }
    }

    /// The trip-computer block: readings with no 0-100 scale, plus the lamps.
    /// These four never traffic-light — low resting HR is good and high HRV is
    /// good, so any colour rule would be backwards half the time.
    private func drawReadouts(_ snapshot: Snapshot, in box: NSRect) {
        let health = snapshot.card("garmin")
        let dim = alpha(health)
        title("readings", in: box, dim: dim)

        // The cells are always drawn, exactly as the gauges above always are: a
        // dead sensor reads as a dark instrument, never as an empty box with a
        // note floating in it. The message goes below the readings, not instead.
        do {
            let cells = ["ready", "rest hr", "hrv", "stress"]
            let cellWidth = (box.width - 28) / 2

            for (index, name) in cells.enumerated() {
                let cx = box.minX + 14 + CGFloat(index % 2) * cellWidth
                let cy = box.minY + 16 + CGFloat(index / 2) * 42
                let stat = snapshot.stat("garmin", name)

                Gauge.label(name, at: NSPoint(x: cx, y: cy), font: capsTiny,
                            color: VFD.label.withAlphaComponent(0.6 * dim))

                // Split "48 bpm" so the unit sits in label ink, digits in phosphor.
                let parts = (stat?.value ?? "--").split(separator: " ", maxSplits: 1)
                let digits = parts.first.map(String.init) ?? "--"
                SevenSegment.draw(digits, at: NSPoint(x: cx, y: cy + 12), metrics: readSeg,
                                  lit: VFD.cyan.withAlphaComponent(dim),
                                  unlit: SevenSegment.ghost(VFD.cyan, metrics: readSeg))
                if parts.count > 1 {
                    let width = SevenSegment.width(digits, metrics: readSeg)
                    Gauge.label(String(parts[1]), at: NSPoint(x: cx + width + 4, y: cy + 26),
                                font: capsTiny,
                                color: VFD.label.withAlphaComponent(0.6 * dim))
                }
            }
        }

        if health?.state == "reauth" {
            Gauge.label(health?.note ?? "sign in",
                        at: NSPoint(x: box.minX + 14, y: box.maxY - 46),
                        font: capsTiny, color: VFD.magenta)
        }

        drawLamps(snapshot, in: box)
    }

    /// Warning lamps. Unlit lamps stay faintly visible — a dark bulb is still a
    /// bulb, and you learn where to look before it ever lights. A lamp lights
    /// for a fault, never for an absence.
    private func drawLamps(_ snapshot: Snapshot, in box: NSRect) {
        VFD.hairline.withAlphaComponent(0.55).setFill()
        NSRect(x: box.minX + 12, y: box.maxY - 30, width: box.width - 24, height: 1).fill()

        func colour(_ id: String) -> NSColor? {
            switch snapshot.card(id)?.state {
            case "stale", "blocked": return VFD.amber
            case "reauth": return VFD.magenta
            default: return nil
            }
        }
        // The fuel light: derived from the quota meters, not from any one source.
        let lowest = ["claude", "codex"]
            .compactMap { snapshot.card($0)?.meters.map(\.remaining).min() }
            .min()
        let low: NSColor? = lowest.map { $0 <= 8 ? VFD.red : ($0 <= 20 ? VFD.amber : nil) } ?? nil

        let lamps: [(String, NSColor?)] = [
            ("cc", colour("claude")), ("cdx", colour("codex")),
            ("grm", colour("garmin")), ("low", low),
        ]

        let width: CGFloat = 34
        let gap = (box.width - 24 - width * 4) / 3
        for (index, lamp) in lamps.enumerated() {
            let rect = NSRect(x: box.minX + 12 + CGFloat(index) * (width + gap),
                              y: box.maxY - 24, width: width, height: 15)
            let tint = lamp.1 ?? VFD.cyan
            let isLit = lamp.1 != nil
            if isLit {
                tint.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            }
            Gauge.box(rect, color: tint.withAlphaComponent(isLit ? 0.9 : 0.13), radius: 2)
            let textWidth = Gauge.label(lamp.0, at: NSPoint(x: 0, y: -200), font: capsTiny,
                                        color: .clear)
            Gauge.label(lamp.0, at: NSPoint(x: rect.midX - textWidth / 2, y: rect.minY + 2),
                        font: capsTiny, color: tint.withAlphaComponent(isLit ? 1 : 0.17))
        }
    }
}

// MARK: - Controller

final class PanelController {
    private let window: NSWindow
    private var panel: ThemeView
    private let collector: String
    private let configPath: String
    private var config: PanelConfig
    private var timer: Timer?
    private var isRefreshing = false

    init(collector: String, configPath: String) {
        self.collector = collector
        self.configPath = configPath
        let config = PanelConfig.load(configPath)
        self.config = config
        self.panel = ThemeView.make(config.theme)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: panel.panelWidth, height: 120),
                          styleMask: .borderless,
                          backing: .buffered,
                          defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        window.contentView = Self.chrome(for: panel)
        window.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.reposition() }
    }

    func start() {
        refresh()
        // 30s keeps the countdowns honest; collect.py's own 180s TTL means the
        // APIs are only hit every third tick or so.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        // Skip the tick if the previous collector run hasn't come back, so a
        // wedged subprocess can't stack up one child every 30 seconds.
        guard !isRefreshing else { return }
        isRefreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let snapshot = Self.run(self.collector)
            DispatchQueue.main.async {
                self.isRefreshing = false
                // Re-read on every tick so edits to panel.json apply without a restart.
                self.config = PanelConfig.load(self.configPath)
                self.applyTheme()
                self.panel.snapshot = snapshot
                self.resize()
            }
        }
    }

    /// The backdrop a theme sits on: blurred material for the HUD, a flat
    /// near-black plate for the cluster. Also carries the corner and hairline.
    private static func chrome(for panel: ThemeView) -> NSView {
        let container: NSView
        if panel.usesBlur {
            let effect = NSVisualEffectView()
            // Pinned dark: the text palette is near-white, so letting the HUD
            // material flip to light in Light Mode would make it unreadable.
            effect.appearance = NSAppearance(named: .vibrantDark)
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            container = effect
        } else {
            container = NSView()
        }
        container.wantsLayer = true
        if !panel.usesBlur {
            container.layer?.backgroundColor = panel.backdropColor.cgColor
        }
        container.layer?.cornerRadius = panel.cornerRadius
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = panel.borderColor.cgColor
        container.autoresizingMask = [.width, .height]
        container.addSubview(panel)
        panel.autoresizingMask = [.width, .height]
        panel.frame = container.bounds
        return container
    }

    /// Swap the whole view when panel.json names a different theme.
    private func applyTheme() {
        let wanted = (config.theme ?? "hud").lowercased()
        guard type(of: panel).themeName != wanted else { return }
        let replacement = ThemeView.make(wanted)
        replacement.snapshot = panel.snapshot
        panel = replacement
        window.contentView = Self.chrome(for: replacement)
    }

    static func run(_ collector: String) -> Snapshot? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = [collector]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            return nil
        }
    }

    private func resize() {
        var frame = window.frame
        frame.size = NSSize(width: panel.panelWidth, height: panel.fittingHeight)
        window.setFrame(frame, display: true)
        reposition()
    }

    private func reposition() {
        guard let screen = config.targetScreen() else { return }
        window.setFrameOrigin(config.origin(in: screen.visibleFrame, size: window.frame.size))
    }
}

// MARK: - Entry point

let home = FileManager.default.homeDirectoryForCurrentUser.path
let collectorPath = "\(home)/.config/agent-widgets/collect.py"
let configPath = "\(home)/.config/agent-widgets/panel.json"

// `--snapshot <path>` renders the panel offscreen to a PNG and exits. Handy for
// checking layout without staring at the wallpaper.
if let flag = CommandLine.arguments.firstIndex(of: "--snapshot") {
    let out = CommandLine.arguments.count > flag + 1
        ? CommandLine.arguments[flag + 1] : "\(home)/Desktop/agent-widgets.png"
    // `--snapshot <path> [theme]` renders a specific theme; otherwise panel.json's.
    let themeArg = CommandLine.arguments.count > flag + 2
        ? CommandLine.arguments[flag + 2] : PanelConfig.load(configPath).theme
    let view = ThemeView.make(themeArg)
    view.snapshot = PanelController.run(collectorPath)
    view.frame = NSRect(x: 0, y: 0, width: view.panelWidth, height: view.fittingHeight)

    // Stand in for the window backdrop so the snapshot reads like the real panel.
    let backdrop = NSView(frame: view.bounds)
    backdrop.wantsLayer = true
    backdrop.layer?.backgroundColor = view.usesBlur
        ? NSColor(white: 0.11, alpha: 1).cgColor : view.backdropColor.cgColor
    backdrop.layer?.cornerRadius = view.cornerRadius
    backdrop.addSubview(view)

    guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else { exit(1) }
    backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try? png.write(to: URL(fileURLWithPath: out))
    print(out)
    // Revision marker. A render is only meaningful against the source that
    // produced it — without this, a review of one build lands after the next,
    // and findings cite line numbers that have already moved.
    if let source = try? Data(contentsOf: URL(fileURLWithPath: "\(home)/.config/agent-widgets/AgentWidgets.swift")) {
        var hash: UInt64 = 5381
        for byte in source { hash = (hash &* 33) &+ UInt64(byte) }
        print("rev \(String(hash, radix: 16).suffix(8))  \(source.count) bytes")
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let controller = PanelController(collector: collectorPath, configPath: configPath)
controller.start()

app.run()
