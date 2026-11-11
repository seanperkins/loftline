import { getCurrentWindow } from "@tauri-apps/api/window";
import { createCanvas } from "./canvas";
import { call, inShell } from "./core";
import { h, icon, icons, replace } from "./dom";
import { createInspector } from "./inspector";
import { unitLabel } from "./model";
import { createPreview } from "./preview3d";
import * as sheets from "./sheets";
import { createSidebar } from "./sidebar";
import { app, apply, applyReply, busy, doc, liveLink, refresh, setLiveLink, setState, subscribe } from "./state";
import type { AssistantStatus, State } from "./model";

interface Info { platform: string; fonts: string[]; defaultFont: string; imageExtensions: string[]; importExtensions: string[] }
let info: Info = { platform: "", fonts: [], defaultFont: "", imageExtensions: [], importExtensions: [] };

const root = document.getElementById("app")!;
const title = h("div", { class: "doc-title" });
const center = h("main", { class: "center" });
const canvas = createCanvas((at) => sheets.openText(at, info.defaultFont, info.fonts));
const preview = createPreview();
const inspector = createInspector();
const statusBar = h("div", { class: "status-bar", role: "status" });
const busyMark = h("div", { class: "busy-mark" });
let cursor = "";
root.addEventListener("loftline-cursor", (e) => {
  const p = (e as CustomEvent).detail as { x: number; y: number };
  cursor = `X ${p.x.toFixed(3)}  Y ${p.y.toFixed(3)}`;
  renderStatus();
});

// MARK: File commands

const guard = async (what: string) => !app.state?.isDirty || sheets.confirmDiscard(what);

async function newProject() { if (await guard("A new project")) { app.selection.clear(); await apply("new"); } }

async function openProject(path?: string) {
  if (!(await guard("Opening a project"))) return;
  const chosen = path ?? (await sheets.pickOpen("Open Project", ["loftline"]));
  if (!chosen) return;
  app.selection.clear(); app.selectedOp = null;
  await apply("open", { path: chosen });
}

async function save(as = false) {
  const current = app.state?.path;
  const path = !as && current ? current : await sheets.pickSave("Save Project", `${app.state?.title ?? "Untitled"}.loftline`, "loftline");
  if (path) await apply("save", { path: path.toLowerCase().endsWith(".loftline") ? path : `${path}.loftline` });
}

async function importFile() {
  const path = await sheets.pickOpen("Import", info.importExtensions);
  if (!path) return;
  try {
    const imported = await applyReply<{ state: State; warnings: string[] }>("import", { path });
    if (!imported) return;
    setState(imported.state);
    if (imported.warnings.length) sheets.openAlert("Import", imported.warnings.join("\n"));
    document.querySelector(".canvas-host")?.dispatchEvent(new Event("loftline-fit"));
  } catch (e) { sheets.openAlert("Import", e instanceof Error ? e.message : String(e)); }
}

async function exportVectors() {
  const path = await sheets.pickSave("Export Vectors", `${app.state?.title ?? "Untitled"}.svg`, "svg");
  if (!path) return;
  try { await call("exportVectors", { path, ids: app.selection.size ? [...app.selection] : undefined }); } catch (e) { sheets.openAlert("Export", e instanceof Error ? e.message : String(e)); }
}

async function command(name: string, extra: Record<string, unknown> = {}) {
  try {
    const done = await applyReply<{ state: State; selection?: string[]; note?: string }>("command", { name, ids: [...app.selection], ...extra });
    if (!done) return;
    if (done.selection) app.selection = new Set(done.selection);
    setState(done.state);
    if (done.note) sheets.openAlert("LoftLine", done.note);
  } catch (e) { sheets.openAlert("LoftLine", e instanceof Error ? e.message : String(e)); }
}

const u = () => unitLabel(doc().units);
const step = () => (doc().units === "inch" ? 0.25 : 5);

