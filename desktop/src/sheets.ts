import { message as nativeMessage, open as nativeOpen, save as nativeSave } from "@tauri-apps/plugin-dialog";
import { call, inShell } from "./core";
import { h, replace } from "./dom";
import type { Child } from "./dom";
import type { Issue, Job, Machine, Operation, Posted, PostRow, Tool } from "./model";
import { kindTitles, opBody, unitLabel } from "./model";
import { app, apply, busy, doc, project, refresh, setErrorHandler } from "./state";
import { numberRow, selectRow } from "./inspector";

let host: HTMLElement;
export function createSheetHost(): HTMLElement {
  host = h("div", { class: "sheet-host" });
  setErrorHandler((title, text) => openAlert(title, text));
  return host;
}

function close() { replace(host); host.classList.remove("open"); }

function present(title: string, body: Child, footer: Child, wide = false) {
  host.classList.add("open");
  const sheet = h("div", { class: `sheet ${wide ? "wide" : ""}`, role: "dialog", "aria-modal": "true", "aria-label": title },
    h("h2", {}, title), h("div", { class: "sheet-body" }, body), h("div", { class: "sheet-foot" }, footer));
  replace(host, sheet);
  sheet.addEventListener("keydown", (e) => { if (e.key === "Escape") close(); });
  (sheet.querySelector("input, select, button") as HTMLElement | null)?.focus();
}

export function openAlert(title: string, text: string) {
  present(title, h("p", { class: "alert-text" }, text), h("button", { class: "button primary", onclick: close }, "OK"));
}

export function confirmDiscard(what: string): Promise<boolean> {
  return new Promise((resolve) => {
    present("Unsaved changes", h("p", {}, `${what} will lose the changes to “${app.state?.title ?? "this project"}”.`), [
      h("button", { class: "button", onclick: () => { close(); resolve(false); } }, "Cancel"),
      h("button", { class: "button danger", onclick: () => { close(); resolve(true); } }, "Discard Changes"),
    ]);
  });
}

// File dialogs: native in the shell. In a plain browser, where no dialog can name a real path, a path is typed.
async function askPath(title: string): Promise<string | null> {
  return new Promise((resolve) => {
    const input = h("input", { class: "text wide", "aria-label": "Path", placeholder: "/path/to/file" });
    present(title, input, [
      h("button", { class: "button", onclick: () => { close(); resolve(null); } }, "Cancel"),
      h("button", { class: "button primary", onclick: () => { const v = input.value; close(); resolve(v || null); } }, "OK"),
    ]);
  });
}

export async function pickOpen(title: string, extensions: string[]): Promise<string | null> {
  if (!inShell()) return askPath(title);
  const picked = await nativeOpen({ title, multiple: false, filters: [{ name: title, extensions }] });
  return typeof picked === "string" ? picked : null;
}

export async function pickSave(title: string, name: string, extension: string): Promise<string | null> {
  if (!inShell()) return askPath(title);
  return nativeSave({ title, defaultPath: name, filters: [{ name: extension.toUpperCase(), extensions: [extension] }] });
}

export const nativeAlert = async (text: string) => { if (inShell()) await nativeMessage(text); };

function issueList(issues: Issue[]) {
  if (issues.length === 0) return h("p", { class: "good-text small" }, "No issues.");
  return h("ul", { class: "issue-list" }, issues.map((i) => h("li", { class: i.severity }, h("strong", {}, i.severity), i.line ? ` line ${i.line}: ` : ": ", i.message)));
}

// MARK: Export

