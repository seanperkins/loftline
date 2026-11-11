// The core's JSON, as it is written in a .loftline file. The Swift types are the definition; these name only what the UI reads.
export interface Vec2 { x: number; y: number }
export type Segment =
  | { line: { to: Vec2 } }
  | { cubic: { to: Vec2; control1: Vec2; control2: Vec2 } }
  | { arc: { to: Vec2; center: Vec2; clockwise: boolean } };
export interface Path { start: Vec2; segments: Segment[]; isClosed: boolean }
export interface Shape { id: string; name: string; layerID: string; paths: Path[]; isLocked?: boolean; groupID?: string; text?: TextSpec; origin?: unknown }
export interface TextSpec { string: string; fontName: string; size: number; alignment: string; lineSpacing: number; letterSpacing: number; transform: unknown }
export interface Layer { id: string; name: string; colorHex: string; isVisible: boolean; isLocked: boolean; side?: string }
export interface Job {
  width: number; height: number; thickness: number; xyOrigin: string; zZero: string; safeZ: number; homeZ: number; home: Vec2; [key: string]: unknown;
}
export interface DocumentModel { name: string; units: "inch" | "millimeter"; gridSpacing: number; job: Job; layers: Layer[]; shapes: Shape[]; models: unknown[] }
export interface Setup { id: string; name: string; isEnabled: boolean; toolID: string; shapeIDs: string[]; [key: string]: unknown }
export type Params = Record<string, unknown>;
export type Operation = Record<string, { _0: { setup: Setup; params: Params } }>;
export interface Tool {
  id: string; number: number; name: string; kind: string; units: string; diameter: number; tipDiameter?: number; angle?: number; flutes: number;
  fluteLength: number; feedRate: number; plungeRate: number; spindleRPM: number; stepdown: number; stepover: number; notes?: string; group?: string;
}
export interface Project { document: DocumentModel; operations: Operation[]; tools: Tool[]; postProfileID?: string }
export interface OperationStatus {
  id: string; isStale: boolean; isCalculated: boolean; error?: string; toolpathCount: number; moveCount: number; seconds: number; duration: string; metadata: Record<string, string>;
}
export interface Issue { severity: string; line?: number; message: string }
export interface State {
  project: Project; path?: string; title: string; isDirty: boolean; undoAction?: string; redoAction?: string; designRevision: number;
  post: { id: string; name: string; fileExtension: string }; machine?: string; side: string; coverage?: string; statuses: OperationStatus[]; issues: Issue[];
  job: { hasEstimate: boolean; totalSeconds: number; duration: string; toolLoads: number; toolChanges: number; sequence: string[] };
  changeRevision: number; assistant: AssistantStatus;
}
/** The live link as the window shows it (spec 2, "The desktop host"). */
export interface AssistantStatus { changeRevision: number; assistantRevision: number; claimed: boolean; asking: boolean; allowed: boolean; changes: number; warning?: string }
export interface PostRow { id: string; name: string; fileExtension: string; units: string }
export interface Machine { id: string; name: string; postIDs: string[]; notes?: string }
export interface JobForm { machineID?: string; machineChoices: { id: string; title: string }[]; postID?: string }
export interface Posted {
  text?: string; errorMessage?: string; issues: Issue[]; missingSteps: Issue[]; hasErrors: boolean; toolpathCount: number; fileName: string; post: string; written?: string;
}
export interface Lines { lines: { points: number[]; isRapid: boolean; operation?: string }[]; maxDepth: number }

export const opKind = (op: Operation): string => Object.keys(op)[0];
export const opBody = (op: Operation) => op[opKind(op)]._0;
export const unitLabel = (units: string) => (units === "inch" ? "in" : "mm");
export const feedLabel = (units: string) => (units === "inch" ? "in/min" : "mm/min");

export const kindTitles: Record<string, string> = {
  profile: "Profile", pocket: "Pocket", drill: "Drilling", vcarve: "V-Carve", inlay: "Inlay", fluting: "Fluting", texture: "Texture", relief3D: "3D Relief",
  photoVCarve: "PhotoVCarve", engrave: "Engrave", chamfer: "Chamfer", holeMill: "Hole Milling", prism: "Prism", merge: "Merged", straightInlay: "Straight Inlay",
  moulding: "Moulding", facing: "Facing",
};

/** Points along a path, curves and arcs flattened to `tolerance`. For drawing and picking only. */
export function flatten(path: Path, tolerance = 0.01): Vec2[] {
  const out: Vec2[] = [path.start];
  let cur = path.start;
  for (const seg of path.segments) {
    if ("line" in seg) {
      out.push(seg.line.to);
      cur = seg.line.to;
    } else if ("cubic" in seg) {
      const { to, control1: a, control2: b } = seg.cubic;
      const size = Math.hypot(a.x - cur.x, a.y - cur.y) + Math.hypot(b.x - a.x, b.y - a.y) + Math.hypot(to.x - b.x, to.y - b.y);
      const n = Math.max(2, Math.min(64, Math.ceil(Math.sqrt(size / tolerance))));
      for (let i = 1; i <= n; i++) {
        const t = i / n, u = 1 - t;
        out.push({
          x: u * u * u * cur.x + 3 * u * u * t * a.x + 3 * u * t * t * b.x + t * t * t * to.x,
          y: u * u * u * cur.y + 3 * u * u * t * a.y + 3 * u * t * t * b.y + t * t * t * to.y,
        });
      }
      cur = to;
    } else {
      const { to, center: c, clockwise } = seg.arc;
      const r = Math.hypot(cur.x - c.x, cur.y - c.y);
      const a0 = Math.atan2(cur.y - c.y, cur.x - c.x);
      let a1 = Math.atan2(to.y - c.y, to.x - c.x);
      if (clockwise && a1 >= a0) a1 -= Math.PI * 2;
      if (!clockwise && a1 <= a0) a1 += Math.PI * 2;
      const step = r > tolerance ? 2 * Math.acos(1 - Math.min(1, tolerance / r)) : Math.PI / 4;
      const n = Math.max(2, Math.min(180, Math.ceil(Math.abs(a1 - a0) / Math.max(step, 0.01))));
      for (let i = 1; i <= n; i++) {
        const a = a0 + ((a1 - a0) * i) / n;
        out.push({ x: c.x + r * Math.cos(a), y: c.y + r * Math.sin(a) });
      }
      cur = to;
    }
  }
  if (path.isClosed) out.push(path.start);
  return out;
}

export function shapeBounds(shape: Shape) {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const p of shape.paths) {
    for (const q of flatten(p)) {
      minX = Math.min(minX, q.x); minY = Math.min(minY, q.y); maxX = Math.max(maxX, q.x); maxY = Math.max(maxY, q.y);
    }
  }
  return { minX, minY, maxX, maxY };
}
