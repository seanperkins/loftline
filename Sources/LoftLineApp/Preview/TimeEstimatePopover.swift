// Time-estimate settings popover (3D preview controls). Owned by preview.
import CADCore
import CAMCore
import SwiftUI
import LoftLineKit

struct TimeEstimatePopover: View {
    @ObservedObject var store: TimeEstimateStore
    /// The job being previewed (for calibration).
    var toolpaths: [Toolpath]
    var rapidRate: Double
    var units: LengthUnit

    @State private var actualMinutes: Double = 0
    @State private var message: String?

    private var accelBinding: Binding<Double> {
        let f = LengthUnit.inch.factor(to: units)
        return Binding(get: { store.settings.accelerationInchPerSec2 * f },
                       set: { store.settings.accelerationInchPerSec2 = max(0.01, $0 / f) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Time Estimate").font(.headline)
            Toggle("Include acceleration and cornering", isOn: $store.settings.useAcceleration)
            NumberField("Acceleration", value: accelBinding, unit: units.abbreviation + "/s²",
                        help: "How fast the machine speeds up and slows down")
                .disabled(!store.settings.useAcceleration)
            NumberField("Tool change", value: Binding(get: { store.settings.toolChangeSeconds },
                                                      set: { store.settings.toolChangeSeconds = TimeEstimateSettings.clampToolChange($0) }),
                        unit: "s", help: "Time allowed for each manual tool change")
            NumberField("Scale factor", value: Binding(get: { store.settings.scale },
                                                      set: { store.settings.scale = TimeEstimateSettings.clampScale($0) }),
                        unit: "×", help: "Multiplies motion time; calibrate it against a real run")
            Divider()
            Text("Calibrate from a real run").font(.subheadline.bold())
            Text("Enter how long this job actually took on the machine. The scale factor is set so the estimate matches.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                NumberField("Actual time", value: $actualMinutes, unit: "min")
                Button("Calibrate", action: calibrate).disabled(actualMinutes <= 0 || toolpaths.isEmpty)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            Divider()
            HStack {
                Button("Restore Defaults") { store.settings = TimeEstimateSettings(); message = nil }
                Spacer()
                Text("Estimate: " + MachiningTimeEstimator.format(
                    store.settings.estimate(toolpaths, rapidRate: rapidRate, units: units)))
                    .font(.caption.monospacedDigit())
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func calibrate() {
        let parts = store.settings.calibrationParts(toolpaths, rapidRate: rapidRate, units: units)
        guard let s = TimeEstimateSettings.calibratedScale(motionSeconds: parts.motion, fixedSeconds: parts.fixed,
                                                           actualSeconds: actualMinutes * 60) else {
            message = "The actual time must be longer than the tool-change allowances."
            return
        }
        store.settings.scale = s
        message = String(format: "Scale factor set to %.3f.", s)
    }
}
