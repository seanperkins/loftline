import Foundation
import LoftLineKit

// `loftline-cli` posts and checks a project without any window system. The app target keeps its own check for `LoftLine export …`.
exit(LoftLineCLI.run(Array(CommandLine.arguments.dropFirst()), output: .live))
