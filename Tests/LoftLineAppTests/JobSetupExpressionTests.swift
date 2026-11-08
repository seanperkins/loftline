import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// Expressions typed into Job Setup evaluate against the form's pending values, and the link
/// they leave behind is re-evaluated against the committed job on Apply (issue #25).
@Suite @MainActor struct JobSetupExpressionTests {
    /// What a Job Setup field does on commit: parse with the form's variables, note the expression, write.
    static func type(_ text: String, into form: JobSetupForm, document: LoftLineDocument, current: Double) throws -> Double {
        let style = ExpressionNumberStyle(variables: form.variableTable(in: document.document), units: form.units,
                                          recorder: document.expressionRecorder,
                                          target: .job(sheetID: document.document.currentSheetID))
        let v = try style.parseStrategy.parse(text)
        return document.expressionRecorder.valueToWrite(v, current: current)
    }

    @Test func expressionsSeeTheDraftThicknessAndStayRightAfterApply() throws {
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        #expect(doc.document.job.thickness == 0.75)
        var form = JobSetupForm(project: doc.project, machines: MachineCatalog.shared.machines)
        form.job.thickness = 0.5
        // Before Apply the saved thickness is still 0.75; the form's table says 0.5.
        #expect(form.variableTable(in: doc.document)["thickness"] == 0.5)
        #expect(doc.document.variableTable["thickness"] == 0.75)
        form.job.safeZ = try Self.type("=thickness/2", into: form, document: doc, current: form.job.safeZ)
        #expect(form.job.safeZ == 0.25)
        doc.applyJobSetup(form)
        // Applied: the value stands, and it is linked to the committed job.
        #expect(doc.document.job.thickness == 0.5 && doc.document.job.safeZ == 0.25)
        #expect(doc.document.linkedValues.map(\.expression) == ["=thickness/2"])
        #expect(doc.document.linkedValues.first?.path == ["safeZ"])
        // The link follows the material from now on.
        doc.perform("Thicker") { $0.document.job.thickness = 1.0 }
        #expect(doc.document.job.safeZ == 0.5)
    }

    @Test func userVariablesAndSwitchedUnitsReachTheFormInTheFormsUnits() throws {
        var p = AppTestSupport.project()
        p.document.userVariables = [DocumentVariable(name: "margin", value: 0.1)]
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        var form = JobSetupForm(project: doc.project, machines: MachineCatalog.shared.machines)
        #expect(form.variableTable(in: doc.document)["margin"] == 0.1)
        // Switching the form to millimetres scales the draft job; a user variable is a plain number
        // (a count or a ratio as often as a length) and keeps its value.
        form.setUnits(.millimeter)
        let table = form.variableTable(in: doc.document)
        #expect(abs((table["width"] ?? 0) - 24 * 25.4) < 1e-9 && table["margin"] == 0.1)
        form.job.height = try Self.type("=width/2 + margin", into: form, document: doc, current: form.job.height)
        #expect(abs(form.job.height - (12 * 25.4 + 0.1)) < 1e-9)
        // A suffix converts into the form's units, not the saved document's.
        #expect(abs(try Self.type("1/4in", into: form, document: doc, current: 0) - 6.35) < 1e-9)
        // Applying converts the project and still links the expression, typed in the new units.
        doc.applyJobSetup(form)
        #expect(doc.units == .millimeter && abs(doc.document.job.height - (12 * 25.4 + 0.1)) < 1e-9)
        #expect(doc.document.userVariables.map(\.value) == [0.1])
        #expect(doc.document.linkedValues.map { ($0.expression, $0.path) }.contains { $0 == "=width/2 + margin" && $1 == ["height"] })
        doc.perform("Wider") { $0.document.job.width = 400 }
        #expect(abs(doc.document.job.height - 200.1) < 1e-9)
    }

    @Test func anExpressionTypedBeforeTheUnitsAreSwitchedStillLinks() throws {
        // Type =width/2 (12 in) into Height, then switch the form to millimetres (the draft height
        // becomes 304.8), then Apply: the noted value is matched in millimetres and the link is made.
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        var form = JobSetupForm(project: doc.project, machines: MachineCatalog.shared.machines)
        form.job.height = try Self.type("=width/2", into: form, document: doc, current: form.job.height)
        #expect(form.job.height == 12)
        form.setUnits(.millimeter)
        #expect(abs(form.job.height - 304.8) < 1e-9)
        doc.applyJobSetup(form)
        #expect(doc.document.linkedValues.map { ($0.path, $0.expression) }.contains { $0 == ["height"] && $1 == "=width/2" })
        doc.perform("Wider") { $0.document.job.width = 400 }
        #expect(doc.document.job.height == 200)
    }

