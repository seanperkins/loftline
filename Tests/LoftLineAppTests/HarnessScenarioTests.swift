import Foundation
import Testing
@testable import LoftLineApp

#if DEBUG
@Suite struct HarnessScenarioTests {
    private func parse(_ json: String) throws -> HarnessScenario { try HarnessScenario.parse(Data(json.utf8)) }

    @Test func aFullScenarioParses() throws {
        let s = try parse("""
        {"name": "profile", "appearance": "light", "window": [1280, 820],
         "steps": [
           {"op": "sample", "name": "sign"},
           {"op": "tab", "value": "toolpaths"},
           {"op": "selectToolpath", "name": "Profile 1"},
           {"op": "capture", "name": "profile"}
         ]}
        """)
        #expect(s.name == "profile" && s.appearance == "light" && s.window == [1280, 820])
        #expect(s.steps.map(\.op) == ["sample", "tab", "selectToolpath", "capture"])
    }

    @Test func aLongRecordingCanRaiseTheWatchdog() throws {
        #expect(try parse(#"{"steps": []}"#).watchdogSeconds == 180)
        #expect(try parse(#"{"timeout": 600, "steps": []}"#).watchdogSeconds == 600)
        #expect(throws: HarnessError.self) { try parse(#"{"timeout": 0, "steps": []}"#) }
        #expect(throws: HarnessError.self) { try parse(#"{"timeout": 3601, "steps": []}"#) }
    }

    @Test func anUnknownOpNamesTheValidOnes() {
        #expect(throws: HarnessError.self) { try parse(#"{"steps": [{"op": "teleport"}]}"#) }
        do { _ = try parse(#"{"steps": [{"op": "teleport"}]}"#) } catch let e as HarnessError {
            #expect(e.message.contains("teleport") && e.message.contains("capture"))
        } catch {}
    }

    @Test func stepsMustCarryTheirArguments() {
        #expect(throws: HarnessError.self) { try parse(#"{"steps": [{"op": "capture"}]}"#) }
        #expect(throws: HarnessError.self) { try parse(#"{"steps": [{"op": "size", "size": [800]}]}"#) }
        #expect(throws: HarnessError.self) { try parse(#"{"steps": [{"op": "wait"}]}"#) }
        #expect(throws: HarnessError.self) { try parse(#"{"steps": [{"op": "select"}]}"#) }
    }

    @Test func enumeratedValuesAreChecked() {
        #expect(throws: HarnessError.self) { try parse(#"{"steps": [{"op": "mode", "value": "4d"}]}"#) }
        #expect(throws: HarnessError.self) { try parse(#"{"steps": [{"op": "tab", "value": "layers"}]}"#) }
        #expect(throws: HarnessError.self) { try parse(#"{"steps": [{"op": "sheet", "value": "nope"}]}"#) }
        #expect(throws: HarnessError.self) { try parse(#"{"appearance": "sepia", "steps": []}"#) }
        #expect((try? parse(#"{"steps": [{"op": "mode", "value": "split"}, {"op": "sheet", "value": "jobSetup"}]}"#)) != nil)
    }

    @Test func captureNamesBecomeSafeFileNames() throws {
        let s = try parse(#"{"steps": [{"op": "capture", "name": "../evil name/1"}]}"#)
        #expect(HarnessScenario.fileStem(s.steps[0].name!) == "evil-name-1")
        #expect(HarnessScenario.fileStem("Main Window") == "Main-Window")
    }

    @Test func aPressStepNeedsTheControlItPresses() throws {
        #expect(throws: HarnessError.self) { try parse(#"{"steps": [{"op": "press"}]}"#) }
        #expect(try parse(#"{"steps": [{"op": "press", "name": "Calculate", "value": "AXButton"}]}"#).steps.count == 1)
    }

    @Test func everyShippedScenarioParses() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("harness/scenarios")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(files.count >= 4)
        for file in files {
            do { _ = try HarnessScenario.parse(Data(contentsOf: file)) } catch {
                Issue.record("\(file.lastPathComponent): \(error)")
            }
        }
    }

    @Test func invalidJSONIsAReadableError() throws {
        let error = #expect(throws: HarnessError.self) { try parse("{not json") }
        #expect(try #require(error).message.isEmpty == false)
    }
}
#endif
