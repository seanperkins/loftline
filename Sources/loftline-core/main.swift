import Foundation
import LoftLineKit
import LoftLineMCP

// The desktop app's engine (desktop/): one JSON request per line on standard input, one reply per line on standard output.
// All G-code comes from here, through the same exporter and validator as the Mac app and the command line. With "Let
// assistants edit open documents" on, it also hosts the live link (spec 2): the stdin loop and the link take the host's lock
// around each request.
let service = CoreService()
let host = CoreLinkHost(service: service, access: AssistantAccess(settingsFile: AssistantSettings.fileURL))
if AssistantSettings.load().liveLink {
    do { try host.switchChanged(true) } catch {
        FileHandle.standardError.write(Data("loftline-core: the live link didn't start: \(error.localizedDescription)\n".utf8))
    }
}
while let line = readLine(strippingNewline: true) {
    if line.isEmpty { continue }
    let reply = host.handle(Data(line.utf8))
    FileHandle.standardOutput.write(reply)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
try? host.switchChanged(false)