    @Test func retypingAnEqualExpressionAfterAUnitChangeStillLinks() throws {
        // Safe Z is already thickness/2. Switch the form to millimetres and retype =thickness/2:
        // the field writes one ulp above the equal value, and that must still read as a change
        // after the conversion, so the link is made (a unit change drops the old links, and this
        // is how a user restores one).
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        doc.perform("Half") { $0.document.job.safeZ = $0.document.job.thickness / 2 }
        var form = JobSetupForm(project: doc.project, machines: MachineCatalog.shared.machines)
        form.setUnits(.millimeter)
        form.job.safeZ = try Self.type("=thickness/2", into: form, document: doc, current: form.job.safeZ)
        doc.applyJobSetup(form)
        #expect(abs(doc.document.job.safeZ - 9.525) < 1e-9)
        #expect(doc.document.linkedValues.map { ($0.path, $0.expression) }.contains { $0 == ["safeZ"] && $1 == "=thickness/2" })
        doc.perform("Thicker") { $0.document.job.thickness = 25.4 }
        #expect(abs(doc.document.job.safeZ - 12.7) < 1e-9)
    }

    @Test func aLiteralTypedBeforeTheUnitsAreSwitchedIsNotLinked() throws {
        // "=width/2 - 1" typed in inches (11) then the form switched to millimetres: the sheet shows
        // 279.4 mm, and re-evaluating the text in millimetres would give 303.8. The converted value
        // is what Apply commits, with no link.
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        var form = JobSetupForm(project: doc.project, machines: MachineCatalog.shared.machines)
        form.job.height = try Self.type("=width/2 - 1", into: form, document: doc, current: form.job.height)
        #expect(form.job.height == 11)
        form.setUnits(.millimeter)
        doc.applyJobSetup(form)
        #expect(abs(doc.document.job.height - 279.4) < 1e-9 && doc.document.linkedValues.isEmpty)
    }

    @Test func aUnitRoundTripBeforeApplyKeepsTheLinks() throws {
        // Safe Z linked to the thickness; Job Setup opened, units toggled to millimetres and back,
        // Apply: untouched fields are converted from the saved values in one step, so they are not
        // hand edits and the link survives.
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        var first = JobSetupForm(project: doc.project, machines: MachineCatalog.shared.machines)
        first.job.safeZ = try Self.type("=thickness/2", into: first, document: doc, current: first.job.safeZ)
        doc.applyJobSetup(first)
        #expect(doc.document.linkedValues.count == 1)
        var toggled = JobSetupForm(project: doc.project, machines: MachineCatalog.shared.machines)
        toggled.setUnits(.millimeter); toggled.setUnits(.inch)
        doc.applyJobSetup(toggled)
        #expect(doc.document.linkedValues.count == 1)
        doc.perform("Thicker") { $0.document.job.thickness = 1.0 }
        #expect(doc.document.job.safeZ == 0.5)
    }

    @Test func unitTogglesInTheFormDoNotMakeUntouchedFieldsLookEdited() throws {
        // Width 4.2 in and height 2.1 in. Toggle the form millimetres, inches, millimetres and type
        // =width/2 into Safe Z: the untouched height, which equals that value, is not linked,
        // because it still reads exactly as a single conversion of the saved height.
        var p = AppTestSupport.project()
        p.document.job.width = 4.2; p.document.job.height = 2.1
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        var form = JobSetupForm(project: doc.project, machines: MachineCatalog.shared.machines)
        form.setUnits(.millimeter); form.setUnits(.inch); form.setUnits(.millimeter)
        #expect(form.job.height == 2.1 * 25.4 && form.job.width == 4.2 * 25.4)
        form.job.safeZ = try Self.type("=width/2", into: form, document: doc, current: form.job.safeZ)
        doc.applyJobSetup(form)
        #expect(doc.document.linkedValues.map(\.path) == [["safeZ"]])
        // Toggled back to inches before Apply, the untouched fields are the saved ones to the bit.
        var saved = AppTestSupport.project()
        saved.document.job.home = Vec2(2.1, 3.3); saved.document.job.homeZ = 1.3; saved.document.job.safeZ = 0.9
        saved.document.job.plungeGap = 0.7; saved.document.job.datumOffset = Vec2(1.1, 2.7); saved.document.gridSpacing = 0.7
        var back = JobSetupForm(project: saved, machines: MachineCatalog.shared.machines)
        for u in [LengthUnit.millimeter, .inch, .millimeter, .inch] { back.setUnits(u) }
        #expect(back.job == saved.document.job && back.gridSpacing == saved.document.gridSpacing)
    }

