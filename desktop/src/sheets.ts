import { message as nativeMessage, open as nativeOpen, save as nativeSave } from "@tauri-apps/plugin-dialog";
import { call, inShell } from "./core";
import { h, replace } from "./dom";
import type { Child } from "./dom";
import type { Issue, Job, JobForm, Machine, Operation, Posted, PostRow, Tool } from "./model";
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

// MARK: Small forms

export interface Field { key: string; label: string; value: number; unit?: string; integer?: boolean }

/** A form of numbers and, optionally, one switch. Resolves to the values, or null on Cancel. */
export function askNumbers(title: string, fields: Field[], flag?: { label: string; value: boolean }): Promise<{ values: Record<string, number>; flag: boolean } | null> {
  return new Promise((resolve) => {
    const values: Record<string, number> = Object.fromEntries(fields.map((f) => [f.key, f.value]));
    let on = flag?.value ?? false;
    const ok = () => { close(); resolve({ values, flag: on }); };
    present(title, [
      fields.map((f) => numberRow(f.label, f.value, f.unit ?? "", (v) => { values[f.key] = v; }, f.integer ? { step: "1", min: 1 } : {})),
      flag ? h("label", { class: "row toggle" }, h("input", { type: "checkbox", checked: on, onchange: (e: Event) => { on = (e.target as HTMLInputElement).checked; } }), flag.label) : null,
    ], [
      h("button", { class: "button", onclick: () => { close(); resolve(null); } }, "Cancel"),
      h("button", { class: "button primary", onclick: () => {
        // A field still being typed in commits on the way out.
        (document.activeElement as HTMLElement | null)?.blur();
        ok();
      } }, "OK"),
    ]);
  });
}

/** The post pickers' entries: the installed posts, and the project's own when only the file has it, so the selection still shows. */
function postChoices(posts: PostRow[]): [string, string][] {
  const own = app.state!.post;
  const rows = posts.map((p): [string, string] => [p.id, p.name]);
  return rows.some(([id]) => id === own.id) ? rows : [...rows, [own.id, `${own.name} (from this project)`]];
}

/** What a program covers when it isn't the whole job: the sheet and side on show. */
const coverageNote = () => app.state?.coverage ? h("p", { class: "small coverage" }, `This covers only: ${app.state.coverage}.`) : null;

// MARK: Save All

interface SaveAllFile { fileName: string; title: string; posted: boolean; issues: Issue[] }
interface SaveAllReply { files: SaveAllFile[]; existing: string[]; invalidNames: string[]; unposted: string[]; written: boolean; hasErrors: boolean }

export async function openSaveAll() {
  const posts = await call<PostRow[]>("posts");
  let mode = "oneFile", postID = app.state!.post.id, groupByTool = false;
  const list = h("div", { class: "export-status tall" });
  const save = h("button", { class: "button primary", disabled: true, onclick: () => void write() }, "Save…");
  const describe = (r: SaveAllReply) => {
    replace(list,
      h("table", { class: "table" }, h("thead", {}, h("tr", {}, h("th", {}, "File"), h("th", {}, "Holds"), h("th", {}, "State"))),
        h("tbody", {}, r.files.map((f) => {
          const errors = f.issues.filter((i) => i.severity === "error").length, warnings = f.issues.filter((i) => i.severity === "warning").length;
          return h("tr", {}, h("td", {}, f.fileName), h("td", {}, f.title), h("td", { class: !f.posted || errors ? "error-text" : "" }, !f.posted ? "Failed to post" : errors ? `${errors} error${errors === 1 ? "" : "s"}` : warnings ? `${warnings} warning${warnings === 1 ? "" : "s"}` : "OK"));
        }))),
      r.hasErrors ? h("p", { class: "error-text" }, "A program has errors or a missing step, so nothing can be saved. Fix it in Check Toolpaths.") : null,
      r.invalidNames.length ? h("p", { class: "error-text" }, `These names clash: ${r.invalidNames.join(", ")}`) : null);
    save.disabled = r.hasErrors || r.unposted.length > 0 || r.invalidNames.length > 0 || r.files.length === 0;
  };
  const plan = async () => {
    replace(list, h("p", { class: "muted" }, "Posting…"));
    save.disabled = true;
    try {
      describe(await busy("Calculating…", () => call<SaveAllReply>("saveAll", { mode, postID, groupByTool })));
      await apply("state");
    } catch (e) { replace(list, h("p", { class: "error-text" }, e instanceof Error ? e.message : String(e))); }
  };
  const write = async () => {
    const folder = inShell() ? await nativeOpen({ title: "Save All Toolpaths", directory: true }) as string | null : await askPath("Folder");
    if (!folder) return;
    let reply = await call<SaveAllReply>("saveAll", { mode, postID, groupByTool, folder });
    if (!reply.written && reply.existing.length) {
      const yes = await new Promise<boolean>((resolve) => present("Replace files?", h("p", {}, `${reply.existing.join(", ")} already exist in that folder.`), [
        h("button", { class: "button", onclick: () => resolve(false) }, "Cancel"), h("button", { class: "button danger", onclick: () => resolve(true) }, "Replace"),
      ]));
      close();
      if (!yes) return;
      reply = await call<SaveAllReply>("saveAll", { mode, postID, groupByTool, folder, replacing: true });
    }
    close();
    if (!reply.written) openAlert("Save All Toolpaths", "Nothing was written.");
  };
  present("Save All Toolpaths", [
    h("div", { class: "form-grid" },
      selectRow("Files", mode, [["oneFile", "One file"], ["filePerToolpath", "One file per toolpath"], ["filePerTool", "One file per tool"]], (v) => { mode = v; void plan(); }),
      selectRow("Post processor", postID, postChoices(posts), (v) => { postID = v; void plan(); }),
      h("label", { class: "row toggle" }, h("input", { type: "checkbox", onchange: (e: Event) => { groupByTool = (e.target as HTMLInputElement).checked; void plan(); } }), "Group by tool (fewest tool changes)")),
    coverageNote(),
    list,
  ], [h("button", { class: "button", onclick: close }, "Close"), save], true);
  void plan();
}

