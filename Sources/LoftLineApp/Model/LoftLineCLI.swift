import CADCore
import CAMCore
import Foundation
import PostCore

/// The command line: posts a `.loftline` project the way the Export G-code sheet does, so a script or a CI job can
/// check or regenerate a program without opening a window.
///
///     loftline-cli export <file.loftline> [--post <id>] [--operation <name>] [--out <dir>|-] [--side top|bottom]
///                     [--name <job name>] [--group-by-tool] [--builtin-only] [--force] [--quiet]
///     loftline-cli posts [--builtin-only]
///
/// The same code runs as `LoftLine export …`: the executable decides before it starts the app (see main.swift).
/// Exit status: 0 = written with no validator errors; 1 = validator errors (nothing is written unless `--force`) or
/// nothing to export; 2 = a usage error, an unreadable or invalid project, an unknown post or toolpath, or a failed write.
enum LoftLineCLI {
    /// Where the output goes; tests capture it.
    struct Output {
        var standardOutput: (String) -> Void
        var standardError: (String) -> Void

        static let live = Output(
            standardOutput: { FileHandle.standardOutput.write(Data($0.utf8)) },
            standardError: { FileHandle.standardError.write(Data($0.utf8)) })
    }

    static let commands: Set<String> = ["export", "posts", "help", "--help", "-h"]

    static let usage = """
        usage: loftline-cli export <file.loftline> [options]
               loftline-cli posts [--builtin-only]

        export posts the project as the Export G-code sheet does and checks it with the same validator. Issues go to
        standard error; the file is written to --out (default: the current folder) as <file>[_<toolpath>].<extension>.

        options:
          --post <id>          post processor (default: the project's); `loftline-cli posts` lists them
          --operation <name>   only that toolpath, with its own sheet and side
          --out <dir>|-        folder to write to (created if needed), or - for standard output
          --side top|bottom    which side of a two-sided job the whole program is for (default top); a toolpath asked for
                       by name is posted with its own sheet and side
          --name <text>        job name in the program header (default: the project's name)
          --group-by-tool      order the program by tool, as the Export sheet's option does
          --builtin-only       ignore the user's posts and machines in Application Support (for CI)
          --force              write the program even when the validator reports errors (the status stays 1); never
                       when a toolpath failed to calculate
          --quiet              do not print the written file's name

        With --out - the program is written to standard output exactly as the post made it.

        exit status: 0 ok, 1 validator errors or nothing to export, 2 usage or file error
        """

    /// The status to exit with when `arguments` (the process's, program name first) ask for the command line, else nil.
    /// A binary called `loftline-cli` is always the command line; the app binary only for a command name.
    static func runIfRequested(_ arguments: [String]) -> Int32? {
        guard let program = arguments.first else { return nil }
        let rest = Array(arguments.dropFirst())
        if URL(fileURLWithPath: program).lastPathComponent == "loftline-cli" { return run(rest, output: .live) }
        guard let first = rest.first, commands.contains(first) else { return nil }
        return run(rest, output: .live)
    }

    /// Runs one command. `arguments` are the words after the program name.
    static func run(_ arguments: [String], output: Output) -> Int32 {
        guard let command = arguments.first else {
            output.standardError(usage + "\n")
            return 2
        }
        switch command {
        case "help", "--help", "-h":
            output.standardOutput(usage + "\n")
            return 0
        case "posts":
            return posts(Array(arguments.dropFirst()), output: output)
        case "export":
            return export(Array(arguments.dropFirst()), output: output)
        default:
            output.standardError("error: unknown command \"\(command)\"\n\(usage)\n")
            return 2
        }
    }

    // MARK: Options

    struct Options {
        var file: String?
        var post: String?
        var operation: String?
        var out: String?
        var side: JobSide = .top
        var name: String?
        var groupByTool = false
        var builtinOnly = false
        var force = false
        var quiet = false
    }

