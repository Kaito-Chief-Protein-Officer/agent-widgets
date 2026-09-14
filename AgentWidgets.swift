// Desktop panel showing Claude Code / Codex remaining quota.
//
// Renders a borderless, click-through window pinned at the desktop-icon level,
// so it sits on the wallpaper and never steals focus or appears in the Dock.
// All data comes from ~/.config/agent-widgets/collect.py, which is the only
// thing that talks to the network.

import AppKit
import Carbon.HIToolbox

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
    /// Local card only. Bytes on disk, and whether the model is resident in
    /// unified memory right now.
    let size: Int?
    let resident: Bool?
}

struct Stat: Decodable {
    let label: String
    let value: String
}

/// One column of the merge histogram: a local calendar day and its count.
/// Days with no merges arrive as zeros — a gap in the chart is the reading,
/// not missing data.
struct DayCount: Decodable {
    let label: String
    let count: Int
}

struct Card: Decodable {
    let id: String
    let label: String
    /// Which service a quota card reads — "claude" or "codex". One service can
    /// have several cards (one per signed-in Claude account), so the panel
    /// finds them by provider rather than by id.
    let provider: String?
    let sub: String?
    let kind: String?
    let meters: [Meter]
    let rows: [ModelRow]
    let stats: [Stat]
    let note: String?
    let state: String
    /// Merge card only. Rolling 24h count, window total, and per-day columns.
    let merged24h: Int?
    let mergedWindow: Int?
    let days: [DayCount]
    let lastMergedAt: Int?
    let activeTotal: Int?

    var isModels: Bool { kind == "models" }
    var isLocal: Bool { kind == "local" }
    var isHealth: Bool { kind == "health" }
    var isPRs: Bool { kind == "prs" }
    var isAgents: Bool { kind == "agents" }
    var isSystem: Bool { kind == "system" }

    enum CodingKeys: String, CodingKey {
        case id, label, provider, sub, kind, meters, rows, stats, note, state, days
        case merged24h = "merged_24h"
        case mergedWindow = "merged_window"
        case lastMergedAt = "last_merged_at"
        case activeTotal = "active_total"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        sub = try container.decodeIfPresent(String.self, forKey: .sub)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        meters = try container.decodeIfPresent([Meter].self, forKey: .meters) ?? []
        rows = try container.decodeIfPresent([ModelRow].self, forKey: .rows) ?? []
        stats = try container.decodeIfPresent([Stat].self, forKey: .stats) ?? []
        note = try container.decodeIfPresent(String.self, forKey: .note)
        state = try container.decode(String.self, forKey: .state)
        merged24h = try container.decodeIfPresent(Int.self, forKey: .merged24h)
        mergedWindow = try container.decodeIfPresent(Int.self, forKey: .mergedWindow)
        days = try container.decodeIfPresent([DayCount].self, forKey: .days) ?? []
        lastMergedAt = try container.decodeIfPresent(Int.self, forKey: .lastMergedAt)
        activeTotal = try container.decodeIfPresent(Int.self, forKey: .activeTotal)
    }
}

/// Optional ~/.config/agent-widgets/panel.json. Everything has a default, so a
/// missing or malformed file is not an error.
struct PanelConfig: Codable {
    var screen: Int?
    var corner: String?
    var margin: CGFloat?
    var theme: String?
    /// Bottom-left origin from a manual drag, in the coordinate space of
    /// `targetScreen()?.visibleFrame`. Once present, this wins over
    /// corner/margin placement — a drag is a stronger signal of intent than
    /// the startup default. Absent on a fresh install, so first launch still
    /// falls back to the corner/margin/screen-index placement below.
    var x: CGFloat?
    var y: CGFloat?

    static func load(_ path: String) -> PanelConfig {
        guard let data = FileManager.default.contents(atPath: path),
              let config = try? JSONDecoder().decode(PanelConfig.self, from: data)
        else { return PanelConfig() }
        return config
    }