/** Posts through the core, shows what it made and what the validator said, and writes only what the core posted. */
export async function openExport(operationID: string | null) {
  const posts = await call<PostRow[]>("posts");
  let postID = app.state!.post.id;
  let groupByTool = false;
  let posted: Posted | null = null;
  const op = operationID ? project().operations.find((o) => opBody(o).setup.id === operationID) : undefined;
  const summary = h("div", { class: "export-status" });
  const text = h("pre", { class: "program" });
  const save = h("button", { class: "button primary", disabled: true, onclick: () => void write(false) }, "Save…");
  const force = h("button", { class: "button danger hidden", onclick: () => void write(true) }, "Save Anyway…");

  const post = async () => {
    replace(summary, h("p", { class: "muted" }, "Posting…"));
    replace(text);
    save.disabled = true;
    try {
      posted = await busy("Calculating…", () => call<Posted>("export", { postID, groupByTool, operation: operationID ?? undefined }));
      await apply("state");
    } catch (e) {
      replace(summary, h("p", { class: "error-text" }, e instanceof Error ? e.message : String(e)));
      return;
    }
    show(posted);
  };

  const show = (p: Posted) => {
    const refused = p.missingSteps.length > 0 || p.text === undefined || p.text === null;
    replace(summary,
      p.errorMessage ? h("p", { class: "error-text" }, p.errorMessage) : null,
      h("p", { class: "small" }, `${p.toolpathCount} toolpath${p.toolpathCount === 1 ? "" : "s"} · ${p.post} · ${p.fileName}`),
      issueList(p.issues));
    replace(text, p.text ?? "");
    save.disabled = refused || p.hasErrors;
    force.classList.toggle("hidden", refused || !p.hasErrors);
  };

  const write = async (withErrors: boolean) => {
    if (!posted) return;
    const extension = posted.fileName.split(".").pop() ?? "tap";
    const path = await pickSave("Save G-code", posted.fileName, extension);
    if (!path) return;
    // Posted again and written by the core, so the file is the post's bytes (line endings included) for the project as it is now.
    const result = await call<Posted>("export", { postID, groupByTool, operation: operationID ?? undefined, path, force: withErrors });
    if (result.written) {
      close();
    } else {
      show(result);
      replace(summary, h("p", { class: "error-text" }, "Nothing was written: the program has errors."), issueList(result.issues));
    }
  };

  present(op ? `Export G-code: ${opBody(op).setup.name}` : "Export G-code",
    [
      h("div", { class: "form-grid" },
        selectRow("Post processor", postID, posts.map((p) => [p.id, p.name]), (v) => { postID = v; void post(); }),
        h("label", { class: "row toggle" }, h("input", { type: "checkbox", onchange: (e: Event) => { groupByTool = (e.target as HTMLInputElement).checked; void post(); } }), "Group by tool (fewest tool changes)")),
      summary, text,
    ],
    [h("button", { class: "button", onclick: close }, "Close"), force, save], true);
  void post();
}

// MARK: Check Toolpaths

export async function openValidation() {
  const body = h("div", {}, h("p", { class: "muted" }, "Checking…"));
  present("Check Toolpaths", body, h("button", { class: "button primary", onclick: close }, "Close"), true);
  try {
    const posted = await busy("Calculating…", () => call<Posted>("export", {}));
    await apply("state");
    const rows = project().operations.map((o: Operation) => {
      const { setup } = opBody(o);
      const s = app.state!.statuses.find((x) => x.id === setup.id);
      return h("tr", {}, h("td", {}, setup.name), h("td", {}, kindTitles[Object.keys(o)[0]] ?? ""), h("td", {}, !setup.isEnabled ? "Off" : s?.error ? "Failed" : s?.isCalculated ? s.duration : "Not calculated"));
    });
    replace(body,
      posted.errorMessage ? h("p", { class: "error-text" }, posted.errorMessage) : null,
      h("table", { class: "table" }, h("thead", {}, h("tr", {}, h("th", {}, "Toolpath"), h("th", {}, "Type"), h("th", {}, "Time"))), h("tbody", {}, rows)),
      h("h3", {}, posted.hasErrors ? "Errors must be fixed before cutting" : "Program"),
      issueList(posted.issues));
  } catch (e) {
    replace(body, h("p", { class: "error-text" }, e instanceof Error ? e.message : String(e)));
  }
}

// MARK: Job Setup

export async function openJobSetup() {
  const [machines, posts] = await Promise.all([call<Machine[]>("machines"), call<PostRow[]>("posts")]);
  const d = doc();
  const job: Job = { ...d.job };
  let units: string = d.units, gridSpacing = d.gridSpacing, name = d.name;
  let machineID = machines.find((m) => m.name === app.state!.machine)?.id ?? "";
  let postID = app.state!.post.id;
  const body = h("div", {});
  const render = () => {
    const u = unitLabel(units);
    replace(body,
      h("div", { class: "form-grid" },
        h("label", { class: "row" }, h("span", { class: "row-label" }, "Job name"), h("input", { class: "text", value: name, onchange: (e: Event) => { name = (e.target as HTMLInputElement).value; } })),
        selectRow("Units", units, [["inch", "Inches"], ["millimeter", "Millimeters"]], (v) => {
          const factor = v === units ? 1 : v === "millimeter" ? 25.4 : 1 / 25.4;
          for (const k of ["width", "height", "thickness", "safeZ", "homeZ"] as const) job[k] = (job[k] as number) * factor;
          job.home = { x: job.home.x * factor, y: job.home.y * factor };
          gridSpacing *= factor;
          units = v;
          render();
        }),
        numberRow("Width", job.width, u, (v) => { job.width = v; }, { min: 0 }),
        numberRow("Height", job.height, u, (v) => { job.height = v; }, { min: 0 }),
        numberRow("Thickness", job.thickness, u, (v) => { job.thickness = v; }, { min: 0 }),
        selectRow("Z zero", job.zZero, [["materialTop", "Material surface"], ["machineBed", "Machine bed (spoilboard)"]], (v) => { job.zZero = v; }),
        selectRow("XY origin", job.xyOrigin, [["lowerLeft", "Lower left"], ["lowerRight", "Lower right"], ["upperLeft", "Upper left"], ["upperRight", "Upper right"], ["center", "Center"]], (v) => { job.xyOrigin = v; }),
        numberRow("Safe Z", job.safeZ, u, (v) => { job.safeZ = v; }),
        numberRow("Home Z", job.homeZ, u, (v) => { job.homeZ = v; }),
        numberRow("Grid spacing", gridSpacing, u, (v) => { gridSpacing = v; }, { min: 0 }),
        selectRow("Machine", machineID, machines.map((m) => [m.id, m.name]), (v) => { machineID = v; const m = machines.find((x) => x.id === v); if (m && !m.postIDs.includes(postID) && m.postIDs[0]) { postID = m.postIDs[0]; render(); } }),
        selectRow("Post processor", postID, posts.map((p) => [p.id, p.name]), (v) => { postID = v; })));
  };
  render();
  present("Job Setup", body, [
    h("button", { class: "button", onclick: close }, "Cancel"),
    h("button", { class: "button primary", onclick: async () => {
      const ok = await apply("setJob", { units, job, gridSpacing, name, machineID: machineID || undefined, postID });
      if (ok) { close(); document.querySelector(".canvas-host")?.dispatchEvent(new Event("loftline-fit")); }
    } }, "Apply"),
  ], true);
}