async function offsetCommand() {
  const r = await sheets.askNumbers("Offset", [{ key: "d", label: "Distance", value: step(), unit: u() }], { label: "Sharp corners", value: false });
  if (r) await command("offset", { number: r.values.d, flag: r.flag });
}
async function joinCommand() {
  const r = await sheets.askNumbers("Join Open Vectors", [{ key: "t", label: "Tolerance", value: doc().units === "inch" ? 0.001 : 0.025, unit: u() }]);
  if (r) await command("join", { number: r.values.t });
}
async function rectArray() {
  const r = await sheets.askNumbers("Rectangular Array", [
    { key: "rows", label: "Rows", value: 2, integer: true }, { key: "columns", label: "Columns", value: 2, integer: true },
    { key: "x", label: "X spacing", value: step() * 4, unit: u() }, { key: "y", label: "Y spacing", value: step() * 4, unit: u() },
  ], { label: "Spacing is the gap between copies", value: false });
  if (r) await command("rectangularArray", { rows: r.values.rows, columns: r.values.columns, x: r.values.x, y: r.values.y, flag: r.flag });
}
async function circularArray() {
  const r = await sheets.askNumbers("Circular Array", [
    { key: "count", label: "Copies", value: 6, integer: true }, { key: "step", label: "Angle between", value: 60, unit: "°" },
    { key: "x", label: "Center X", value: doc().job.width / 2, unit: u() }, { key: "y", label: "Center Y", value: doc().job.height / 2, unit: u() },
  ], { label: "Rotate the copies", value: true });
  if (r) await command("circularArray", { count: r.values.count, number: r.values.step, center: { x: r.values.x, y: r.values.y }, flag: r.flag });
}
async function corners(kind: "fillet" | "chamfer") {
  const r = await sheets.askNumbers(kind === "fillet" ? "Fillet Corners" : "Chamfer Corners", [{ key: "v", label: kind === "fillet" ? "Radius" : "Distance", value: step(), unit: u() }]);
  if (r) await command(kind, { number: r.values.v });
}
async function jobSheet() {
  const path = await sheets.pickSave("Export Job Sheet", `${app.state?.title ?? "Job"}.html`, "html");
  if (!path) return;
  try { await call("jobSheet", { path }); } catch (e) { sheets.openAlert("Job Sheet", e instanceof Error ? e.message : String(e)); }
}

let clipboard: unknown[] = [];
const copy = () => { clipboard = doc().shapes.filter((s) => app.selection.has(s.id)); };
async function paste() {
  if (!clipboard.length) return;
  try {
    const done = await applyReply<{ state: State; selection: string[] }>("paste", { shapes: clipboard });
    if (!done) return;
    app.selection = new Set(done.selection);
    setState(done.state);
  } catch (e) { sheets.openAlert("Paste", e instanceof Error ? e.message : String(e)); }
}

const setCenter = (m: typeof app.center) => {
  app.center = m;
  layout();
  refresh();
  requestAnimationFrame(() => document.querySelector(".canvas-host")?.dispatchEvent(new Event("loftline-fit")));
};

// MARK: Menu bar: in the window, as is usual on Windows and Linux (the Mac app uses the system menu bar).

