#if DEBUG
import AppKit
import LoftLineKit

/// Frames of the document window taken at a fixed rate while a scenario runs, for `scripts/reel.sh` to turn
/// into a GIF or MP4. Each frame is the window with its sheet, the synthetic pointer and the caption drawn
/// in (`HarnessCapture.frame`). Frames are PNG-encoded off the main thread; `<name>.ffconcat` lists them
/// with the real time each was on screen, so a slow frame is held rather than dropped.
@MainActor
final class HarnessRecorder {
    let name: String
    let fps: Double
    private let framesDir: URL
    private let listURL: URL
    private var frames: [(file: String, time: TimeInterval)] = []
    private var task: Task<Void, Never>?
    private let started = Date()
    private let encoder = DispatchQueue(label: "loftline.harness.recorder", qos: .userInitiated)
    /// Draws the current frame; nil skips the tick.
    var frameProvider: @MainActor () -> NSBitmapImageRep? = { nil }

    init(name: String, outDir: URL, fps: Double) throws {
        self.name = name
        self.fps = max(1, min(fps, 30))
        framesDir = outDir.appendingPathComponent(name + ".frames", isDirectory: true)
        listURL = outDir.appendingPathComponent(name + ".ffconcat")
        try? FileManager.default.removeItem(at: framesDir)
        try FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
    }

    func start() {
        let interval = 1 / fps
        task = Task { @MainActor [weak self] in
            var next = Date()
            while !Task.isCancelled {
                self?.tick()
                next = next.addingTimeInterval(interval)
                let wait = next.timeIntervalSinceNow
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
                } else {
                    // Behind schedule (a slow frame): let the scenario's own steps run before the next frame.
                    next = Date()
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
        }
    }

    /// Time spent drawing frames on the main thread, to report the real capture cost.
    private(set) var captureSeconds: TimeInterval = 0

    private func tick() {
        let began = Date()
        defer { captureSeconds += Date().timeIntervalSince(began) }
        guard let rep = frameProvider() else { return }
        let file = String(format: "%05d.png", frames.count)
        frames.append((file, Date().timeIntervalSince(started)))
        let url = framesDir.appendingPathComponent(file)
        encoder.async { try? rep.representation(using: .png, properties: [:])?.write(to: url) }
    }

    /// Stops, waits for every frame to be written and writes the ffconcat list, each frame held until the
    /// next one was taken (the last file is repeated, as ffmpeg's concat demuxer needs).
    func stop() async -> (count: Int, seconds: Double) {
        task?.cancel()
        task = nil
        tick()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in encoder.async { c.resume() } }
        var lines = ["ffconcat version 1.0"]
        for (i, f) in frames.enumerated() {
            let next = i + 1 < frames.count ? frames[i + 1].time : f.time + 1 / fps
            lines.append("file '\(name).frames/\(f.file)'")
            lines.append(String(format: "duration %.4f", max(next - f.time, 0.001)))
        }
        if let last = frames.last { lines.append("file '\(name).frames/\(last.file)'") }
        try? (lines.joined(separator: "\n") + "\n").write(to: listURL, atomically: true, encoding: .utf8)
        return (frames.count, frames.last.map { $0.time + 1 / fps } ?? 0)
    }
}
#endif
