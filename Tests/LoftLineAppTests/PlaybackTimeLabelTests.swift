import AppKit
import SwiftUI
import Testing
@testable import LoftLineApp

/// The 3D preview's playback bar wraps onto more lines in a narrow pane. A time label whose width changed as the clock
/// ran ("9s / 15m 37s" to "1m 00s / 15m 37s") re-wrapped the bar mid-playback, the 3D view above it shrank, and the
/// stock looked as if it jumped or resized with the tool. The label must keep one width for the whole simulation.
@Suite @MainActor struct PlaybackTimeLabelTests {
    func width(time: TimeInterval, total: TimeInterval) -> CGFloat {
        NSHostingView(rootView: PlaybackTimeLabel(time: time, total: total)).fittingSize.width
    }

    @Test func theLabelKeepsOneWidthWhileTheClockRuns() {
        for total in [937.0, 59.0, 3723.0] {
            let widths = Set([0, 1, 9, 10, 59, 60, 61, 599, 600, 3599, total].filter { $0 <= total }
                .map { width(time: $0, total: total) })
            #expect(widths.count == 1, "total \(total): \(widths.sorted())")
        }
    }

    @Test func itStillShowsTheTimes() {
        #expect(PlaybackTimeLabel.text(time: 62, total: 937) == "1m 02s / 15m 37s")
    }

    /// The spinner that shows while a frame renders came and went in the same wrapping bar, and its height made the bar
    /// taller for a moment on every frame: the 3D view above shrank and grew, and the stock jumped with the tool.
    @Test func theBusySpinnerTakesTheSameRoomShownOrNot() {
        let shown = NSHostingView(rootView: BusyIndicator(isBusy: true)).fittingSize
        let hidden = NSHostingView(rootView: BusyIndicator(isBusy: false)).fittingSize
        #expect(shown == hidden, "shown \(shown), hidden \(hidden)")
        #expect(shown.height <= 16, "no taller than the bar's icons: \(shown)")
    }
}
