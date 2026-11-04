import Foundation
import LoftLineKit

// The desktop app's engine (desktop/): one JSON request per line on standard input, one reply per line on standard output.
// All G-code comes from here, through the same exporter and validator as the Mac app and the command line.
let service = CoreService()
while let line = readLine(strippingNewline: true) {
    if line.isEmpty { continue }
    let reply = service.handle(Data(line.utf8))
    FileHandle.standardOutput.write(reply)
    FileHandle.standardOutput.write(Data("\n".utf8))
}