    /// The options in `arguments`, or the reason they are not usable.
    static func parse(_ arguments: [String]) -> Result<Options, ParseError> {
        var o = Options()
        var words = arguments[...]
        while let word = words.popFirst() {
            guard word.hasPrefix("--") else {
                guard o.file == nil else { return .failure(ParseError("unexpected argument \"\(word)\"")) }
                o.file = word
                continue
            }
            var name = word
            var inline: String?
            if let eq = word.firstIndex(of: "=") {
                name = String(word[..<eq])
                inline = String(word[word.index(after: eq)...])
            }
            // The next word is the value unless it is another option (`--out --force` is a missing value, not a folder
            // named --force); `--out=--force` is how to name one.
            func value() -> String? {
                if let inline { return inline }
                guard let next = words.first, !next.hasPrefix("--") else { return nil }
                return words.popFirst()
            }
            switch name {
            case "--post", "--operation", "--out", "--side", "--name":
                guard let v = value() else { return .failure(ParseError("\(name) needs a value")) }
                switch name {
                case "--post": o.post = v
                case "--operation": o.operation = v
                case "--out": o.out = v
                case "--name": o.name = v
                default:
                    guard let side = JobSide(rawValue: v) else { return .failure(ParseError("--side is top or bottom")) }
                    o.side = side
                }
            case "--group-by-tool", "--builtin-only", "--force", "--quiet":
                guard inline == nil else { return .failure(ParseError("\(name) takes no value")) }
                switch name {
                case "--group-by-tool": o.groupByTool = true
                case "--builtin-only": o.builtinOnly = true
                case "--force": o.force = true
                default: o.quiet = true
                }
            default:
                return .failure(ParseError("unknown option \(name)"))
            }
        }
        return .success(o)
    }

    struct ParseError: Error {
        var message: String
        init(_ message: String) { self.message = message }
    }

    /// The post and machine stores: the user's folders, or the built-ins alone.
    private static func stores(builtinOnly: Bool) -> (posts: PostProfileStore, machines: MachineStore) {
        var posts = PostProfileStore(), machines = MachineStore()
        if builtinOnly {
            posts.readsUserFiles = false
            machines.readsUserFiles = false
        }
        return (posts, machines)
    }

    // MARK: posts

    private static func posts(_ arguments: [String], output: Output) -> Int32 {
        guard arguments.allSatisfy({ $0 == "--builtin-only" }) else {
            output.standardError("error: posts takes only --builtin-only\n")
            return 2
        }
        let options = Options(builtinOnly: !arguments.isEmpty)
        let loaded = stores(builtinOnly: options.builtinOnly).posts.load()
        for line in skippedMessages(loaded.skipped) { output.standardError(line) }
        for profile in loaded.profiles {
            output.standardOutput("\(profile.id)\t\(profile.name)\n")
        }
        return 0
    }

    /// One warning line per post file that did not load.
    static func skippedMessages(_ skipped: [SkippedPost]) -> [String] {
        skipped.map { "warning: post file \($0.fileName) did not load: \($0.reason)\n" }
    }

    // MARK: post resolution

    /// The post to write with, the project's own post (which sets the rapid rate), and the notices. The machine is the
    /// one the project as opened resolves to (its copy, or the machine inferred from its own post). `--post <id>`
    /// replaces only the post, with the installed one, never the project's copy of it, even when the ids are equal; it
    /// answers the project's own post being missing or differing, so those notices are left out. nil = no such post.
    static func resolvePost(project: LoftLineProject, override: String?, profiles: [PostProfile],
                            machines: [MachineDefinition]) -> (profile: PostProfile, own: PostProfile, issues: [GCodeIssue])? {
        let own = ProjectPost.resolve(project, profiles: profiles, machines: machines)
        guard let id = override else {
            return (own.post, own.post, ProjectPost.issues(for: project, profiles: profiles, machines: machines))
        }
        guard let installed = profiles.first(where: { $0.id == id }) else { return nil }
        return (MachineResolver.effectiveProfile(installed, machine: own.machine), own.post,
                ProjectPost.issues(for: project, profiles: profiles, machines: machines, includingPost: false))
    }

    // MARK: export

