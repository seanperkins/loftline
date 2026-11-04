import AppKit
import CADCore
import CAMCore
import SwiftUI
import UniformTypeIdentifiers
import LoftLineKit

/// Photo V-Carve settings: the picture, where it sits on the material and the groove pattern.
struct PhotoVCarveForm: View {
    @Binding var params: PhotoVCarveParameters
    var units: LengthUnit
    var job: JobSetup
    @State private var loadError: String?

    var body: some View {
        InspectorSection(title: "Picture") {
            HStack {
                Text(params.image == nil ? "No image chosen" : params.imageName)
                    .foregroundStyle(params.image == nil ? .orange : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(params.image == nil ? "Choose Image…" : "Replace…") { chooseImage() }
            }
            if let image = params.image {
                Text("\(image.width) × \(image.height) px (grayscale)").font(.caption).foregroundStyle(.secondary)
                if let preview = Self.preview(image) {
                    Image(nsImage: preview).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 140)
                }
            }
            if let loadError { Text(loadError).font(.caption).foregroundStyle(Color.warningText) }
            LengthField("Left (X)", value: Binding(get: { params.origin.x }, set: { params.origin.x = $0 }), units: units,
                        help: "Left edge of the picture on the material")
            LengthField("Bottom (Y)", value: Binding(get: { params.origin.y }, set: { params.origin.y = $0 }), units: units,
                        help: "Bottom edge of the picture on the material")
            LengthField("Width", value: $params.width, units: units, help: "Width of the picture; the height keeps its proportions")
            LabeledContent("Height") {
                Text("\(RulerTicks.label((params.height * 1000).rounded() / 1000)) \(units.abbreviation)").monospacedDigit()
            }
            Button("Fit to Material") { params = params.fitted(in: job) }
        }
        Divider()
        InspectorSection(title: "Grooves") {
            LengthField("Line spacing", value: $params.lineSpacing, units: units,
                        help: "Distance between groove centers; black areas are carved this wide")
            NumberField("Line angle", value: $params.angle, unit: "°", help: "0° = horizontal grooves")
            LengthField("Min depth", value: $params.minDepth, units: units, help: "Shallower grooves are skipped (light areas)")
            LengthField("Start depth", value: $params.startDepth, units: units)
            Toggle("Invert (carve light areas)", isOn: $params.invert)
                .fieldHelp("Invert (carve light areas)")
            Text("Dark areas get wide, deep grooves and light areas narrow ones, so the picture shows when the grooves are darker than the wood (or filled with paint).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a photo to carve"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let image = try PhotoImageLoader.load(url)
            let hadImage = params.image != nil
            params.image = image
            params.imageName = url.lastPathComponent
            if !hadImage { params = params.fitted(in: job) }
            loadError = nil
        } catch {
            loadError = "Could not read \(url.lastPathComponent) as an image."
        }
    }

    /// Small greyscale preview of the stored pixels.
    static func preview(_ image: GrayImage) -> NSImage? {
        guard let provider = CGDataProvider(data: image.pixels as CFData),
              let cg = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 8,
                               bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                               decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: image.width, height: image.height))
    }
}