    @Test func anUnknownNameCannotHideASelfReference() throws {
        // "=zzz + thickness/2" in Thickness fails on zzz first; the guard still sees the thickness.
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        #expect(VariableLink.references("thickness", in: "=zzz + thickness/2", variables: doc.document.variableTable, units: .inch))
        #expect(VariableLink.references("thickness", in: "=1/zzz + thickness/2", variables: doc.document.variableTable, units: .inch))
        #expect(!VariableLink.references("width", in: "=zzz + thickness/2", variables: doc.document.variableTable, units: .inch))
        let thickness = doc.document.job.thickness
        doc.perform("Stale") {
            $0.document.linkedValues = [VariableLink(target: .job(sheetID: $0.document.currentSheetID), path: ["thickness"], expression: "=zzz + thickness/2")]
        }
        #expect(doc.document.linkedValues.isEmpty)
        doc.perform("Define") { $0.document.userVariables = [DocumentVariable(name: "zzz", value: 0)] }
        #expect(doc.document.linkedValues.isEmpty && doc.document.job.thickness == thickness)
    }

    @Test func anUnknownNameFilledInDoesNotZeroADenominator() throws {
        // The names the table lacks are filled in as the evaluation meets them; a denominator built from
        // them ("zzz-1", "zzz-yyy") must not come out as zero and end the search before the thickness.
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        let table = doc.document.variableTable
        for text in ["=1/(zzz-1) + thickness/2", "=1/(zzz-yyy) + thickness/2", "=1/(zzz-2*yyy) + thickness/2", "=thickness/(zzz-yyy)"] {
            #expect(VariableLink.references("thickness", in: text, variables: table, units: .inch), "\(text)")
            #expect(!VariableLink.references("width", in: text, variables: table, units: .inch), "\(text)")
        }
        // A zero that no filled name made stays "not a reference": the link can never evaluate.
        #expect(!VariableLink.references("thickness", in: "=1/0 + thickness/2", variables: table, units: .inch))
        doc.perform("Stale") {
            $0.document.linkedValues = [VariableLink(target: .job(sheetID: $0.document.currentSheetID), path: ["thickness"], expression: "=1/(zzz-1) + thickness/2")]
        }
        #expect(doc.document.linkedValues.isEmpty)
    }

    @Test func aUnitChangeLinksOnlyTheTypedField() throws {
        // A profile cut 0.375 in deep by hand, and a pocket whose depth is linked to the thickness
        // with an inch literal, which cannot mean the same in millimetres.
        var p = AppTestSupport.project()
        let profile = OperationFactory.make(kind: .profile, project: p, library: .seeded, shapeIDs: [p.document.shapes[0].id])!
        let pocket = OperationFactory.make(kind: .pocket, project: p, library: .seeded, shapeIDs: [p.document.shapes[1].id])!
        p.operations = [profile, pocket]
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        func depth(_ id: UUID) -> Double {
            switch doc.operation(id) {
            case .profile(let o)?: return o.params.depth.cutDepth
            case .pocket(let o)?: return o.params.depth.cutDepth
            default: return .nan
            }
        }
        guard case .profile(var pr) = doc.operation(profile.id) else { throw TestError.notAProfile }
        pr.params.depth.cutDepth = 0.375
        doc.updateOperation(.profile(pr))
        guard case .pocket(var po) = doc.operation(pocket.id) else { throw TestError.notAProfile }
        let style = ExpressionNumberStyle(variables: doc.document.variableTable, units: .inch, recorder: doc.expressionRecorder,
                                          target: .operation(pocket.id))
        po.params.depth.cutDepth = doc.expressionRecorder.valueToWrite(try style.parseStrategy.parse("=thickness - 0.1"), current: po.params.depth.cutDepth)
        doc.updateOperation(.pocket(po))
        #expect(doc.document.linkedValues.count == 1 && abs(depth(pocket.id) - 0.65) < 1e-12)
        // Switch to millimetres and type =thickness/2 (9.525 mm) into Safe Z: the profile's 0.375 in,
        // now 9.525 mm too, is not linked by the coincidence; the pocket's old link is dropped, as
        // every link is by a unit change, and its converted value stands.
        var form = JobSetupForm(project: doc.project, machines: MachineCatalog.shared.machines)
        form.setUnits(.millimeter)
        form.job.safeZ = try Self.type("=thickness/2", into: form, document: doc, current: form.job.safeZ)
        doc.applyJobSetup(form)
        let links = doc.document.linkedValues.map { ($0.path, $0.expression) }
        #expect(links.count == 1 && links[0] == (["safeZ"], "=thickness/2"))
        #expect(abs(depth(profile.id) - 9.525) < 1e-9 && abs(depth(pocket.id) - 16.51) < 1e-9)
        doc.perform("Thicker") { $0.document.job.thickness = 25.4 }
        #expect(abs(depth(profile.id) - 9.525) < 1e-9 && abs(depth(pocket.id) - 16.51) < 1e-9)
        #expect(abs(doc.document.job.safeZ - 12.7) < 1e-9)
    }