// MARK: Tool Database

export async function openTools() {
  let tools = await call<Tool[]>("tools");
  let current: Tool | null = tools[0] ?? null;
  const list = h("ul", { class: "tool-list" });
  const form = h("div", { class: "tool-form" });
  const render = () => {
    replace(list, tools.slice().sort((a, b) => a.number - b.number).map((t) => h("li", { class: t.id === current?.id ? "on" : "", onclick: () => { current = t; render(); } }, `T${t.number} · ${t.name}`)));
    if (!current) { replace(form); return; }
    const t: Tool = { ...current };
    const u = unitLabel(t.units);
    const fu = t.units === "inch" ? "in/min" : "mm/min";
    replace(form,
      h("label", { class: "row" }, h("span", { class: "row-label" }, "Name"), h("input", { class: "text", value: t.name, onchange: (e: Event) => { t.name = (e.target as HTMLInputElement).value; } })),
      numberRow("Tool number", t.number, "", (v) => { t.number = v; }, { min: 1, step: "1" }),
      numberRow("Diameter", t.diameter, u, (v) => { t.diameter = v; }, { min: 0 }),
      numberRow("Flutes", t.flutes, "", (v) => { t.flutes = v; }, { min: 1, step: "1" }),
      numberRow("Flute length", t.fluteLength, u, (v) => { t.fluteLength = v; }, { min: 0 }),
      numberRow("Spindle speed", t.spindleRPM, "RPM", (v) => { t.spindleRPM = v; }, { min: 0 }),
      numberRow("Feed rate", t.feedRate, fu, (v) => { t.feedRate = v; }, { min: 0 }),
      numberRow("Plunge rate", t.plungeRate, fu, (v) => { t.plungeRate = v; }, { min: 0 }),
      numberRow("Pass depth", t.stepdown, u, (v) => { t.stepdown = v; }, { min: 0 }),
      numberRow("Stepover", t.stepover, u, (v) => { t.stepover = v; }, { min: 0 }),
      h("div", { class: "button-row" }, h("button", { class: "button primary", onclick: async () => {
        tools = await call<Tool[]>("saveTool", { tool: t });
        current = tools.find((x) => x.id === t.id) ?? null;
        await apply("state");
        render();
      } }, "Save Tool")));
  };
  render();
  present("Tool Database", h("div", { class: "tools-layout" }, list, form), h("button", { class: "button primary", onclick: close }, "Close"), true);
}

// MARK: Text

export function openText(at: { x: number; y: number }, defaultFont: string, fonts: string[]) {
  const text = h("input", { class: "text wide", value: "LoftLine", "aria-label": "Text" });
  let font = fonts.includes(defaultFont) ? defaultFont : fonts[0] ?? defaultFont;
  let size = app.state!.project.document.units === "inch" ? 1 : 25;
  present("Add Text", [
    h("label", { class: "row" }, h("span", { class: "row-label" }, "Text"), text),
    selectRow("Font", font, fonts.map((f) => [f, f]), (v) => { font = v; }),
    numberRow("Height", size, unitLabel(app.state!.project.document.units), (v) => { size = v; }, { min: 0 }),
  ], [
    h("button", { class: "button", onclick: close }, "Cancel"),
    h("button", { class: "button primary", onclick: async () => {
      const ok = await apply("addText", { spec: { string: text.value, fontName: font, size, transform: { a: 1, b: 0, c: 0, d: 1, tx: at.x, ty: at.y } } });
      if (ok) { app.tool = "select"; close(); refresh(); }
    } }, "Add"),
  ]);
}

export function openAbout(platform: string) {
  present("About LoftLine", [
    h("p", {}, "LoftLine for Windows and Linux."),
    h("p", { class: "muted small" }, `Running on ${platform}. Toolpaths and G-code come from the same Swift core as the Mac app.`),
  ], h("button", { class: "button primary", onclick: close }, "OK"));
}
