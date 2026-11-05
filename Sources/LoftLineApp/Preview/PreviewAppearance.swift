// Material look of the 3D preview (preset, paint, machined colour). Owned by preview.
// Stored per user in UserDefaults.
import AppKit
import CAMCore
import SwiftUI
import LoftLineKit

/// CAMCore.RGBColor (QuickDraw also exports an `RGBColor`).
typealias StockColor = CAMCore.RGBColor

struct PreviewAppearanceSettings: Equatable, Sendable {
    var material: StockAppearance.Material = .pine
    var paintTop = false
    var paintColor = StockColor(0.10, 0.20, 0.45)
    var colorMachined = false
    var machinedColor = StockColor(0.95, 0.75, 0.20)

    static let materialKey = "loftline.preview.material"
    static let paintTopKey = "loftline.preview.paintTop"
    static let paintColorKey = "loftline.preview.paintColor"
    static let colorMachinedKey = "loftline.preview.colorMachined"
    static let machinedColorKey = "loftline.preview.machinedColor"

    var appearance: StockAppearance {
        var a = StockAppearance.preset(material)
        a.paint = paintTop ? paintColor : nil
        a.machinedOverride = colorMachined ? machinedColor : nil
        return a
    }

    static func load(from d: UserDefaults = .standard) -> PreviewAppearanceSettings {
        var s = PreviewAppearanceSettings()
        if let m = d.string(forKey: materialKey).flatMap(StockAppearance.Material.init(rawValue:)) { s.material = m }
        s.paintTop = d.bool(forKey: paintTopKey)
        if let c = d.string(forKey: paintColorKey).flatMap(StockColor.init(hex:)) { s.paintColor = c }
        s.colorMachined = d.bool(forKey: colorMachinedKey)
        if let c = d.string(forKey: machinedColorKey).flatMap(StockColor.init(hex:)) { s.machinedColor = c }
        return s
    }

    func save(to d: UserDefaults = .standard) {
        d.set(material.rawValue, forKey: Self.materialKey)
        d.set(paintTop, forKey: Self.paintTopKey)
        d.set(paintColor.hex, forKey: Self.paintColorKey)
        d.set(colorMachined, forKey: Self.colorMachinedKey)
        d.set(machinedColor.hex, forKey: Self.machinedColorKey)
    }
}

@MainActor
final class PreviewAppearanceStore: ObservableObject {
    static let shared = PreviewAppearanceStore()

    @Published var settings: PreviewAppearanceSettings {
        didSet { if settings != oldValue { settings.save() } }
    }

    init(defaults: UserDefaults = .standard) { settings = .load(from: defaults) }
}

extension StockColor {
    /// "#RRGGBB".
    var hex: String {
        func c(_ v: Float) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(Float((v >> 16) & 0xFF) / 255, Float((v >> 8) & 0xFF) / 255, Float(v & 0xFF) / 255)
    }

    var swiftUIColor: Color { Color(nsColor: nsColor) }
    var nsColor: NSColor { NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        self.init(Float(ns.redComponent), Float(ns.greenComponent), Float(ns.blueComponent))
    }
}

/// Popover in the 3D preview controls.
struct PreviewAppearancePopover: View {
    @ObservedObject var store: PreviewAppearanceStore

    private func color(_ kp: WritableKeyPath<PreviewAppearanceSettings, StockColor>) -> Binding<Color> {
        Binding(get: { store.settings[keyPath: kp].swiftUIColor },
                set: { store.settings[keyPath: kp] = StockColor($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Material Appearance").font(.headline)
            Picker("Material", selection: $store.settings.material) {
                ForEach(StockAppearance.Material.allCases) { Text($0.displayName).tag($0) }
            }
            HStack {
                Toggle("Painted top", isOn: $store.settings.paintTop)
                Spacer()
                ColorPicker("Paint color", selection: color(\.paintColor), supportsOpacity: false)
                    .labelsHidden().disabled(!store.settings.paintTop)
            }
            .help("Color the uncut surface; carved areas show bare material")
            HStack {
                Toggle("Color machined areas", isOn: $store.settings.colorMachined)
                Spacer()
                ColorPicker("Machined color", selection: color(\.machinedColor), supportsOpacity: false)
                    .labelsHidden().disabled(!store.settings.colorMachined)
            }
            .help("Show every cut in one flat color")
            Button("Restore Defaults") { store.settings = PreviewAppearanceSettings() }
        }
        .padding(14)
        .frame(width: 300)
    }
}
