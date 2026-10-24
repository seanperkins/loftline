import Foundation

/// Runs the repo's shell scripts (scripts/, packaging/) with `Process`, so the release tooling is tested like any other code.
enum ScriptRunner {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct Output {
        var status: Int32
        var out: String
        var err: String
    }

    /// Runs `executable` with `args`. The environment is the test process's, minus any `LOFTLINE_UPDATER_*` it
    /// inherited, plus `env`. Standard input is `input` (empty by default), never the test runner's own, so a script
    /// that prompts cannot hang a test.
    @discardableResult
    static func exec(_ executable: String, _ args: [String], env: [String: String] = [:], input: String = "") throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("LOFTLINE_UPDATER_") }
        environment.merge(env) { _, new in new }
        process.environment = environment
        let stdin = Pipe(), out = Pipe(), err = Pipe()
        process.standardInput = stdin
        process.standardOutput = out
        process.standardError = err
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus,
                      out: String(decoding: outData, as: UTF8.self), err: String(decoding: errData, as: UTF8.self))
    }

    /// Runs a script by its path relative to the repo root.
    @discardableResult
    static func script(_ path: String, _ args: [String] = [], env: [String: String] = [:], input: String = "") throws -> Output {
        try exec(root.appendingPathComponent(path).path, args, env: env, input: input)
    }
}
