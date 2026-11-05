// Standard view directions and camera framing for the 3D preview. Owned by preview.
import CADCore
import Foundation
import LoftLineKit

/// A standard direction to look at the stock from. Directions are named for where the viewer
/// stands relative to the machine: "front" is the material's low-Y edge (the operator side).
enum PreviewViewDirection: String, CaseIterable, Identifiable, Sendable {
    case threeQuarter, iso, top, front, back, left, right, bottom

    var id: Self { self }

    var title: String {
        switch self {
        case .threeQuarter: return "Default (Front, Above)"
        case .iso: return "Isometric"
        case .top: return "Top"
        case .front: return "Front"
        case .back: return "Back"
        case .left: return "Left"
        case .right: return "Right"
        case .bottom: return "Bottom"
        }
    }

    var systemImage: String {
        switch self {
        case .threeQuarter: return "camera.metering.center.weighted"
        case .iso: return "cube"
        case .top: return "square.tophalf.filled"
        case .front: return "rectangle.bottomhalf.filled"
        case .back: return "rectangle.tophalf.filled"
        case .left: return "rectangle.lefthalf.filled"
        case .right: return "rectangle.righthalf.filled"
        case .bottom: return "square.bottomhalf.filled"
        }
    }

    /// Unit vector from the stock centre towards the eye, in the material frame (z up).
    var eyeDirection: Vec3 {
        switch self {
        case .threeQuarter: return Vec3(0, -1.1, 0.9).normalized
        case .iso: return Vec3(1, -1, 1).normalized
        case .top: return Vec3(0, 0, 1)
        case .front: return Vec3(0, -1, 0)
        case .back: return Vec3(0, 1, 0)
        case .left: return Vec3(-1, 0, 0)
        case .right: return Vec3(1, 0, 0)
        case .bottom: return Vec3(0, 0, -1)
        }
    }

    /// Approximate screen-up direction (material frame); made exact by `PreviewCameraPose`.
    var upHint: Vec3 {
        switch self {
        case .top, .bottom: return Vec3(0, 1, 0)
        default: return Vec3(0, 0, 1)
        }
    }
}

/// Where the preview camera sits for a view direction, framing the whole stock.
/// All points are in the material frame (x right, y away from the operator, z up, top at z = 0).
struct PreviewCameraPose: Equatable, Sendable {
    var eye: Vec3
    var target: Vec3
    /// Exact screen-up unit vector (perpendicular to the view direction).
    var up: Vec3
    /// Half the visible height when the camera is orthographic.
    var orthographicScale: Double

    /// Margin around the stock in the framed view.
    static let margin = 1.1

    /// Frames the stock box of `job` seen from `direction`.
    /// - Parameters:
    ///   - fieldOfView: vertical field of view in degrees (perspective).
    ///   - aspect: view width / height.
    init(direction: PreviewViewDirection, job: JobSetup, fieldOfView: Double = 40, aspect: Double = 1.5) {
        let w = max(job.width, 1e-6), h = max(job.height, 1e-6), t = max(job.thickness, 1e-6)
        target = Vec3(w / 2, h / 2, -t / 2)
        let back = direction.eyeDirection.normalized        // centre → eye
        let forward = back * -1
        let right = forward.cross(direction.upHint).normalized
        up = right.cross(forward).normalized

        // Extents of the stock box projected onto the screen axes.
        var halfW = 0.0, halfH = 0.0, halfD = 0.0
        for sx in [-1.0, 1.0] { for sy in [-1.0, 1.0] { for sz in [-1.0, 1.0] {
            let c = Vec3(sx * w / 2, sy * h / 2, sz * t / 2)
            halfW = max(halfW, abs(c.dot(right)))
            halfH = max(halfH, abs(c.dot(up)))
            halfD = max(halfD, abs(c.dot(back)))
        } } }
        let a = max(aspect, 1e-3)
        let fitHalfHeight = max(halfH, halfW / a) * Self.margin
        orthographicScale = fitHalfHeight
        let tanHalf = tan(max(fieldOfView, 1) * .pi / 360)
        let distance = fitHalfHeight / tanHalf + halfD
        eye = target + back * distance
    }

    /// Orthographic scale showing what a perspective camera `distance` from its target sees there.
    static func orthographicScale(distance: Double, fieldOfView: Double) -> Double {
        max(distance, 1e-6) * tan(max(fieldOfView, 1) * .pi / 360)
    }
}