    /// Writes back only the origin, preserving whatever else is in the file
    /// (theme, corner, margin, screen) so a hand-edited panel.json survives a
    /// drag. Read-modify-write against the file rather than `self`, because
    /// `self` may be a stale in-memory copy from the last periodic reload.
    func saved(withOrigin origin: NSPoint, at path: String) -> PanelConfig {
        var config = PanelConfig.load(path)
        config.x = origin.x
        config.y = origin.y
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
        if let x, let y { return NSPoint(x: x, y: y) }
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

    /// Every card for one service, in collector order. A cache written before
    /// cards carried `provider` still has a card whose id *is* the service.
    func cards(provider: String) -> [Card] {
        let matches = cards.filter { $0.provider == provider }
        return matches.isEmpty ? cards.filter { $0.id == provider } : matches
    }

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
    static let chartHeight: CGFloat = 28
    static let chartGap: CGFloat = 3
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

/// Weights on disk, quoted the way `ollama list` quotes them: decimal
/// gigabytes, truncated — so the panel and the CLI never disagree about the
/// size of the same file. Memory is quoted in binary units instead (see
/// collect.py), because that is the unit a machine's RAM is sold in.
func compactBytes(_ value: Int) -> String {
    if value >= 1_000_000_000 { return "\(value / 1_000_000_000)G" }
    if value >= 1_000_000 { return "\(value / 1_000_000)M" }
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

/// Time since something happened — the mirror of `countdown`. Coarse on
/// purpose: a merge three hours old never needs reading to the minute.
func elapsed(_ since: Int?) -> String? {
    guard let since else { return nil }
    let secs = Int(Date().timeIntervalSince1970) - since
    if secs < 60 { return "just now" }
    let days = secs / 86400
    let hours = (secs % 86400) / 3600
    let mins = (secs % 3600) / 60
    if days > 0 { return "\(days)d \(hours)h ago" }
    if hours > 0 { return "\(hours)h \(mins)m ago" }
    return "\(mins)m ago"
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

        if card.isPRs { return height + prsHeight(card) }
        if card.isAgents { return height + 38 }
        if card.isSystem {
            let row = Style.meterLabel.pointSize + Style.labelGap + Style.trackHeight
            return height + 2 * row + Style.meterGap
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

    private func prsHeight(_ card: Card) -> CGFloat {
        guard card.merged24h != nil || !card.days.isEmpty else { return 14 }
        var height = 2 * (Style.meterLabel.pointSize + 2)
        if !card.days.isEmpty {
            height += Style.headGap + Style.chartHeight + Style.labelGap
                + Style.sub.pointSize
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

            if card.isModels || card.isLocal {
                y = drawModels(card, left: left, right: right, y: y, dim: dim)
                continue
            }

            if card.isPRs {
                y = drawPRs(card, left: left, right: right, y: y, dim: dim)
                continue
            }

            if card.isAgents {
                y = drawAgents(card, left: left, right: right, y: y, dim: dim)
                continue
            }

            if card.isSystem {
                y = drawSystem(card, left: left, right: right, y: y, dim: dim)
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

    /// Merge counts plus a seven-day column chart. Columns are scaled to the
    /// week's own peak, not to a fixed ceiling: a merge count has no ceiling, so
    /// the shape of the week is what the chart is for. The exact figures are the
    /// two rows above it.
    private func drawPRs(_ card: Card, left: CGFloat, right: CGFloat,
                         y startY: CGFloat, dim: CGFloat) -> CGFloat {
        var y = startY
        guard card.merged24h != nil || !card.days.isEmpty else {
            drawText(noteText(card) ?? "no data", font: Style.meterLabel,
                     color: Style.warn, at: NSPoint(x: left, y: y))
            return y + 14
        }

        for (label, value) in [("last 24h", card.merged24h),
                               ("last 7 days", card.mergedWindow)] {
            drawText(label, font: Style.meterLabel,
                     color: Style.secondary.withAlphaComponent(0.62 * dim),
                     at: NSPoint(x: left, y: y))
            let text = NSAttributedString(string: value.map(String.init) ?? "--", attributes: [
                .font: Style.pct,
                .foregroundColor: Style.primary.withAlphaComponent(0.92 * dim),
            ])
            text.draw(at: NSPoint(x: right - text.size().width, y: y))
            y += Style.meterLabel.pointSize + 2
        }

        guard !card.days.isEmpty else { return y }
        y += Style.headGap

        let peak = card.days.map(\.count).max() ?? 0
        let columnWidth = (right - left) / CGFloat(card.days.count)
        let barWidth = max(3, columnWidth - Style.chartGap)
        for (index, day) in card.days.enumerated() {
            let x = left + CGFloat(index) * columnWidth

            // Every day keeps its track, so a zero day reads as a day with no
            // merges rather than as a hole in the chart.
            let track = NSRect(x: x, y: y, width: barWidth, height: Style.chartHeight)
            Style.track.withAlphaComponent(0.09 * dim).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()

            let ratio = peak > 0 ? CGFloat(day.count) / CGFloat(peak) : 0
            let height = day.count > 0 ? max(2, ratio * Style.chartHeight) : 0
            if height > 0 {
                let fill = NSRect(x: x, y: y + Style.chartHeight - height,
                                  width: barWidth, height: height)
                Style.seriesColor(2).withAlphaComponent(0.9 * dim).setFill()
                NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
            }

            // Today is the last column and the only partial one, so its label
            // is the one that stays bright.
            let isToday = index == card.days.count - 1
            let label = NSAttributedString(string: day.label.uppercased(), attributes: [
                .font: Style.sub,
                .foregroundColor: Style.tertiary
                    .withAlphaComponent((isToday ? 0.85 : 0.42) * dim),
                .kern: 0.4,
            ])
            label.draw(at: NSPoint(x: x + (barWidth - label.size().width) / 2,
                                   y: y + Style.chartHeight + Style.labelGap))
        }
        return y + Style.chartHeight + Style.labelGap + Style.sub.pointSize
    }

    /// Load, not budget: the bar fills as the machine gets busier, and the
    /// colour ramp is read backwards from every other card here so that full
    /// is the bad end.
    private func drawSystem(_ card: Card, left: CGFloat, right: CGFloat,
                            y: CGFloat, dim: CGFloat) -> CGFloat {
        func reading(_ name: String) -> Int? {
            card.stats.first { $0.label == name }.flatMap { Int($0.value) }
        }
        func text(_ name: String) -> String? {
            card.stats.first { $0.label == name }?.value
        }
        let footprint = text("ram_used").flatMap { used in
            text("ram_total").map { "\(used) of \($0)" }
        }

        var y = y
        for (index, row) in [("cpu", reading("cpu"), nil),
                             ("ram", reading("ram"), footprint)].enumerated() {
            let (name, used, detail) = row
            if index > 0 { y += Style.meterGap }

            drawText(name, font: Style.meterLabel,
                     color: Style.secondary.withAlphaComponent(0.62 * dim),
                     at: NSPoint(x: left, y: y))

            let value = NSMutableAttributedString(
                string: used.map { "\($0)%" } ?? "—",
                attributes: [.font: Style.pct,
                             .foregroundColor: Style.primary.withAlphaComponent(0.92 * dim)])
            if let detail {
                value.append(NSAttributedString(
                    string: " · \(detail)",
                    attributes: [.font: Style.meterLabel,
                                 .foregroundColor: Style.secondary.withAlphaComponent(0.62 * dim)]))
            }
            value.draw(at: NSPoint(x: right - value.size().width, y: y))
            y += Style.meterLabel.pointSize + Style.labelGap

            let track = NSRect(x: left, y: y, width: right - left, height: Style.trackHeight)
            let path = NSBezierPath(roundedRect: track, xRadius: Style.trackHeight / 2,
                                    yRadius: Style.trackHeight / 2)
            Style.track.setFill()
            path.fill()
            if let used, used > 0 {
                let width = max(Style.trackHeight, track.width * CGFloat(used) / 100)
                let fill = NSRect(x: left, y: y, width: width, height: Style.trackHeight)
                let filled = NSBezierPath(roundedRect: fill, xRadius: Style.trackHeight / 2,
                                          yRadius: Style.trackHeight / 2)
                Style.meterColor(100 - used).withAlphaComponent(dim).setFill()
                filled.fill()
            }
            y += Style.trackHeight
        }
        return y
    }

    private func drawAgents(_ card: Card, left: CGFloat, right: CGFloat,
                            y: CGFloat, dim: CGFloat) -> CGFloat {
        let value = card.activeTotal.map(String.init) ?? "--"
        drawText(value, font: NSFont.monospacedDigitSystemFont(ofSize: 24, weight: .semibold),
                 color: Style.primary.withAlphaComponent(dim), at: NSPoint(x: left, y: y))
        let split = card.stats.map { "\($0.label) \($0.value)" }.joined(separator: "  ·  ")
        let detail = split.isEmpty ? (noteText(card) ?? "unavailable") : split
        let text = NSAttributedString(string: detail, attributes: [
            .font: Style.meterLabel,
            .foregroundColor: Style.secondary.withAlphaComponent(0.62 * dim),
        ])
        text.draw(at: NSPoint(x: right - text.size().width, y: y + 12))
        return y + 38
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
        // sight and persisted, and this machine's slot 3 holds a local model —
        // so on the mix, the four hues that appear together are the
        // widely-separated ones and teal never has to sit beside cyan. It does
        // chart, on the local card, where cyan is not in play.
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
    override var fittingHeight: CGFloat { 768 }

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
    // Half-width hero: two of these share the speedo face when two Claude
    // accounts are signed in. Same proportions as `hero`, sized so "100" and
    // its % clear half the box.
    private let twinSeg = SevenSegment.Metrics(width: 26, height: 54, thickness: 7.0,
                                               gap: 1.8, slant: 0.09, spacing: 6.5)
    private let rowSeg = SevenSegment.Metrics(width: 18, height: 30, thickness: 4.1,
                                              gap: 1.2, slant: 0.09, spacing: 4.5)
    private let midSeg = SevenSegment.Metrics(width: 18, height: 30, thickness: 3.9,
                                              gap: 1.1, slant: 0.09, spacing: 4.5)
    private let tinySeg = SevenSegment.Metrics(width: 12, height: 21, thickness: 2.8,
                                               gap: 0.9, slant: 0.09, spacing: 3)
    // Sized so a three-digit reading plus its unit clears the readings cell.
    private let readSeg = SevenSegment.Metrics(width: 16, height: 27, thickness: 3.4,
                                               gap: 1.0, slant: 0.09, spacing: 3.8)
    private let countSeg = SevenSegment.Metrics(width: 29, height: 48, thickness: 6.2,
                                                gap: 1.7, slant: 0.09, spacing: 7)

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
        // Third row follows the same column grid as the first: the counter sits
        // under the hero, the histogram under the tacho.
        let agentsBox = NSRect(x: 12, y: 340, width: 112, height: 116)
        let mergeBox = NSRect(x: 136, y: 340, width: 156, height: 116)
        let historyBox = NSRect(x: 304, y: 340, width: 384, height: 116)
        // Fourth row, full width: local models are a list of named things with
        // a size and a count each, not a single reading, so they get the whole
        // width rather than a cell in the column grid.
        let localBox = NSRect(x: 12, y: 470, width: 676, height: 120)
        // Fifth row: the machine the rest of this is running on. Two readings,
        // so they sit side by side rather than taking a column cell each.
        let systemBox = NSRect(x: 12, y: 604, width: 676, height: 150)

        for box in [heroBox, rampBox, quotaBox, vitalsBox, readBox, agentsBox, mergeBox,
                    historyBox, localBox, systemBox] {
            Gauge.box(box, color: VFD.hairline.withAlphaComponent(0.85), radius: 4)
        }

        drawSpeedo(snapshot, in: heroBox)
        drawModelRamp(snapshot, in: rampBox)
        drawQuota(snapshot, in: quotaBox)
        drawGauges(snapshot, in: vitalsBox)
        drawReadouts(snapshot, in: readBox)
        drawActiveAgents(snapshot, in: agentsBox)
        drawMergeCounter(snapshot, in: mergeBox)
        drawMergeHistory(snapshot, in: historyBox)
        drawLocalModels(snapshot, in: localBox)
        drawSystem(snapshot, in: systemBox)
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

    /// Hero numeral: the Claude 5h window, the number checked most often. With
    /// two accounts signed in the face splits into a twin speedo, one dial per
    /// subscription — "which one is nearly empty" is then the question.
    private func drawSpeedo(_ snapshot: Snapshot, in box: NSRect) {
        let accounts = snapshot.cards(provider: "claude")
        if accounts.count >= 2 {
            drawTwinSpeedo(Array(accounts.prefix(2)), in: box)
            return
        }
        let card = accounts.first
        let dim = alpha(card)
        let meter = card?.meters.first { $0.name == "5h" }
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

    /// Two dials on one face. Each keeps the single hero's anatomy — numeral,
    /// bar, reset — at half width, with the account name and plan tier where
    /// the single dial has "5h remaining". A dial in a fault state dims and
    /// wears its state word alone; the other dial is unaffected.
    private func drawTwinSpeedo(_ accounts: [Card], in box: NSRect) {
        title("claude code", in: box, dim: 1, tag: "5h window")

        let left = box.minX + 16
        let right = box.maxX - 16
        let gutter: CGFloat = 16
        let width = (right - left - gutter) / 2

        VFD.hairline.withAlphaComponent(0.55).setFill()
        NSRect(x: left + width + gutter / 2, y: box.minY + 18, width: 1,
               height: box.height - 32).fill()

        for (index, card) in accounts.enumerated() {
            let x = left + CGFloat(index) * (width + gutter)
            let dim = alpha(card)
            let meter = card.meters.first { $0.name == "5h" }
            let colour = meter.map { VFD.level($0.remaining) } ?? VFD.cyan

            Gauge.label(card.label, at: NSPoint(x: x, y: box.minY + 16), font: capsTiny,
                        color: VFD.label.withAlphaComponent(0.85 * dim))
            // The state word always wins the right-hand slot; the plan tier
            // only shows when there is nothing more urgent to say.
            if let state = stateTag(card) {
                Gauge.label(state.0, at: NSPoint(x: x + width, y: box.minY + 16),
                            font: capsTiny, color: state.1, alignRight: true)
            } else if let plan = card.sub {
                Gauge.label(plan, at: NSPoint(x: x + width, y: box.minY + 16),
                            font: capsTiny, color: VFD.label.withAlphaComponent(0.55),
                            alignRight: true)
            }

            let text = meter.map { String(format: "%3d", $0.remaining) } ?? "---"
            SevenSegment.draw(text, at: NSPoint(x: x, y: box.minY + 34), metrics: twinSeg,
                              lit: colour.withAlphaComponent(dim),
                              unlit: SevenSegment.ghost(VFD.cyan, metrics: twinSeg))
            let numeralWidth = SevenSegment.width(text, metrics: twinSeg)
            NSAttributedString(string: "%", attributes: [
                .font: NSFont.systemFont(ofSize: 20, weight: .light),
                .foregroundColor: colour.withAlphaComponent(0.9 * dim),
            ]).draw(at: NSPoint(x: x + numeralWidth + 4, y: box.minY + 60))

            Gauge.bar(in: NSRect(x: x, y: box.minY + 102, width: width, height: 10),
                      segments: 12, fraction: Double(meter?.remaining ?? 0) / 100,
                      lit: colour.withAlphaComponent(dim),
                      unlit: VFD.cyan.withAlphaComponent(0.10), gap: 2.4)

            Gauge.label("reset", at: NSPoint(x: x, y: box.minY + 124), font: capsTiny,
                        color: VFD.label.withAlphaComponent(0.55 * dim))
            Gauge.label(countdown(meter?.resetsAt) ?? "—",
                        at: NSPoint(x: x + width, y: box.minY + 124), font: capsSmall,
                        color: VFD.label.withAlphaComponent(dim), alignRight: true)
        }
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
    /// Local models: what this machine can run, and what it has generated.
    ///
    /// Deliberately not a share of the model mix. Local tokens cost no
    /// subscription quota, and against a frontier model their share rounds to
    /// zero — so the reading here is the absolute count, and every model on
    /// disk gets a row whether it has run or not. A row with an empty track is
    /// the answer to "what else could I run", which is half the question.
    private func drawLocalModels(_ snapshot: Snapshot, in box: NSRect) {
        let card = snapshot.card("local")
        let dim = alpha(card)
        let rows = card?.rows ?? []
        // The rail says where the reading came from, and says "offline" when
        // the daemon is not answering — otherwise an empty resident column
        // reads as "nothing loaded" when it means "nobody asked".
        let state = stateTag(card)
        title("local models", in: box, dim: dim, tag: state?.0 ?? card?.sub ?? "ollama",
              tagColor: state?.1 ?? VFD.label)

        let x = box.minX + 14
        let right = box.maxX - 14

        guard !rows.isEmpty else {
            Gauge.label("no local models", at: NSPoint(x: x, y: box.minY + 24),
                        font: capsSmall, color: VFD.label.withAlphaComponent(0.4))
            return
        }

        let busiest = Double(rows.map(\.value).max() ?? 0)
        for (index, row) in rows.prefix(4).enumerated() {
            let rowY = box.minY + 18 + CGFloat(index) * 22
            let colour = VFD.slot(row.slot)

            // Resident is carried by the marker's shape, not only its colour: a
            // filled lamp is in memory now, a ring is on disk. The bar below
            // says nothing about residency, so this is the only place it lives.
            let lamp = NSRect(x: x, y: rowY + 1, width: 7, height: 7)
            let path = NSBezierPath(ovalIn: lamp)
            if row.resident == true {
                colour.withAlphaComponent(dim).setFill()
                path.fill()
            } else {
                colour.withAlphaComponent(0.45 * dim).setStroke()
                path.lineWidth = 1
                path.stroke()
            }

            Gauge.label(row.label, at: NSPoint(x: x + 14, y: rowY),
                        font: capsTiny, color: colour.withAlphaComponent(dim))

            if let size = row.size, size > 0 {
                Gauge.label(compactBytes(size), at: NSPoint(x: x + 232, y: rowY),
                            font: capsTiny,
                            color: VFD.label.withAlphaComponent(0.55 * dim), alignRight: true)
            }

            // Scaled to the busiest model by token count, not by the rounded
            // share — a model with 66 tokens beside one with 115k still lights
            // a segment. An untouched model reads as an empty track, not a
            // missing one, which is the point of listing it at all.
            let track = NSRect(x: x + 246, y: rowY + 1, width: right - 96 - (x + 246), height: 7)
            Gauge.bar(in: track, segments: 22,
                      fraction: busiest > 0 ? Double(row.value) / busiest : 0,
                      lit: colour.withAlphaComponent(0.9 * dim),
                      unlit: VFD.cyan.withAlphaComponent(0.10), gap: 2.4)

            Gauge.label(compactTokens(row.value), at: NSPoint(x: right, y: rowY),
                        font: capsTiny,
                        color: VFD.label.withAlphaComponent((row.value > 0 ? 0.85 : 0.35) * dim),
                        alignRight: true)
        }

        VFD.hairline.withAlphaComponent(0.6 * dim).setFill()
        NSRect(x: x, y: box.minY + 96, width: right - x, height: 1).fill()

        let stats = card?.stats ?? []
        if stats.count >= 2 {
            Gauge.label("resident", at: NSPoint(x: x, y: box.minY + 104), font: capsTiny,
                        color: VFD.label.withAlphaComponent(0.55 * dim))
            Gauge.label("\(stats[0].value) / \(stats[1].value)",
                        at: NSPoint(x: right, y: box.minY + 104), font: capsTiny,
                        color: VFD.label.withAlphaComponent(0.85 * dim), alignRight: true)
        }
    }

    private func drawQuota(_ snapshot: Snapshot, in box: NSRect) {
        title("week windows", in: box, dim: 1)

        let claude = snapshot.cards(provider: "claude")
        let codex = snapshot.cards(provider: "codex")
        var rows: [(String, Card?, Meter?, String?)] = claude.map { card in
            (claude.count > 1 ? "claude · \(card.label)" : "claude · week",
             card, card.meters.first { $0.name == "week" }, nil)
        }
        // With one Codex login the plan name has room to ride along, the way it
        // always has; with two, the account label needs that slot instead.
        rows += codex.map { card in
            (codex.count > 1 ? "codex · \(card.label)" : "codex · week",
             card, card.meters.first { $0.name == "week" }, codex.count > 1 ? nil : card.sub)
        }
        if rows.count > 2 {
            drawQuotaRows(rows, in: box)
            return
        }

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

    /// Odometer rows for three or more windows in the same box. Each row is a
    /// label line and a reading line — numeral left, bar filling the rest —
    /// which is what fits three long-horizon totals in the height two had.
    /// The bars share one left edge so the shapes compare down the column.
    private func drawQuotaRows(_ rows: [(String, Card?, Meter?, String?)], in box: NSRect) {
        let x = box.minX + 14
        let right = box.maxX - 14
        let pitch = (box.height - 20) / CGFloat(rows.count)
        // Widest numeral the row can show, so the bars line up whatever the reading.
        let barLeft = x + SevenSegment.width("100", metrics: tinySeg) + 20

        for (index, row) in rows.enumerated() {
            let (label, card, meter, plan) = row
            let dim = alpha(card)
            let top = box.minY + 14 + CGFloat(index) * pitch
            let colour = meter.map { VFD.level($0.remaining) } ?? VFD.cyan

            let name = plan.map { "\(label.replacingOccurrences(of: " · week", with: "")) · \($0)" }
                ?? label
            Gauge.label(name, at: NSPoint(x: x, y: top), font: capsTiny,
                        color: VFD.label.withAlphaComponent(dim))
            if let state = stateTag(card) {
                Gauge.label(state.0, at: NSPoint(x: right, y: top), font: capsTiny,
                            color: state.1, alignRight: true)
            } else if let reset = countdown(meter?.resetsAt) {
                Gauge.label(reset, at: NSPoint(x: right, y: top), font: capsTiny,
                            color: VFD.label.withAlphaComponent(0.85 * dim), alignRight: true)
            }

            let text = meter.map { String($0.remaining) } ?? "--"
            SevenSegment.draw(text, at: NSPoint(x: x, y: top + 12), metrics: tinySeg,
                              lit: colour.withAlphaComponent(dim),
                              unlit: SevenSegment.ghost(VFD.cyan, metrics: tinySeg))
            Gauge.label("%", at: NSPoint(x: x + SevenSegment.width(text, metrics: tinySeg) + 3,
                                          y: top + 23),
                        font: capsTiny, color: colour.withAlphaComponent(0.85 * dim))

            Gauge.bar(in: NSRect(x: barLeft, y: top + 18, width: right - barLeft, height: 9),
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

    /// Trip-meter counter: merges in the last rolling 24 hours, with the week
    /// total and the time since the last merge under it. A count has no ceiling,
    /// so no bar is drawn here — the histogram beside it carries the shape.
    private func drawMergeCounter(_ snapshot: Snapshot, in box: NSRect) {
        let card = snapshot.card("prs")
        let dim = alpha(card)
        let state = stateTag(card)
        title("prs merged", in: box, dim: dim, tag: state?.0 ?? "24h", tagColor: state?.1)

        let x = box.minX + 16
        let right = box.maxX - 12

        // Leading blank, as on the hero: a one-digit count keeps the tens cell
        // dark rather than padding it with a zero.
        let text = card?.merged24h.map { String(format: "%2d", $0) } ?? "--"
        SevenSegment.draw(text, at: NSPoint(x: x, y: box.minY + 16), metrics: countSeg,
                          lit: VFD.cyan.withAlphaComponent(dim),
                          unlit: SevenSegment.ghost(VFD.cyan, metrics: countSeg))
        Gauge.label("24h", at: NSPoint(x: x, y: box.minY + 68), font: capsTiny,
                    color: VFD.label.withAlphaComponent(0.7 * dim))

        // Week total as a trip-computer cell, right-aligned against the counter.
        Gauge.label("7d", at: NSPoint(x: right, y: box.minY + 18), font: capsTiny,
                    color: VFD.label.withAlphaComponent(0.6 * dim), alignRight: true)
        let weekText = card?.mergedWindow.map(String.init) ?? "--"
        let weekWidth = SevenSegment.width(weekText, metrics: rowSeg)
        SevenSegment.draw(weekText, at: NSPoint(x: right - weekWidth, y: box.minY + 30),
                          metrics: rowSeg, lit: VFD.cyan.withAlphaComponent(dim),
                          unlit: SevenSegment.ghost(VFD.cyan, metrics: rowSeg))

        VFD.hairline.withAlphaComponent(0.55 * dim).setFill()
        NSRect(x: x, y: box.minY + 86, width: right - x, height: 1).fill()

        Gauge.label("last", at: NSPoint(x: x, y: box.minY + 93), font: capsTiny,
                    color: VFD.label.withAlphaComponent(0.55 * dim))
        Gauge.label(elapsed(card?.lastMergedAt) ?? "—",
                    at: NSPoint(x: right, y: box.minY + 93), font: capsSmall,
                    color: VFD.label.withAlphaComponent(dim), alignRight: true)
    }

    private func drawActiveAgents(_ snapshot: Snapshot, in box: NSRect) {
        let card = snapshot.card("agents")
        let dim = alpha(card)
        let state = stateTag(card)
        title("agents", in: box, dim: dim, tag: state?.0 ?? "live", tagColor: state?.1)

        let total = card?.activeTotal.map(String.init) ?? "--"
        let width = SevenSegment.width(total, metrics: countSeg)
        SevenSegment.draw(total, at: NSPoint(x: box.midX - width / 2, y: box.minY + 18),
                          metrics: countSeg, lit: VFD.cyan.withAlphaComponent(dim),
                          unlit: SevenSegment.ghost(VFD.cyan, metrics: countSeg))
        Gauge.label("active", at: NSPoint(x: box.minX + 12, y: box.minY + 70),
                    font: capsTiny, color: VFD.label.withAlphaComponent(0.7 * dim))

        VFD.hairline.withAlphaComponent(0.55 * dim).setFill()
        NSRect(x: box.minX + 12, y: box.minY + 86, width: box.width - 24, height: 1).fill()
        let claude = card?.stats.first { $0.label == "claude" }?.value ?? "—"
        let codex = card?.stats.first { $0.label == "codex" }?.value ?? "—"
        let opencode = card?.stats.first { $0.label == "opencode" }?.value ?? "—"
        let color = VFD.label.withAlphaComponent(dim)
        Gauge.label("cc \(claude)", at: NSPoint(x: box.minX + 12, y: box.minY + 93),
                    font: capsTiny, color: color)
        let ocText = "oc \(opencode)"
        let ocWidth = NSAttributedString(string: ocText.uppercased(),
                                          attributes: [.font: capsTiny, .kern: 0.9]).size().width
        Gauge.label(ocText, at: NSPoint(x: box.midX - ocWidth / 2, y: box.minY + 93),
                    font: capsTiny, color: color)
        Gauge.label("cdx \(codex)", at: NSPoint(x: box.maxX - 12, y: box.minY + 93),
                    font: capsTiny, color: color, alignRight: true)
    }

    /// Merge histogram: one segmented column per local day, oldest at the left.
    /// Columns share one rail scaled to the week's peak, so the tallest column
    /// is always full — the shape of the week is the reading, not the absolute
    /// height. Today's column is marked, because it is the only partial one and
    /// is not yet comparable to the six beside it.
    private func drawMergeHistory(_ snapshot: Snapshot, in box: NSRect) {
        let card = snapshot.card("prs")
        let dim = alpha(card)
        let days = card?.days ?? []
        title("merge history", in: box, dim: dim, tag: "7 day")

        let left = box.minX + 36
        let right = box.maxX - 14
        let top = box.minY + 14
        let barHeight: CGFloat = 48
        let columns = max(1, days.count)
        let columnWidth = (right - left) / CGFloat(columns)
        let barWidth = min(columnWidth - 14, 30)
        let peak = days.map(\.count).max() ?? 0

        // Shared rail, labelled with the peak rather than a round number: the
        // scale is the week's own maximum, and printing it is what stops the
        // columns reading as percentages. A week with no merges has no range to
        // label, so the top of the rail stays blank rather than reading 0 twice.
        if peak > 0 {
            Gauge.label(String(peak), at: NSPoint(x: box.minX + 31, y: top - 4),
                        font: capsTiny,
                        color: VFD.label.withAlphaComponent(0.4 * dim), alignRight: true)
        }
        Gauge.label("0", at: NSPoint(x: box.minX + 31, y: top + barHeight - 8),
                    font: capsTiny, color: VFD.label.withAlphaComponent(0.4 * dim),
                    alignRight: true)

        guard !days.isEmpty else {
            Gauge.bar(in: NSRect(x: left, y: top, width: right - left, height: barHeight),
                      segments: 8, fraction: 0, lit: VFD.cyan,
                      unlit: VFD.cyan.withAlphaComponent(0.10), gap: 2.2, vertical: true)
            Gauge.label(card == nil ? "no data" : "no merges",
                        at: NSPoint(x: box.midX - 22, y: top + barHeight + 22),
                        font: capsSmall, color: VFD.label.withAlphaComponent(0.4))
            return
        }

        for (index, day) in days.enumerated() {
            let centre = left + (CGFloat(index) + 0.5) * columnWidth
            let isToday = index == days.count - 1

            Gauge.bar(in: NSRect(x: centre - barWidth / 2, y: top,
                                 width: barWidth, height: barHeight),
                      segments: 8,
                      fraction: peak > 0 ? Double(day.count) / Double(peak) : 0,
                      lit: VFD.cyan.withAlphaComponent(dim),
                      unlit: VFD.cyan.withAlphaComponent(0.10), gap: 2.2, vertical: true)

            let text = String(day.count)
            let width = SevenSegment.width(text, metrics: tinySeg)
            SevenSegment.draw(text, at: NSPoint(x: centre - width / 2, y: top + barHeight + 8),
                              metrics: tinySeg,
                              lit: VFD.cyan.withAlphaComponent((day.count == 0 ? 0.35 : 1) * dim),
                              unlit: SevenSegment.ghost(VFD.cyan, metrics: tinySeg))

            let labelWidth = Gauge.label(day.label, at: NSPoint(x: 0, y: -200),
                                         font: capsTiny, color: .clear)
            Gauge.label(day.label, at: NSPoint(x: centre - labelWidth / 2, y: top + barHeight + 32),
                        font: capsTiny, color: VFD.label.withAlphaComponent(dim))

            // Cursor under today, the way a cluster marks the live reading.
            if isToday {
                VFD.cyan.withAlphaComponent(0.8 * dim).setFill()
                NSRect(x: centre - labelWidth / 2 - 1, y: top + barHeight + 44,
                       width: labelWidth + 2, height: 1.5).fill()
            }
        }
    }

    /// The machine row: a dial at each end, compact bars between them.
    ///
    /// CPU and ping are the twitchy ones — a needle's angle registers before a
    /// number does — and they bracket the row so it reads as a cluster rather
    /// than a list. RAM and swap change slowly and only need to answer "how
    /// much is gone", which a bar does in a fraction of the space the wedge
    /// was taking.
    private func drawSystem(_ snapshot: Snapshot, in box: NSRect) {
        let card = snapshot.card("system")
        let dim = alpha(card)
        title("system", in: box, dim: dim, tag: card?.sub ?? "cpu · ram · net")

        func reading(_ name: String) -> Int? {
            card?.stats.first { $0.label == name }.flatMap { Int($0.value) }
        }
        func text(_ name: String) -> String? {
            card?.stats.first { $0.label == name }?.value
        }
        func footprint(_ used: String, _ total: String) -> String? {
            guard let used = text(used), let total = text(total) else { return nil }
            return "\(used) of \(total)"
        }

        let radius: CGFloat = 44
        let column: CGFloat = 140
        let centreY = box.minY + 66
        let readoutY = box.minY + 106

        drawDial(reading("cpu"), scaleMax: 100, unit: "% cpu", warn: 0.6, danger: 0.8,
                 centre: NSPoint(x: box.minX + 14 + column / 2, y: centreY),
                 radius: radius, dim: dim, readoutY: readoutY)

        // 200ms full scale: past that the link is unusable and the exact
        // number stops mattering, which is what a pegged needle should say.
        drawDial(reading("ping"), scaleMax: 200, unit: "ms", warn: 0.3, danger: 0.6,
                 centre: NSPoint(x: box.maxX - 14 - column / 2, y: centreY),
                 radius: radius, dim: dim, readoutY: readoutY)

        if let down = text("net_down"), let up = text("net_up") {
            let rates = "↓ \(down)   ↑ \(up)"
            let width = NSAttributedString(string: rates.uppercased(),
                                           attributes: [.font: capsTiny, .kern: 0.9]).size().width
            Gauge.label(rates, at: NSPoint(x: box.maxX - 14 - column / 2 - width / 2,
                                           y: box.minY + 130),
                        font: capsTiny, color: VFD.label.withAlphaComponent(0.8 * dim))
        }

        let left = box.minX + 14 + column + 26
        let right = box.maxX - 14 - column - 26
        drawUsageRow("ram", reading("ram"), footprint("ram_used", "ram_total"),
                     left: left, right: right, top: box.minY + 26, dim: dim)
        drawUsageRow("swap", reading("swap"), footprint("swap_used", "swap_total"),
                     left: left, right: right, top: box.minY + 76, dim: dim)
    }

    /// One "how much is gone" row: numeral, then a bar filling the rest. Load,
    /// not budget, so the ramp is read backwards — a full bar is the bad end.
    private func drawUsageRow(_ name: String, _ value: Int?, _ detail: String?,
                              left: CGFloat, right: CGFloat, top: CGFloat, dim: CGFloat) {
        let colour = value.map { VFD.level(100 - $0) } ?? VFD.cyan
        Gauge.label(name, at: NSPoint(x: left, y: top), font: capsTiny,
                    color: VFD.label.withAlphaComponent(dim))
        if let detail {
            Gauge.label(detail, at: NSPoint(x: right, y: top), font: capsTiny,
                        color: VFD.label.withAlphaComponent(0.85 * dim), alignRight: true)
        }

        let digits = value.map(String.init) ?? "--"
        SevenSegment.draw(digits, at: NSPoint(x: left, y: top + 12), metrics: rowSeg,
                          lit: colour.withAlphaComponent(dim),
                          unlit: SevenSegment.ghost(VFD.cyan, metrics: rowSeg))
        Gauge.label("%", at: NSPoint(x: left + SevenSegment.width(digits, metrics: rowSeg) + 4,
                                      y: top + 30),
                    font: capsTiny, color: colour.withAlphaComponent(0.85 * dim))

        // Widest numeral the row can show, so both bars share a left edge.
        let barLeft = left + SevenSegment.width("100", metrics: rowSeg) + 22
        Gauge.bar(in: NSRect(x: barLeft, y: top + 18, width: right - barLeft, height: 11),
                  segments: 20, fraction: Double(value ?? 0) / 100,
                  lit: colour.withAlphaComponent(dim),
                  unlit: VFD.cyan.withAlphaComponent(0.10), gap: 2.4)
    }

    /// A boost-gauge face: ticks radiating round a 270° sweep, cool at the
    /// bottom of the range and red at the top, a needle, and the reading
    /// repeated digitally below. The bands belong to the face, not the needle,
    /// so the red is there to read against before anything reaches it. Below
    /// rather than inside, because a 270° sweep puts the needle through the
    /// middle of the dial, where it would cross its own readout.
    private func drawDial(_ value: Int?, scaleMax: Int, unit: String,
                          warn: CGFloat, danger: CGFloat,
                          centre: NSPoint, radius: CGFloat, dim: CGFloat, readoutY: CGFloat) {
        // Flipped view: y grows downward, so a conventional angle is plotted
        // with -sin. Sweep runs 225° (lower left) clockwise to -45°.
        func point(_ fraction: CGFloat, _ distance: CGFloat) -> NSPoint {
            let angle = (225 - fraction * 270) * .pi / 180
            return NSPoint(x: centre.x + distance * cos(angle),
                           y: centre.y - distance * sin(angle))
        }
        func bandColour(_ fraction: CGFloat) -> NSColor {
            if fraction >= danger { return VFD.red }
            if fraction >= warn { return VFD.amber }
            return VFD.cyan
        }

        let steps = 50
        for index in 0...steps {
            let fraction = CGFloat(index) / CGFloat(steps)
            let major = index % 5 == 0
            let path = NSBezierPath()
            path.move(to: point(fraction, radius - (major ? 11 : 6)))
            path.line(to: point(fraction, radius))
            path.lineWidth = major ? 2.2 : 1.2
            bandColour(fraction).withAlphaComponent((major ? 0.95 : 0.55) * dim).setStroke()
            path.stroke()
        }

        for step in stride(from: 0, through: scaleMax, by: max(1, scaleMax / 5)) {
            let fraction = CGFloat(step) / CGFloat(scaleMax)
            let at = point(fraction, radius - 18)
            let label = String(step)
            let size = NSAttributedString(string: label,
                                          attributes: [.font: capsTiny, .kern: 0.9]).size()
            Gauge.label(label, at: NSPoint(x: at.x - size.width / 2, y: at.y - 5),
                        font: capsTiny,
                        color: bandColour(fraction).withAlphaComponent(0.85 * dim))
        }

        // Parked at zero when there is no reading rather than hidden, because
        // a dial with no needle reads as a broken gauge. Pegged at full scale
        // rather than swung past it, the way a real needle stops.
        let fraction = min(1, CGFloat(value ?? 0) / CGFloat(scaleMax))
        let needle = NSBezierPath()
        needle.move(to: point(fraction, -8))
        needle.line(to: point(fraction, radius - 8))
        needle.lineWidth = 2.6
        needle.lineCapStyle = .round
        VFD.red.withAlphaComponent((value == nil ? 0.35 : 0.95) * dim).setStroke()
        needle.stroke()

        let hub: CGFloat = 6
        VFD.red.withAlphaComponent(0.9 * dim).setFill()
        NSBezierPath(ovalIn: NSRect(x: centre.x - hub / 2, y: centre.y - hub / 2,
                                    width: hub, height: hub)).fill()

        let digits = value.map(String.init) ?? "--"
        let width = SevenSegment.width(digits, metrics: tinySeg)
        let unitWidth = NSAttributedString(string: unit.uppercased(),
                                           attributes: [.font: capsTiny, .kern: 0.9]).size().width
        let readoutX = centre.x - (width + 5 + unitWidth) / 2
        SevenSegment.draw(digits, at: NSPoint(x: readoutX, y: readoutY), metrics: tinySeg,
                          lit: bandColour(fraction).withAlphaComponent(dim),
                          unlit: SevenSegment.ghost(VFD.cyan, metrics: tinySeg))
        Gauge.label(unit, at: NSPoint(x: readoutX + width + 5, y: readoutY + 11),
                    font: capsTiny, color: VFD.label.withAlphaComponent(0.75 * dim))
    }

    /// Warning lamps. Unlit lamps stay faintly visible — a dark bulb is still a
    /// bulb, and you learn where to look before it ever lights. A lamp lights
    /// for a fault, never for an absence.
    private func drawLamps(_ snapshot: Snapshot, in box: NSRect) {
        VFD.hairline.withAlphaComponent(0.55).setFill()
        NSRect(x: box.minX + 12, y: box.maxY - 30, width: box.width - 24, height: 1).fill()

        // One lamp per source; a source with several cards (two Claude
        // accounts) lights for the worst of them, needs-your-hands first.
        func colour(_ cards: [Card?]) -> NSColor? {
            let states = cards.compactMap { $0?.state }
            if states.contains("reauth") { return VFD.magenta }
            if states.contains(where: { $0 == "stale" || $0 == "blocked" }) { return VFD.amber }
            return nil
        }
        let claude = snapshot.cards(provider: "claude")
        // The fuel light: derived from the quota meters, not from any one source.
        let lowest = (claude + snapshot.cards(provider: "codex"))
            .compactMap { $0.meters.map(\.remaining).min() }
            .min()
        let low: NSColor? = lowest.map { $0 <= 8 ? VFD.red : ($0 <= 20 ? VFD.amber : nil) } ?? nil

        let lamps: [(String, NSColor?)] = [
            ("cc", colour(claude)), ("cdx", colour(snapshot.cards(provider: "codex"))),
            ("grm", colour([snapshot.card("garmin")])), ("git", colour([snapshot.card("prs")])),
            ("low", low),
        ]

        let width: CGFloat = 30
        let gap = (box.width - 24 - width * CGFloat(lamps.count))
            / CGFloat(lamps.count - 1)
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

final class PanelController: NSObject {
    private let window: NSWindow
    private var panel: ThemeView
    private let collector: String
    private let configPath: String
    private var config: PanelConfig
    private var timer: Timer?
    private var isRefreshing = false
    /// Coalesces the flood of `didMoveNotification`s a single drag produces
    /// into one disk write, and stays nil between drags.
    private var moveSaveTimer: Timer?
    /// Set while `reposition()` itself sets the frame, so that programmatic
    /// move doesn't get mistaken for a user drag and re-saved as one.
    private var isRepositioning = false
    /// True while drag mode is on and the panel is (temporarily) draggable.
    private var isInteractive = false
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    /// Retitled with drag mode, and the only place the shortcut is discoverable.
    private var dragItem: NSMenuItem?
    /// Which displays were attached last time the screen setup changed.
    private var lastDisplaySignature = PanelController.displaySignature()
    /// Held rather than assigned to `statusItem.menu`: assigning it makes the
    /// menu swallow the click before any action can run, which would leave no
    /// way to open the popover.
    private var statusMenu: NSMenu?
    private var popover: NSPopover?
    /// A second view of the same snapshot, so the popover can render the panel
    /// without disturbing the one on the desktop.
    private var popoverPanel: ThemeView?
    /// Menu bar presence. Held strongly because `NSStatusBar` does not retain
    /// its items, and an unretained one silently vanishes from the menu bar.
    private var statusItem: NSStatusItem?
    /// Retitled on toggle, so the item always names what it will do next.
    private var toggleItem: NSMenuItem?

    init(collector: String, configPath: String) {
        self.collector = collector
        self.configPath = configPath
        let config = PanelConfig.load(configPath)
        self.config = config
        let panel = ThemeView.make(config.theme)
        self.panel = panel

        // Built through locals because a subclass initializer cannot touch
        // `self` until `super.init()` has run, and `super.init()` cannot run
        // until every stored property is set.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: panel.panelWidth, height: 120),
                              styleMask: .borderless,
                              backing: .buffered,
                              defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // Resting state is exactly the original behaviour: click-through, at
        // desktop-icon level, so it lives on the wallpaper alongside real
        // desktop icons/widgets and never overlaps a normal or full-screen
        // window. Two things confirmed live and worth recording: (1) that
        // level does not reliably deliver mouseDown to a third-party window
        // even with `ignoresMouseEvents` off — it's effectively Finder/Dock
        // territory — so dragging from rest is not possible here; (2)
        // `.normal` drags fine but then sits in the ordinary app z-order and
        // can cover a maximized/full-screen window. `registerDragHotKey()`
        // below is the compromise: ⌘⇧E promotes the window to something that
        // actually receives events, you drag it, and a second ⌘⇧E drops it
        // back to this resting state.
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        window.contentView = Self.chrome(for: panel)
        window.orderFrontRegardless()
        self.window = window

        super.init()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.handleScreenChange() }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window, queue: .main) { [weak self] _ in self?.handleUserMove() }
        registerDragHotKey()
    }

    /// ⌘⇧E toggles drag mode. Carbon's `RegisterEventHotKey` rather than an
    /// `NSEvent` global monitor because a global monitor for real keystrokes
    /// (as opposed to bare modifiers) needs an Accessibility/Input Monitoring
    /// grant and silently no-ops until it gets one — awkward for a bare
    /// launchd binary. The tradeoff is that this claims the combination
    /// system-wide: while the panel runs, ⌘⇧E no longer reaches other apps.
    private func registerDragHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        // Non-capturing so it can become a C function pointer; `self` travels
        // through userData instead. Carbon delivers this on the main thread.
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context -> OSStatus in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<PanelController>.fromOpaque(context).takeUnretainedValue()
            controller.setInteractive(!controller.isInteractive)
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x41_47_57_54), id: 1)  // 'AGWT'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_E), UInt32(cmdKey | shiftKey), id,
                                         GetApplicationEventTarget(), 0, &ref)
        hotKeyRef = ref
        // -9878 is eventHotKeyExistsErr: something else already owns ⌘⇧E, and
        // the shortcut would otherwise just be silently dead.
        if status != noErr {
            FileHandle.standardError.write(
                "agent-widgets: ⌘⇧E unavailable (OSStatus \(status)); drag via the menu bar instead\n"
                    .data(using: .utf8)!)
        }
    }

    /// Drag mode. On, the window sits at `.floating` — a level dragging is
    /// guaranteed to work on — and accepts the mouse; off, it drops straight
    /// back to the inert click-through desktop-icon resting state. A discrete
    /// shortcut means this is a toggle rather than the old hold-to-drag: press
    /// once to unlock, drag, press again to put it back down.
    private func setInteractive(_ interactive: Bool) {
        guard interactive != isInteractive else { return }
        isInteractive = interactive
        if interactive {
            window.level = .floating
            window.ignoresMouseEvents = false
        } else {
            window.ignoresMouseEvents = true
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
        }
        dragItem?.title = interactive ? "Lock in Place (⌘⇧E)" : "Unlock for Dragging (⌘⇧E)"
    }

    @objc private func toggleDragMode() {
        setInteractive(!isInteractive)
    }

    // MARK: - Menu bar

    /// The panel is click-through and the app is `.accessory`, so it has no
    /// window chrome, no Dock icon and no menu of its own. This status item is
    /// the only way to reach it without `launchctl` or Activity Monitor.
    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(systemSymbolName: "speedometer", accessibilityDescription: "Agent Widgets")
        icon?.isTemplate = true
        item.button?.image = icon

        let menu = NSMenu()
        let drag = NSMenuItem(title: "Unlock for Dragging (⌘⇧E)",
                              action: #selector(toggleDragMode), keyEquivalent: "")
        drag.target = self
        menu.addItem(drag)
        let toggle = NSMenuItem(title: "Hide Panel", action: #selector(togglePanel), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quitPanel), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.button?.target = self
        item.button?.action = #selector(statusButtonClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusItem = item
        statusMenu = menu
        toggleItem = toggle
        dragItem = drag
    }

    /// Left click peeks at the panel in a popover; right click (or ⌃-click)
    /// opens the menu. The menu is attached only for as long as it takes to
    /// pop, then detached so the next left click reaches the action again.
    @objc private func statusButtonClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        guard wantsMenu, let item = statusItem else {
            togglePopover()
            return
        }
        item.menu = statusMenu
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// The desktop panel is on the wallpaper, so it is invisible whenever a
    /// window covers it. This is the same widget, rendered from the same
    /// snapshot, reachable from the menu bar regardless of what is in front.
    private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }

        let view = popoverPanel ?? ThemeView.make(config.theme)
        popoverPanel = view
        view.snapshot = panel.snapshot
        let size = NSSize(width: view.panelWidth, height: view.fittingHeight)

        let shown: NSPopover
        if let popover {
            shown = popover
        } else {
            shown = NSPopover()
            shown.behavior = .transient
            // The panel's palette is near-white on near-black; the default
            // popover material would flip light and render it unreadable.
            shown.appearance = NSAppearance(named: .darkAqua)
            let host = NSViewController()
            let content = Self.chrome(for: view)
            content.frame = NSRect(origin: .zero, size: size)
            host.view = content
            shown.contentViewController = host
            popover = shown
        }
        shown.contentSize = size

        NSApp.activate(ignoringOtherApps: true)
        shown.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// Ordering out leaves the refresh timer running, so a panel that has been
    /// hidden for an hour is current the moment it comes back — `resize()` and
    /// `reposition()` both set the frame without ordering the window in.
    @objc private func togglePanel() {
        if window.isVisible {
            window.orderOut(nil)
            toggleItem?.title = "Show Panel"
        } else {
            window.orderFrontRegardless()
            toggleItem?.title = "Hide Panel"
        }
    }

    /// Exits 0, which the LaunchAgent's `KeepAlive`/`SuccessfulExit` pair
    /// reads as deliberate: it stays quit until the next login instead of
    /// being restarted a second later.
    @objc private func quitPanel() {
        NSApp.terminate(nil)
    }

    /// The attached displays, identified by display ID rather than by frame:
    /// changing resolution is not the same as changing monitors, and should
    /// not cost you a position you chose deliberately.
    private static func displaySignature() -> String {
        NSScreen.screens
            .map {
                ($0.deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? NSNumber)?
                    .stringValue ?? "?"
            }
            .sorted()
            .joined(separator: ",")
    }

    /// `didChangeScreenParameters` fires for everything from a resolution tweak
    /// to undocking. Only a change in the display set invalidates a dragged
    /// position: coordinates chosen on a monitor that is no longer attached
    /// leave the panel somewhere you cannot see or reach it. So drop them and
    /// let corner placement take over — the position it had before you ever
    /// dragged it.
    private func handleScreenChange() {
        let signature = Self.displaySignature()
        if signature != lastDisplaySignature {
            lastDisplaySignature = signature
            clearSavedOrigin()
        }
        reposition()
    }

    /// Catches what the signature check cannot: a monitor swapped while the
    /// panel was not running has no notification to observe, so a saved origin
    /// is also validated against the displays actually present. Judged by the
    /// panel's centre — if that is on a screen, it can be seen and grabbed.
    private func discardOffscreenOrigin() {
        guard let x = config.x, let y = config.y else { return }
        let centre = NSPoint(x: x + window.frame.width / 2, y: y + window.frame.height / 2)
        if !NSScreen.screens.contains(where: { $0.visibleFrame.contains(centre) }) {
            clearSavedOrigin()
        }
    }

    /// Forgets a dragged position, in memory and on disk. Synthesized encoding
    /// omits nil optionals, so this drops the keys rather than writing nulls,
    /// and `origin(in:size:)` falls through to corner placement again.
    private func clearSavedOrigin() {
        var updated = PanelConfig.load(configPath)
        guard updated.x != nil || updated.y != nil else { return }
        updated.x = nil
        updated.y = nil
        config = updated
        if let data = try? JSONEncoder().encode(updated) {
            try? data.write(to: URL(fileURLWithPath: configPath))
        }
    }

    /// A drag just ended (or is still in flight — dragging fires many of
    /// these). Debounce so one drag becomes one write, then persist the new
    /// origin into panel.json so it survives a restart.
    private func handleUserMove() {
        guard !isRepositioning else { return }
        moveSaveTimer?.invalidate()
        moveSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            let origin = self.window.frame.origin
            let updated = self.config.saved(withOrigin: origin, at: self.configPath)
            self.config = updated
            if let data = try? JSONEncoder().encode(updated) {
                try? data.write(to: URL(fileURLWithPath: self.configPath))
            }
        }
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
                self.popoverPanel?.snapshot = snapshot
                if let popover = self.popover, popover.isShown, let view = self.popoverPanel {
                    popover.contentSize = NSSize(width: view.panelWidth, height: view.fittingHeight)
                }
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
        discardOffscreenOrigin()
        // Guarded so this programmatic move (corner default, or reapplying a
        // saved drag after a resize) is never mistaken by `handleUserMove`
        // for a fresh drag and rewritten as one.
        isRepositioning = true
        window.setFrameOrigin(config.origin(in: screen.visibleFrame, size: window.frame.size))
        isRepositioning = false
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
controller.installStatusItem()
controller.start()

app.run()
