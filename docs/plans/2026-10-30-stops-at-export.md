# Stops at export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task.

**Goal:** Refuse at export a post whose pause or tool change never stops. **Spec:** `docs/specs/2026-10-30-stops-at-export-design.md`

### Task 1: `sampleStopProblem`, stricter markers, block delete, the export refusal
- [ ] Tests (spec table) in `PostDraftReportTests` (`aPauseThatNeverStopsIsASampleStopProblem`, `aToolChangeThatNeverStopsIsASampleStopProblem`,
  `literalStopsAreNotAProblem`, `forgedMarkersInThePreludeDoNotHideMissingStops`, `aBlockDeleteStopIsNoStop`, `aPostNamedLikeAMarkerIsNotRefused`,
  `aPostTheBuilderRefusesHasNoSampleStopProblem`, `aTouchPlateMachineStillNeedsAToolChangeThatStops`) and `PreflightChecksTests`
  (`aPostWhosePauseNeverStopsIsRefusedAtExport`, `aPostTheBuilderRefusesKeepsTheBuildersMessage`); watch them fail to compile.
- [ ] `PostDraftReport.plainSample`, `sampleStopProblem`; `stopProblems` markers by comment prefix, exactly once; no credit on block-delete lines;
  `GCodeExporter.export` throws `invalidPost` before posting. Run `scripts/test.sh --filter "PostDraftReportTests|PreflightChecksTests"`: PASS.
- [ ] Help paragraph, DECISIONS `stops-at-export`; full `scripts/build.sh` and `scripts/test.sh`.