type Item = { label: string | (() => string); keys?: string; run: () => void; enabled?: () => boolean } | "-";
const hasSelection = () => app.selection.size > 0;
const menus: [string, Item[]][] = [
  ["File", [
    { label: "New", keys: "Ctrl+N", run: () => void newProject() },
    { label: "Open…", keys: "Ctrl+O", run: () => void openProject() }, "-",
    { label: "Save", keys: "Ctrl+S", run: () => void save() },
    { label: "Save As…", keys: "Ctrl+Shift+S", run: () => void save(true) }, "-",
    { label: "Import…", keys: "Ctrl+I", run: () => void importFile() },
    { label: "Export Vectors…", run: () => void exportVectors() },
    { label: "Export G-code…", keys: "Ctrl+E", run: () => void sheets.openExport(null) },
    { label: "Export Job Sheet…", run: () => void jobSheet() },
  ]],
  ["Edit", [
    { label: "Undo", keys: "Ctrl+Z", run: () => void apply("undo"), enabled: () => !!app.state?.undoAction },
    { label: "Redo", keys: "Ctrl+Shift+Z", run: () => void apply("redo"), enabled: () => !!app.state?.redoAction }, "-",
    { label: "Copy", keys: "Ctrl+C", run: copy, enabled: hasSelection },
    { label: "Paste", keys: "Ctrl+V", run: () => void paste(), enabled: () => clipboard.length > 0 },
    { label: "Duplicate", keys: "Ctrl+D", run: () => { copy(); void paste(); }, enabled: hasSelection },
    { label: "Delete", keys: "Del", run: () => void apply("deleteShapes", { ids: [...app.selection] }), enabled: hasSelection },
    { label: "Select All", keys: "Ctrl+A", run: () => { app.selection = new Set(doc().shapes.map((s) => s.id)); refresh(); } },
  ]],
  ["View", [
    { label: "2D", run: () => setCenter("2d") }, { label: "2D | 3D", run: () => setCenter("split") }, { label: "3D", run: () => setCenter("3d") }, "-",
    { label: "Zoom to Fit", keys: "Ctrl+0", run: () => document.querySelector(".canvas-host")?.dispatchEvent(new Event("loftline-fit")) },
    { label: "Snap to Grid", run: () => { app.snapToGrid = !app.snapToGrid; refresh(); } },
    { label: "Toolpaths", run: () => { app.showToolpaths = !app.showToolpaths; refresh(); } },
    { label: "Inspector", run: () => { app.showInspector = !app.showInspector; layout(); refresh(); } }, "-",
    {
      label: () => (app.state?.side === "bottom" ? "Show Top Side" : "Show Bottom Side"),
      run: () => { app.selection = new Set(); void apply("setSide", { side: app.state?.side === "bottom" ? "top" : "bottom" }); },
      enabled: () => !!doc().job.twoSided,
    },
  ]],
  ["Design", [
    { label: "Align Left", run: () => void command("align", { mode: "left" }), enabled: hasSelection },
    { label: "Align Centers Horizontally", run: () => void command("align", { mode: "centerX" }), enabled: hasSelection },
    { label: "Align Right", run: () => void command("align", { mode: "right" }), enabled: hasSelection },
    { label: "Align Top", run: () => void command("align", { mode: "top" }), enabled: hasSelection },
    { label: "Align Centers Vertically", run: () => void command("align", { mode: "centerY" }), enabled: hasSelection },
    { label: "Align Bottom", run: () => void command("align", { mode: "bottom" }), enabled: hasSelection },
    { label: "Center on Material", run: () => void command("align", { mode: "materialCenter" }), enabled: hasSelection }, "-",
    { label: "Distribute Horizontally", run: () => void command("distribute", { flag: true }), enabled: hasSelection },
    { label: "Distribute Vertically", run: () => void command("distribute", { flag: false }), enabled: hasSelection }, "-",
    { label: "Group", keys: "Ctrl+G", run: () => void command("group"), enabled: hasSelection },
    { label: "Ungroup", run: () => void command("ungroup"), enabled: hasSelection },
    { label: "Combine Vectors", run: () => void command("combine"), enabled: hasSelection },
    { label: "Break Apart", run: () => void command("breakApart"), enabled: hasSelection }, "-",
    { label: "Weld (Union)", run: () => void command("boolean", { mode: "union" }), enabled: hasSelection },
    { label: "Subtract", run: () => void command("boolean", { mode: "subtract" }), enabled: hasSelection },
    { label: "Intersect", run: () => void command("boolean", { mode: "intersect" }), enabled: hasSelection }, "-",
    { label: "Offset…", run: () => void offsetCommand(), enabled: hasSelection },
    { label: "Join Open Vectors…", run: () => void joinCommand(), enabled: hasSelection },
    { label: "Close Open Vectors", run: () => void command("close"), enabled: hasSelection },
    { label: "Fillet Corners…", run: () => void corners("fillet"), enabled: hasSelection },
    { label: "Chamfer Corners…", run: () => void corners("chamfer"), enabled: hasSelection },
    { label: "Delete Duplicate Vectors", run: () => void command("deleteDuplicates"), enabled: hasSelection }, "-",
    { label: "Rotate 90° Left", run: () => void command("rotate", { number: 90 }), enabled: hasSelection },
    { label: "Rotate 90° Right", run: () => void command("rotate", { number: -90 }), enabled: hasSelection },
    { label: "Mirror Horizontally", run: () => void apply("mirrorShapes", { ids: [...app.selection], horizontally: true }), enabled: hasSelection },
    { label: "Mirror Vertically", run: () => void apply("mirrorShapes", { ids: [...app.selection], horizontally: false }), enabled: hasSelection },
    { label: "Rectangular Array…", run: () => void rectArray(), enabled: hasSelection },
    { label: "Circular Array…", run: () => void circularArray(), enabled: hasSelection },
    { label: "Convert Text to Curves", run: () => void command("textToCurves"), enabled: hasSelection },
  ]],
  ["Toolpaths", [
    { label: "Calculate All", run: () => void busy("Calculating…", () => apply("calculate", {})) },
    { label: "Check Toolpaths…", run: () => void sheets.openValidation() },
    { label: "Save All Toolpaths…", run: () => void sheets.openSaveAll() },
    { label: "Tool Database…", run: () => void sheets.openTools() },
  ]],
  ["Job", [{ label: "Job Setup…", keys: "Ctrl+J", run: () => void sheets.openJobSetup() }]],
  ["Help", [
    { label: "LoftLine Help", keys: "F1", run: () => void sheets.openHelp() },
    { label: "Keyboard Shortcuts", run: () => void sheets.openHelp("shortcuts") },
    { label: "Running a Safe Air Cut", run: () => void sheets.openHelp("airCut") }, "-",
    { label: "Connect an AI Assistant…", run: () => void sheets.openAssistant() },
    { label: "About LoftLine", run: () => sheets.openAbout(info.platform) },
  ]],
];