// MARK: Help

interface Topic { id: string; title: string; body: string; related: string[] }

/** The Mac's own help text, from the core. Inline Markdown only: bold, code and paragraphs. */
function paragraphs(body: string) {
  return body.split("\n\n").map((block) => {
    const p = h("p", {});
    for (const part of block.split(/(\*\*[^*]+\*\*|`[^`]+`)/)) {
      if (part.startsWith("**")) p.appendChild(h("strong", {}, part.slice(2, -2)));
      else if (part.startsWith("`")) p.appendChild(h("code", {}, part.slice(1, -1)));
      else if (part) p.appendChild(document.createTextNode(part));
    }
    return p;
  });
}

export async function openHelp(topicID?: string) {
  const topics = await call<Topic[]>("help");
  let current = topics.find((t) => t.id === topicID) ?? topics[0];
  const side = h("ul", { class: "tool-list" });
  const text = h("div", { class: "help-text" });
  const render = () => {
    replace(side, topics.map((t) => h("li", { class: t.id === current.id ? "on" : "", onclick: () => { current = t; render(); } }, t.title)));
    replace(text, h("h3", {}, current.title), paragraphs(current.body),
      current.related.length ? h("p", { class: "small" }, "See also: ", current.related.map((id) => {
        const t = topics.find((x) => x.id === id);
        return t ? h("button", { class: "link-button", onclick: () => { current = t; render(); } }, t.title) : null;
      })) : null);
  };
  render();
  present("LoftLine Help", h("div", { class: "tools-layout" }, side, text), h("button", { class: "button primary", onclick: close }, "Close"), true);
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
        selectRow("Post processor", postID, postChoices(posts), (v) => { postID = v; void post(); }),
        h("label", { class: "row toggle" }, h("input", { type: "checkbox", onchange: (e: Event) => { groupByTool = (e.target as HTMLInputElement).checked; void post(); } }), "Group by tool (fewest tool changes)")),
      coverageNote(), summary, text,
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
  const [machines, posts, form] = await Promise.all([call<Machine[]>("machines"), call<PostRow[]>("posts"), call<JobForm>("jobForm")]);
  const d = doc();
  let job: Job = { ...d.job };
  let units: string = d.units, gridSpacing = d.gridSpacing, name = d.name;
  let machineID = form.machineID ?? "";
  let postID = app.state!.post.id;
  // The project's own machine, even one not installed here; no machine at all is a choice too, since Apply then leaves it unset.
  const machineChoices: [string, string][] = [...(form.machineID ? [] : [["", "Custom (post limits)"] as [string, string]]), ...form.machineChoices.map((m): [string, string] => [m.id, m.title])];
  const body = h("div", {});
  const render = () => {
    const u = unitLabel(units);
    replace(body,
      h("div", { class: "form-grid" },
        h("label", { class: "row" }, h("span", { class: "row-label" }, "Job name"), h("input", { class: "text", value: name, onchange: (e: Event) => { name = (e.target as HTMLInputElement).value; } })),
        selectRow("Units", units, [["inch", "Inches"], ["millimeter", "Millimeters"]], (v) => {
          // The core converts: it knows every length a job holds, shown here or not.
          void call<{ job: Job; gridSpacing: number }>("convertJob", { units, job, gridSpacing, to: v }).then((r) => {
            job = r.job;
            gridSpacing = r.gridSpacing;
            units = v;
            render();
          }, (e) => openAlert("Job Setup", e instanceof Error ? e.message : String(e)));
        }),
        numberRow("Width", job.width, u, (v) => { job.width = v; }, { min: 0 }),
        numberRow("Height", job.height, u, (v) => { job.height = v; }, { min: 0 }),
        numberRow("Thickness", job.thickness, u, (v) => { job.thickness = v; }, { min: 0 }),
        selectRow("Z zero", job.zZero, [["materialTop", "Material surface"], ["spoilboard", "Machine bed (spoilboard)"]], (v) => { job.zZero = v; }),
        selectRow("XY origin", job.xyOrigin, [["lowerLeft", "Lower left"], ["lowerRight", "Lower right"], ["upperLeft", "Upper left"], ["upperRight", "Upper right"], ["center", "Center"]], (v) => { job.xyOrigin = v; }),
        numberRow("Safe Z", job.safeZ, u, (v) => { job.safeZ = v; }),
        numberRow("Home Z", job.homeZ, u, (v) => { job.homeZ = v; }),
        numberRow("Grid spacing", gridSpacing, u, (v) => { gridSpacing = v; }, { min: 0 }),
        selectRow("Machine", machineID, machineChoices, (v) => { machineID = v; const m = machines.find((x) => x.id === v); if (m && !m.postIDs.includes(postID) && m.postIDs[0]) { postID = m.postIDs[0]; render(); } }),
        selectRow("Post processor", postID, postChoices(posts), (v) => { postID = v; })));
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
      const ok = await apply("addText", { spec: { string: text.value, fontName: font, size, alignment: "left", lineSpacing: 1, letterSpacing: 0, transform: { a: 1, b: 0, c: 0, d: 1, tx: at.x, ty: at.y } } });
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