    private static func export(_ arguments: [String], output: Output) -> Int32 {
        let options: Options
        switch parse(arguments) {
        case .failure(let e):
            output.standardError("error: \(e.message)\n\(usage)\n")
            return 2
        case .success(let o): options = o
        }
        guard let path = options.file else {
            output.standardError("error: export needs a .loftline file\n\(usage)\n")
            return 2
        }
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) } catch {
            output.standardError("error: cannot read \(path): \(error.localizedDescription)\n")
            return 2
        }
        let project: LoftLineProject
        do { project = try LoftLineProject.opening(from: data) } catch {
            output.standardError("error: \(path) is not a LoftLine project: \(ProjectOpenError(error).message)\n")
            return 2
        }

        // The post and the machine, as the document resolves them: the project's own copies first (`ProjectPost`).
        let stores = stores(builtinOnly: options.builtinOnly)
        let loadedPosts = stores.posts.load()
        for line in skippedMessages(loadedPosts.skipped) { output.standardError(line) }
        let profiles = loadedPosts.profiles
        let machines = stores.machines.allMachines()
        let units = project.document.units
        guard let resolved = resolvePost(project: project, override: options.post, profiles: profiles, machines: machines) else {
            output.standardError("error: unknown post \"\(options.post ?? "")\"; installed: \(profiles.map(\.id).joined(separator: ", "))\n")
            return 2
        }
        let profile = resolved.profile
        let issues = resolved.issues
        // The rapid rate only times the toolpaths; the project's own post sets it, as in the app.
        let own = resolved.own
        let rapid = own.rapidRate * own.units.factor(to: units)

        // The scope: one toolpath by name, or the whole program.
        var scope = GCodeExportScope.all
        var operationName: String?
        if let wanted = options.operation {
            let exact = project.operations.filter { $0.setup.name == wanted }
            let found = exact.isEmpty ? project.operations.filter { $0.setup.name.caseInsensitiveCompare(wanted) == .orderedSame } : exact
            guard found.count == 1, let op = found.first else {
                let names = project.operations.map { "\"\($0.setup.name)\"" }.joined(separator: ", ")
                output.standardError(found.isEmpty
                                     ? "error: no toolpath named \"\(wanted)\"; the project has: \(names)\n"
                                     : "error: \(found.count) toolpaths are named \"\(wanted)\"; rename one of them\n")
                return 2
            }
            scope = .operation(op.id)
            operationName = op.setup.name
        }
        let outputProject = project.exportProject(for: scope, side: options.side)
        let targets: [AnyOperation]
        switch scope {
        case .all: targets = outputProject.operations.filter(\.setup.isEnabled)
        case .operation: targets = outputProject.operations
        }

        // Calculate what is exported, against the project as a whole (each toolpath uses its own sheet and side). The tools
        // are the ones the project was saved with (its snapshot, which holds any edit to a seeded tool), over the seeded
        // defaults for any it does not mention: never the library of the Mac it runs on.
        var library = ToolLibrary.seeded
        for tool in project.tools { library.upsert(tool) }
        var results: [UUID: ToolpathResult] = [:]
        // With touch-plate tool changes every operation of the posted sheet is calculated: the spot is checked against all.
        let calculate = GCodeExporter.calculationTargets(project: project, exported: targets.map(\.id), scope: scope, profile: profile)
            .compactMap { id in project.operations.first { $0.id == id } }
        for op in calculate {
            results[op.id] = ToolpathCalculator.calculate(op, project: project, library: library, designRevision: 0,
                                                          rapidRate: rapid)
        }
        let tps = GCodeExporter.toolpaths(scope: scope, operations: outputProject.operations, results: results,
                                          groupByTool: options.groupByTool)
        let jobName = options.name ?? project.document.name
        let sheet = GCodeExporter.sheetToolpathsIfProbing(project: project, results: results, scope: scope, profile: profile)
        var result = GCodeExporter.export(project: outputProject, toolpaths: tps, profile: profile, jobName: jobName,
                                          sheetToolpaths: sheet)
        // A toolpath asked for by name is judged even when it is switched off, as the one that is missing from this program.
        let asked = targets.map { op -> AnyOperation in
            var setup = op.editableSetup
            setup.isEnabled = true
            return op.with(setup: setup)
        }
        let missing = GCodeExporter.missingOperationIssues(asked, results: results)
        result.issues.insert(contentsOf: issues + missing, at: 0)

        for issue in result.issues {
            output.standardError("\(issue.severity.rawValue): \(issue.line.map { "line \($0): " } ?? "")\(issue.message)\n")
        }
        guard let text = result.text else {
            output.standardError("error: \(result.errorMessage ?? "nothing to export")\n")
            return 1
        }
        let status: Int32 = result.hasErrors ? 1 : 0
        // A toolpath that did not calculate is a step missing from the program: `--force` is for the validator's errors and
        // never writes a program that is short of one.
        if !missing.isEmpty {
            output.standardError("error: \(missing.count) toolpath\(missing.count == 1 ? "" : "s") missing from the program: nothing written\n")
            return 1
        }
        if result.hasErrors, !options.force {
            let n = result.issues.filter { $0.severity == .error }.count
            output.standardError("error: \(n) validator error\(n == 1 ? "" : "s"): nothing written (--force writes it anyway)\n")
            return status
        }

        // Where it goes.
        if options.out == "-" {
            output.standardOutput(text)
            return status
        }
        let base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let fileName = GCodeExporter.suggestedFileName(jobName: base, operationName: operationName, profile: profile)
        let folder = URL(fileURLWithPath: options.out ?? ".", isDirectory: true)
        let file = folder.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file, options: .atomic)
        } catch {
            output.standardError("error: cannot write \(file.path): \(error.localizedDescription)\n")
            return 2
        }
        if !options.quiet { output.standardOutput("wrote \(file.path)\n") }
        return status
    }
}
