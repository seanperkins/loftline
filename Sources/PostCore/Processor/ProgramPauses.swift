import CAMCore
import Foundation

/// The operator pauses a program writes, worked out once from the toolpaths in the order it writes them: a stop
/// stands only between two toolpaths that cut, since the program's own end already stops the machine. The builder, its
/// header, the job sheet and the job summary all read pauses from here, so what they list is what the machine does.
public enum ProgramPauses {
    /// `toolpaths` with `pauseAfter` kept only on a toolpath that has moves and is followed by another that has moves.
    public static func effective(_ toolpaths: [Toolpath]) -> [Toolpath] {
        let lastCutting = toolpaths.lastIndex { !$0.moves.isEmpty }
        return toolpaths.enumerated().map { i, tp in
            guard tp.pauseAfter != nil else { return tp }
            var t = tp
            if tp.moves.isEmpty || lastCutting.map({ i >= $0 }) ?? true { t.pauseAfter = nil }
            return t
        }
    }
}
