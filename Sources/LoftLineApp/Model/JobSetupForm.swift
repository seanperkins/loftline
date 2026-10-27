import CADCore
import CAMCore
import Foundation
import PostCore

/// Editable copy of the Job Setup sheet. Switching units converts the values in the form;
/// applying converts the whole project when the units differ.
struct JobSetupForm: Equatable {
    var units: LengthUnit
    var job: JobSetup
    var gridSpacing: Double
    var name: String
    /// Name of the current material sheet (multi-sheet jobs).
    var sheetName: String
    var isMultiSheet: Bool
    /// The machine and post processor the job is cut with. nil means "leave the project's as they are"
    /// (a form made from a document alone, or a project whose post matches no known machine).
    var machineID: String?
    var postID: String?
    /// The machine the form is on: the project's own copy while it is valid (even when that machine is not installed
    /// here), else the installed one, else nil. The bed-fit check and the post grouping read this, not the catalog.
    var machine: MachineDefinition?
    /// The job and grid as the document had them, in its units. A field the user has not touched
    /// is always converted from here in one step, so switching units back and forth leaves it
    /// exactly what a single conversion gives, which is what the saved project's own conversion
    /// gives too; the link reconciliation can then tell a touched field from an untouched one
    /// to the bit.
    private var base: Base
    private struct Base: Equatable { var units: LengthUnit; var job: JobSetup; var gridSpacing: Double }

    init(document: Document) {
        units = document.units; job = document.job; gridSpacing = document.gridSpacing; name = document.name
        sheetName = document.currentSheetName; isMultiSheet = document.isMultiSheet
        base = Base(units: document.units, job: document.job, gridSpacing: document.gridSpacing)
    }

    init(project: LoftLineProject, machines: [MachineDefinition], profiles: [PostProfile] = PostProfileCatalog.shared.profiles) {
        self.init(document: project.document)
        // The project's own machine first, so a machine that is in the file but not installed here is not swapped for
        // a different installed one (Apply would write that swap).
        machine = ProjectPost.resolve(project, profiles: profiles, machines: machines).machine
        machineID = machine?.id
        postID = project.postProfileID ?? PostProfileStore.defaultID(for: project.document.units)
    }

    /// Why the material does not fit the machine's bed (empty = fits).
    var fitProblems: [String] { MachineResolver.fitProblems(job: job, units: units, machine: machine) }

    /// The machine picker's entries: the installed machines, and the project's own copy of one that is not installed
    /// here, so the selection still shows.
    func machineChoices(installed: [MachineDefinition]) -> [(id: String, title: String)] {
        var out = installed.map { (id: $0.id, title: $0.name) }
        if let m = machine, !installed.contains(where: { $0.id == m.id }) { out.append((m.id, "\(m.name) (not installed here)")) }
        return out
    }

    /// Chooses `machine`, switching to one of its posts if the current post does not drive it.
    mutating func selectMachine(_ machine: MachineDefinition, profiles: [PostProfile]) {
        machineID = machine.id
        self.machine = machine
        let current = postID ?? PostProfileStore.defaultID(for: units)
        postID = MachineResolver.post(afterSelecting: machine, current: current, units: units, profiles: profiles)
    }

    mutating func setUnits(_ new: LengthUnit) {
        guard new != units else { return }
        let f = units.factor(to: new)
        let wasUntouched = base.job.scaled(by: base.units.factor(to: units))
        let untouched = base.job.scaled(by: base.units.factor(to: new))
        var scaled = job.scaled(by: f)
        for k in Self.lengths where job[keyPath: k] == wasUntouched[keyPath: k] { scaled[keyPath: k] = untouched[keyPath: k] }
        if let g = job.plungeGap, g == wasUntouched.plungeGap { scaled.plungeGap = untouched.plungeGap }
        if let d = job.datumOffset, d == wasUntouched.datumOffset { scaled.datumOffset = untouched.datumOffset }
        job = scaled
        gridSpacing = gridSpacing == base.gridSpacing * base.units.factor(to: units)
            ? base.gridSpacing * base.units.factor(to: new) : gridSpacing * f
        units = new
    }

    /// The job's plain length fields (the optionals are handled beside them).
    private static let lengths: [WritableKeyPath<JobSetup, Double>] = [\.width, \.height, \.thickness, \.safeZ, \.homeZ, \.home.x, \.home.y]

    /// The names an expression typed into this form can use: the material as the form shows it
    /// (the draft job, in the form's units) with `document`'s user variables, which are plain
    /// numbers and do not convert, so `=thickness/2` sees the thickness on screen rather than the
    /// saved one. Applying links the expression to the committed job and evaluates it there.
    func variableTable(in document: Document) -> [String: Double] {
        var d = document
        d.job = job
        return d.variableTable
    }

    /// Problems that block applying (empty = valid).
    var problems: [String] {
        var p: [String] = []
        if job.width <= 0 || job.height <= 0 { p.append("Material width and height must be positive.") }
        if job.thickness <= 0 { p.append("Material thickness must be positive.") }
        if job.safeZ <= 0 { p.append("Safe Z must be above the material.") }
        if job.homeZ < job.safeZ { p.append("Home Z should be at or above Safe Z.") }
        if let g = job.plungeGap, g < 0 || g > job.safeZ { p.append("Plunge Z must be between the material top and Safe Z.") }
        if gridSpacing <= 0 { p.append("Grid spacing must be positive.") }
        return p
    }

    func apply(to project: LoftLineProject) -> LoftLineProject {
        var p = project.converted(to: units)
        // Job Setup edits the current sheet's stock; the other sheets keep theirs, and so do
        // the operations that cut them.
        let oldThickness = p.document.job.thickness
        let sheet = p.document.currentSheetID
        let onThisSheet = Set(p.operations.filter { p.sheetID(of: $0) == sheet }.map(\.id))
        p.document.job = job
        p.operations = DepthFollow.adjusted(p.operations, thicknessFrom: oldThickness, to: job.thickness) { onThisSheet.contains($0.id) }
        p.document.gridSpacing = gridSpacing
        p.document.name = name
        if isMultiSheet, !sheetName.isEmpty { p.document.activeSheetName = sheetName }
        if let machineID { p.machineID = machineID }
        if let postID { p.postProfileID = postID }
        p.ensureBottomLayer()
        return p
    }
}