function createMenuBar() {
  const bar = h("nav", { class: "menu-bar", role: "menubar", "aria-label": "Menu" });
  let open: HTMLElement | null = null;
  const closeAll = () => { open?.classList.remove("open"); open = null; };
  document.addEventListener("click", (e) => { if (!(e.target as Element).closest(".menu")) closeAll(); });
  for (const [name, items] of menus) {
    const popup = h("div", { class: "menu-popup", role: "menu" });
    const fill = () => replace(popup, items.map((item) => item === "-" ? h("div", { class: "menu-sep" }) : h("button", {
      class: "menu-item", role: "menuitem", disabled: !!item.enabled && !item.enabled(),
      onclick: () => { closeAll(); item.run(); },
    }, h("span", {}, typeof item.label === "function" ? item.label() : item.label), item.keys ? h("span", { class: "keys" }, item.keys) : null)));
    const menu = h("div", { class: "menu" }, h("button", {
      class: "menu-title", "aria-haspopup": "true",
      onclick: () => { const was = open === menu; closeAll(); if (!was) { fill(); menu.classList.add("open"); open = menu; } },
      onmouseenter: () => { if (open && open !== menu) { closeAll(); fill(); menu.classList.add("open"); open = menu; } },
    }, name), popup);
    bar.appendChild(menu);
  }
  return bar;
}