    @Test func aCancelledSheetDropsItsTypedExpressions() throws {
        var p = AppTestSupport.project()
        let op = OperationFactory.make(kind: .profile, project: p, library: .seeded, shapeIDs: [p.document.shapes[0].id])!
        p.operations = [op]
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        var form = JobSetupForm(project: doc.project, machines: MachineCatalog.shared.machines)
        form.job.safeZ = try Self.type("=thickness/2", into: form, document: doc, current: form.job.safeZ)
        #expect(doc.expressionRecorder.pending.count == 1)
        // Cancel: the sheet closes without applying, and the expression is forgotten.
        doc.sheetDismissed()
        #expect(doc.expressionRecorder.pending.isEmpty)
        // A later edit that happens to take the same value is not linked to it.
        guard case .profile(var profile) = doc.operation(op.id) else { throw TestError.notAProfile }
        profile.params.depth.cutDepth = 0.375
        doc.updateOperation(.profile(profile))
        #expect(doc.document.linkedValues.isEmpty)
    }

    @Test func aFieldIsNeverLinkedToAnExpressionOfItself() throws {
        // `=thickness/2` typed into Thickness halves it once; linking it would halve it again on
        // every later edit. The value is kept and no link is made.
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        var form = JobSetupForm(project: doc.project, machines: MachineCatalog.shared.machines)
        form.job.thickness = try Self.type("=thickness/2", into: form, document: doc, current: form.job.thickness)
        #expect(form.job.thickness == 0.375)
        doc.applyJobSetup(form)
        #expect(doc.document.job.thickness == 0.375 && doc.document.linkedValues.isEmpty)
        doc.perform("Unrelated") { $0.document.job.width = 30 }
        #expect(doc.document.job.thickness == 0.375)
        // Two fields that feed each other are a cycle too: the second link is refused, so the
        // first stands and nothing moves on later edits. (Thickness is 0.375 here; "=safez*2"
        // gives the same 0.375, which the field nudges by an ulp so the change can be seen.)
        var cyclic = JobSetupForm(project: doc.project, machines: MachineCatalog.shared.machines)
        cyclic.job.safeZ = try Self.type("=thickness/2", into: cyclic, document: doc, current: cyclic.job.safeZ)
        cyclic.job.thickness = try Self.type("=safez*2", into: cyclic, document: doc, current: cyclic.job.thickness)
        doc.applyJobSetup(cyclic)
        #expect(doc.document.linkedValues.map(\.path) == [["safeZ"]])
        #expect(abs(doc.document.job.thickness - 0.375) < 1e-12 && abs(doc.document.job.safeZ - 0.1875) < 1e-12)
        let before = (doc.document.job.thickness, doc.document.job.safeZ)
        doc.perform("Unrelated") { $0.document.job.width = 31 }
        #expect((doc.document.job.thickness, doc.document.job.safeZ) == before)
        // The same cycle entered on a later Apply is refused as well.
        var later = JobSetupForm(project: doc.project, machines: MachineCatalog.shared.machines)
        later.job.thickness = try Self.type("=safez*2", into: later, document: doc, current: later.job.thickness)
        doc.applyJobSetup(later)
        #expect(doc.document.linkedValues.map(\.path) == [["safeZ"]])
        doc.perform("Unrelated") { $0.document.job.width = 32 }
        // The refused field keeps the ulp the equal-value nudge wrote; nothing else moved.
        #expect(abs(doc.document.job.thickness - before.0) < 1e-12 && abs(doc.document.job.safeZ - before.1) < 1e-12)
        // An expression typed before a field it uses was changed in the same form no longer gives
        // the value the sheet shows, so it is not linked either: Apply commits what was shown.
        var stale = JobSetupForm(project: doc.project, machines: MachineCatalog.shared.machines)
        stale.job.safeZ = try Self.type("=thickness/3", into: stale, document: doc, current: stale.job.safeZ)
        stale.job.thickness = 0.6
        doc.applyJobSetup(stale)
        #expect(abs(doc.document.job.safeZ - 0.125) < 1e-12 && doc.document.linkedValues.isEmpty)
        // Also an existing self-link from an older file: dropped, and the value no longer moves.
        doc.perform("Stale link") {
            $0.document.linkedValues = [VariableLink(target: .job(sheetID: $0.document.currentSheetID), path: ["safeZ"], expression: "=safez*2")]
        }
        #expect(doc.document.linkedValues.isEmpty)
        #expect(VariableLink.references("safez", in: "=safeZ*2", variables: doc.document.variableTable, units: .inch))
        #expect(!VariableLink.references("safez", in: "=thickness/2", variables: doc.document.variableTable, units: .inch))
    }

    enum TestError: Error { case notAProfile }
}
