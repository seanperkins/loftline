import { getCurrentWindow } from "@tauri-apps/api/window";
import { createCanvas } from "./canvas";
import { call, inShell } from "./core";
import { h, icon, icons, replace } from "./dom";
import { createInspector } from "./inspector";
import { unitLabel } from "./model";
import { createPreview } from "./preview3d";
import * as sheets from "./sheets";
import { createSidebar } from "./sidebar";
import { app, apply, busy, doc, refresh, setState, subscribe } from "./state";
import type { State } from "./model";

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
    const imported = await call<{ state: State; warnings: string[] }>("import", { path });
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

const setCenter = (m: typeof app.center) => {
  app.center = m;
  layout();
  refresh();
  requestAnimationFrame(() => document.querySelector(".canvas-host")?.dispatchEvent(new Event("loftline-fit")));
};

// MARK: Menu bar: in the window, as is usual on Windows and Linux (the Mac app uses the system menu bar).

type Item = { label: string; keys?: string; run: () => void; enabled?: () => boolean } | "-";
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
  ]],
  ["Edit", [
    { label: "Undo", keys: "Ctrl+Z", run: () => void apply("undo"), enabled: () => !!app.state?.undoAction },
    { label: "Redo", keys: "Ctrl+Shift+Z", run: () => void apply("redo"), enabled: () => !!app.state?.redoAction }, "-",
    { label: "Delete", keys: "Del", run: () => void apply("deleteShapes", { ids: [...app.selection] }), enabled: hasSelection },
    { label: "Select All", keys: "Ctrl+A", run: () => { app.selection = new Set(doc().shapes.map((s) => s.id)); refresh(); } },
  ]],
  ["View", [
    { label: "2D", run: () => setCenter("2d") }, { label: "2D | 3D", run: () => setCenter("split") }, { label: "3D", run: () => setCenter("3d") }, "-",
    { label: "Zoom to Fit", keys: "Ctrl+0", run: () => document.querySelector(".canvas-host")?.dispatchEvent(new Event("loftline-fit")) },
    { label: "Snap to Grid", run: () => { app.snapToGrid = !app.snapToGrid; refresh(); } },
    { label: "Toolpaths", run: () => { app.showToolpaths = !app.showToolpaths; refresh(); } },
    { label: "Inspector", run: () => { app.showInspector = !app.showInspector; layout(); refresh(); } },
  ]],
  ["Toolpaths", [
    { label: "Calculate All", run: () => void busy("Calculating…", () => apply("calculate", {})) },
    { label: "Check Toolpaths…", run: () => void sheets.openValidation() },
    { label: "Tool Database…", run: () => void sheets.openTools() },
  ]],
  ["Job", [{ label: "Job Setup…", keys: "Ctrl+J", run: () => void sheets.openJobSetup() }]],
  ["Help", [{ label: "About LoftLine", run: () => sheets.openAbout(info.platform) }]],
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
    }, h("span", {}, item.label), item.keys ? h("span", { class: "keys" }, item.keys) : null)));
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
    app.state.issues.filter((i) => i.severity !== "note").slice(0, 1).map((i) => h("span", { class: "warn-text", title: i.message }, "Check the post")),
    h("span", { class: "spacer" }),
    h("span", { class: "muted" }, cursor),
    h("span", {}, app.selection.size ? `${app.selection.size} selected` : ""));
}

replace(center, h("div", { class: "center-views" }, canvas, preview), statusBar);
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
    if (inShell()) {
      const shell = window.__TAURI_INTERNALS__!;
      const opened = (await shell.invoke("opened_file")) as string | null;
      if (opened) await openProject(opened);
    }
  } catch (e) {
    replace(root, h("div", { class: "fatal" }, h("h1", {}, "LoftLine could not start its core"), h("p", {}, e instanceof Error ? e.message : String(e))));
  }
}
void start();