window.addEventListener("keydown", (e) => {
  if (e.key === "F1") { e.preventDefault(); void sheets.openHelp(); return; }
  if (!(e.ctrlKey || e.metaKey)) return;
  const k = e.key.toLowerCase();
  const inField = e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement;
  const run = (f: () => void) => { e.preventDefault(); f(); };
  if (k === "n") run(() => void newProject());
  else if (k === "o") run(() => void openProject());
  else if (k === "s") run(() => void save(e.shiftKey));
  else if (k === "i") run(() => void importFile());
  else if (k === "e") run(() => void sheets.openExport(null));
  else if (k === "j") run(() => void sheets.openJobSetup());
  else if (k === "0") run(() => document.querySelector(".canvas-host")?.dispatchEvent(new Event("loftline-fit")));
  else if (!inField && k === "z") run(() => void apply(e.shiftKey ? "redo" : "undo"));
  else if (!inField && k === "c") run(copy);
  else if (!inField && k === "v") run(() => void paste());
  else if (!inField && k === "d") run(() => { copy(); void paste(); });
  else if (!inField && k === "g") run(() => void command("group"));
  else if (!inField && k === "a") run(() => { app.selection = new Set(doc().shapes.map((s) => s.id)); refresh(); });
});

// MARK: Toolbar and layout

function toolbar() {
  const modes = h("div", { class: "segments" });
  const buttons = h("div", { class: "toolbar-tools" });
  const render = () => {
    const seg = (id: typeof app.center, label: string) => h("button", { class: `segment ${app.center === id ? "on" : ""}`, onclick: () => setCenter(id) }, label);
    replace(modes, seg("2d", "2D"), seg("split", "2D | 3D"), seg("3d", "3D"));
    const tb = (d: string, label: string, run: () => void, on = false) => h("button", { class: `icon-toggle ${on ? "on" : ""}`, title: label, "aria-label": label, onclick: run }, icon(d));
    replace(buttons,
      tb(icons.fit, "Zoom to Fit", () => document.querySelector(".canvas-host")?.dispatchEvent(new Event("loftline-fit"))),
      tb(icons.grid, "Snap to Grid", () => { app.snapToGrid = !app.snapToGrid; refresh(); }, app.snapToGrid),
      tb(icons.tools, "Tool Database", () => void sheets.openTools()),
      tb(icons.play, "Preview in 3D", () => setCenter(app.center === "2d" ? "split" : app.center)),
      tb(icons.export, "Export G-code", () => void sheets.openExport(app.tab === "toolpaths" ? app.selectedOp : null)),
      tb(icons.inspector, "Inspector", () => { app.showInspector = !app.showInspector; layout(); refresh(); }, app.showInspector));
  };
  subscribe(render);
  return h("header", { class: "toolbar" }, title, h("span", { class: "spacer" }), modes, h("span", { class: "spacer" }), buttons);
}

function layout() {
  center.classList.toggle("mode-2d", app.center === "2d");
  center.classList.toggle("mode-split", app.center === "split");
  center.classList.toggle("mode-3d", app.center === "3d");
  inspector.classList.toggle("hidden", !app.showInspector);
}

function renderStatus() {
  if (!app.state) return;
  const d = doc(), job = d.job, u = unitLabel(d.units);
  replace(statusBar,
    h("span", {}, `${job.width} x ${job.height} x ${job.thickness} ${u}`),
    h("span", {}, `Z0: ${job.zZero === "materialTop" ? "Material surface" : "Machine bed"}`),
    h("span", {}, `Origin: ${job.xyOrigin === "lowerLeft" ? "Lower left" : job.xyOrigin === "center" ? "Center" : job.xyOrigin}`),
    h("span", {}, app.state.post.name),
    app.state.coverage ? h("strong", {}, app.state.coverage) : null,
    app.state.issues.filter((i) => i.severity !== "note").slice(0, 1).map((i) => h("span", { class: "warn-text", title: i.message }, "Check the post")),
    h("span", { class: "spacer" }),
    h("span", { class: "muted" }, cursor),
    h("span", {}, app.selection.size ? `${app.selection.size} selected` : ""));
}

