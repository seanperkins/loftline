import AppKit
import CADCore
import Foundation
import SceneKit
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct PreviewCameraTests {
    let job = JobSetup(width: 96, height: 60, thickness: 0.75)

    private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) < tol }

    @Test func topViewLooksStraightDownWithYUp() {
        let pose = PreviewCameraPose(direction: .top, job: job, fieldOfView: 40, aspect: 1.6)
        #expect(near(pose.eye.x, 48) && near(pose.eye.y, 30))
        #expect(pose.eye.z > 0)
        #expect(near(pose.up.y, 1))
        // 96 x 60 at aspect 1.6 needs half-height 30 either way, plus the margin.
        #expect(near(pose.orthographicScale, 30 * PreviewCameraPose.margin))
    }

    @Test func frontAndSideViewsStandOnTheirSide() {
        let front = PreviewCameraPose(direction: .front, job: job)
        #expect(front.eye.y < 0 && near(front.eye.x, 48))
        #expect(near(front.up.z, 1))
        let left = PreviewCameraPose(direction: .left, job: job)
        #expect(left.eye.x < 0 && near(left.eye.y, 30))
        let right = PreviewCameraPose(direction: .right, job: job)
        #expect(right.eye.x > 96)
        let back = PreviewCameraPose(direction: .back, job: job)
        #expect(back.eye.y > 60)
        let bottom = PreviewCameraPose(direction: .bottom, job: job)
        #expect(bottom.eye.z < -0.75)
    }

    @Test func everyViewFramesTheWholeStock() {
        for d in PreviewViewDirection.allCases {
            let pose = PreviewCameraPose(direction: d, job: job, fieldOfView: 40, aspect: 1.5)
            let forward = (pose.target - pose.eye).normalized
            #expect(near(forward.dot(pose.up), 0, 1e-9), "up is perpendicular for \(d)")
            #expect(near(pose.up.length, 1, 1e-9))
            let right = forward.cross(pose.up)
            let tanHalf = tan(20 * Double.pi / 180)
            // Every stock corner lies inside the perspective frustum.
            for x in [0.0, 96] { for y in [0.0, 60] { for z in [0.0, -0.75] {
                let v = Vec3(x, y, z) - pose.eye
                let depth = v.dot(forward)
                #expect(depth > 0)
                #expect(abs(v.dot(pose.up)) <= depth * tanHalf + 1e-9, "\(d) vertical")
                #expect(abs(v.dot(right)) <= depth * tanHalf * 1.5 + 1e-9, "\(d) horizontal")
            } } }
        }
    }

    @Test func orthographicScaleMatchesPerspectiveAtTarget() {
        #expect(near(PreviewCameraPose.orthographicScale(distance: 10, fieldOfView: 90), 10, 1e-9))
    }

    @Test @MainActor func sceneSwitchesDirectionAndProjection() {
        let scene = StockScene()
        scene.configure(job: job)
        scene.setView(.top)
        #expect(scene.viewDirection == .top)
        // Material +Z is scene +Y: the top camera sits above the stock.
        #expect(scene.cameraNode.position.y > 10)
        scene.isOrthographic = true
        #expect(scene.cameraNode.camera?.usesOrthographicProjection == true)
        #expect((scene.cameraNode.camera?.orthographicScale ?? 0) > 30)
        scene.configure(job: JobSetup(width: 24, height: 12, thickness: 0.75))
        #expect(scene.viewDirection == .top) // kept across re-simulation
        scene.isOrthographic = false
        #expect(scene.cameraNode.camera?.usesOrthographicProjection == false)
    }
}
