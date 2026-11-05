import CADCore
import SwiftUI
import LoftLineKit

/// "Images" section of the Design sidebar: one row per tracing image with an editor popover.
struct PlacedImagesSection: View {
    @ObservedObject var document: LoftLineDocument

    var body: some View {
        if !document.document.placedImages.isEmpty {
            Section("Images") {
                ForEach(document.document.placedImages) { img in
                    PlacedImageRow(document: document, image: img)
                }
            }
        }
    }
}

struct PlacedImageRow: View {
    @ObservedObject var document: LoftLineDocument
    var image: PlacedImage
    @State private var editing = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo").foregroundStyle(.secondary).frame(width: 16)
            Text(image.name).lineLimit(1)
            Spacer()
            Button { toggleVisible() } label: { Image(systemName: image.isVisible ? "eye" : "eye.slash") }
                .buttonStyle(.icon).help(image.isVisible ? "Hide image" : "Show image")
            Button { editing = true } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.icon).help("Position, size, crop and fade")
                .popover(isPresented: $editing, arrowEdge: .trailing) {
                    PlacedImageEditor(document: document, image: image) { editing = false }
                }
        }
        .contextMenu {
            Button("Edit Image…") { editing = true }
            Button(image.isVisible ? "Hide" : "Show") { toggleVisible() }
            Divider()
            Button("Delete Image") { document.deleteImage(image.id) }
        }
    }

    private func toggleVisible() {
        var i = image
        i.isVisible.toggle()
        document.updateImage(i, actionName: i.isVisible ? "Show Image" : "Hide Image")
    }
}

struct PlacedImageEditor: View {
    @ObservedObject var document: LoftLineDocument
    var image: PlacedImage
    var done: () -> Void
    @State private var form: ImageEditForm

    init(document: LoftLineDocument, image: PlacedImage, done: @escaping () -> Void) {
        self.document = document; self.image = image; self.done = done
        _form = State(initialValue: ImageEditForm(image))
    }

    var body: some View {
        let u = document.units
        Form {
            TextField("Name", text: $form.name)
            Section("Position and size") {
                LengthField("X (left)", value: $form.x, units: u)
                LengthField("Y (bottom)", value: $form.y, units: u)
                LengthField("Width", value: Binding(get: { form.width }, set: { form.setWidth($0) }), units: u)
                LengthField("Height", value: Binding(get: { form.height }, set: { form.setHeight($0) }), units: u)
                Toggle("Lock aspect ratio", isOn: $form.lockAspect)
                Button("Fit to Material") {
                    form.fit(to: document.document.job,
                             pixelAspect: Double(image.pixelHeight) / Double(max(image.pixelWidth, 1)))
                }
            }
            Section("Fade") {
                Slider(value: $form.fadePercent, in: 0...95) { Text("Fade") }
                Text("\(Int(form.fadePercent))% faded").font(.caption).foregroundStyle(.secondary)
            }
            Section("Crop (% of the image)") {
                NumberField("Left", value: $form.cropLeft, unit: "%")
                NumberField("Right", value: $form.cropRight, unit: "%")
                NumberField("Bottom", value: $form.cropBottom, unit: "%")
                NumberField("Top", value: $form.cropTop, unit: "%")
            }
            Toggle("Visible", isOn: $form.isVisible)
            Text("\(image.pixelWidth) × \(image.pixelHeight) px. Tracing images are for reference only; they never make toolpaths.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Delete", role: .destructive) { document.deleteImage(image.id); done() }
                Spacer()
                Button("Cancel") { done() }
                Button("Apply") {
                    document.updateImage(form.apply(to: image), actionName: "Edit Image")
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 340)
    }
}

extension LoftLineDocument {
    func updateImage(_ img: PlacedImage, actionName: String) {
        perform(actionName) { p in
            if let i = p.document.placedImages.firstIndex(where: { $0.id == img.id }) { p.document.placedImages[i] = img }
        }
    }

    func deleteImage(_ id: UUID) {
        perform("Delete Image") { $0.document.placedImages.removeAll { $0.id == id } }
    }
}