// The live link's bars (spec 2, "What the user sees"): the Allow question, the assistant at work, a standing Allow, the review marker.
const assistantBars = h("div", { class: "assistant-bars" });
let assistant: AssistantStatus | null = null;
function renderAssistant() {
  const a = assistant;
  if (!a || !app.state) { replace(assistantBars); return; }
  const name = app.state.title;
  const bar = (text: string, ...buttons: HTMLElement[]) => h("div", { class: "assistant-bar", role: "status", "aria-label": text },
    h("span", {}, text), h("span", { class: "spacer" }), ...buttons);
  const button = (label: string, onclick: () => void, primary = false) => h("button", { class: `button${primary ? " primary" : ""}`, onclick }, label);
  const status = async (method: string, params: unknown = {}) => { assistant = await call<AssistantStatus>(method, params); renderAssistant(); };
  const n = a.changes;
  replace(assistantBars,
    a.asking ? bar(`An assistant wants to work on ${name}`, button("Deny", () => void status("assistantAnswer", { allow: false })),
      button("Allow", () => void status("assistantAnswer", { allow: true }), true)) : null,
    a.claimed ? bar("An assistant is working on this document", button("Disconnect", () => void status("assistantRevoke")))
      : a.allowed ? bar("Assistants allowed", button("Revoke", () => void status("assistantRevoke"))) : null,
    n > 0 ? bar(`An assistant changed this document (${n} change${n === 1 ? "" : "s"}); review before posting`,
      button("Dismiss", () => void apply("dismissAssistantMarker"))) : null);
}
subscribe(() => { if (app.state) assistant = app.state.assistant; renderAssistant(); });
// While the switch is on, the window asks the core about the link once a second and refetches when an assistant changed something.
setInterval(async () => {
  if (!liveLink || !app.state) return;
  try {
    const s = await call<AssistantStatus>("assistantStatus");
    const moved = s.changeRevision !== app.state.changeRevision || s.assistantRevision !== app.state.assistant.assistantRevision;
    assistant = s;
    if (moved) setState(await call<State>("state")); else renderAssistant();
  } catch { /* the next poll tries again */ }
}, 1000);

replace(center, assistantBars, h("div", { class: "center-views" }, canvas, preview), statusBar);
replace(root, createSidebar(), h("div", { class: "main-column" }, createMenuBar(), toolbar(), h("div", { class: "work" }, center, inspector)), sheets.createSheetHost(), busyMark);

subscribe(() => {
  if (!app.state) return;
  const name = `${app.state.isDirty ? "• " : ""}${app.state.title}`;
  replace(title, h("strong", {}, name), h("span", { class: "muted small" }, app.state.path ?? ""));
  document.title = `${name} - LoftLine`;
  if (inShell()) void getCurrentWindow().setTitle(document.title).catch(() => undefined);
  replace(busyMark, app.busy ? h("span", {}, app.busy) : null);
  busyMark.classList.toggle("on", !!app.busy);
  renderStatus();
});

// Asks before the window closes on unsaved changes.
if (inShell()) {
  void getCurrentWindow().onCloseRequested(async (e) => {
    if (app.state?.isDirty && !(await sheets.confirmDiscard("Closing the window"))) e.preventDefault();
  });
}

// For headless checks (tools/shots.mjs): the same commands the menus run.
declare global { interface Window { loftline: unknown } }
window.loftline = { app, apply, openProject, setCenter, refresh, sheets, call };

async function start() {
  layout();
  try {
    info = await call<Info>("info");
    setState(await call<State>("state"));
    await call("assistantDialog", { open: false });   // a reloaded window has no dialog open
    setLiveLink((await call<{ liveLink: boolean }>("assistantSetup")).liveLink);
    if (inShell()) {
      const shell = window.__TAURI_INTERNALS__!;
      const opened = (await shell.invoke("opened_file")) as string | null;
      if (opened) await openProject(opened);
      const view = (await shell.invoke("start_view")) as typeof app.center | null;
      if (view) { await apply("calculate", {}); setCenter(view); }
    }
  } catch (e) {
    replace(root, h("div", { class: "fatal" }, h("h1", {}, "LoftLine could not start its core"), h("p", {}, e instanceof Error ? e.message : String(e))));
  }
}
void start();
