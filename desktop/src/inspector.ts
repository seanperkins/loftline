import { h, icon, icons, replace } from "./dom";
import type { Child } from "./dom";
import type { Operation, Params, Shape, TextSpec, Tool } from "./model";
import { feedLabel, kindTitles, opBody, opKind, shapeBounds, unitLabel } from "./model";
import { app, apply, busy, doc, operation, project, refresh, status, subscribe, units } from "./state";

/** The right column: the selected vector's settings, or the selected toolpath's editor. */
export function createInspector(): HTMLElement {
  const root = h("aside", { class: "inspector", "aria-label": "Inspector" });
  let lastKey = "";
  subscribe(() => {
    if (!app.state) return;
    // Rebuilt only when what it shows changed, so a field being typed in keeps its focus and its text.
    const op = app.tab === "toolpaths" ? operation(app.selectedOp) : undefined;
    const st = op ? status(opBody(op).setup.id) : undefined;
    const key = JSON.stringify([app.tab, [...app.selection], op, st, app.state.designRevision, app.tab === "design" ? selectionShapes() : 0]);
    if (key === lastKey) return;
    lastKey = key;
    replace(root, app.tab === "toolpaths" ? (op ? operationEditor(op) : noOperation()) : shapeInspector());
  });
  return root;
}

function selectionShapes(): Shape[] { return doc().shapes.filter((s) => app.selection.has(s.id)); }

function section(title: string, ...children: Child[]) {
  return h("section", { class: "section" }, h("h3", {}, title), children);
}

/** A number field, in a labelled row. Applies on change (Enter or leaving the field). */
export function numberRow(label: string, value: number | undefined, unit: string, onChange: (v: number) => void, options: { min?: number; step?: string } = {}) {
  return h("label", { class: "row" },
    h("span", { class: "row-label" }, label),
    h("span", { class: "row-field" },
      h("input", {
        class: "number", type: "number", step: options.step ?? "any", min: options.min, value: value ?? "",
        onchange: (e: Event) => {
          const v = Number((e.target as HTMLInputElement).value);
          if (Number.isFinite(v)) onChange(v);
        },
      }),
      h("span", { class: "unit" }, unit)));
}

export function toggleRow(label: string, value: boolean, onChange: (v: boolean) => void) {
  return h("label", { class: "row toggle" },
    h("input", { type: "checkbox", checked: value, onchange: (e: Event) => onChange((e.target as HTMLInputElement).checked) }),
    h("span", {}, label));
}

export function selectRow(label: string, value: string, options: [string, string][], onChange: (v: string) => void) {
  return h("label", { class: "row" },
    h("span", { class: "row-label" }, label),
    h("select", { class: "select", onchange: (e: Event) => onChange((e.target as HTMLSelectElement).value) },
      options.map(([v, t]) => h("option", { value: v, ...(v === value ? { selected: true } : {}) }, t))));
}

function shapeInspector(): Child {
  const shapes = selectionShapes();
  if (shapes.length === 0) {
    const job = doc().job;
    return section("Nothing selected",
      h("p", { class: "muted small" }, `Material ${job.width} × ${job.height} × ${job.thickness} ${unitLabel(units())}. Select vectors to edit them.`));
  }
  const ids = shapes.map((s) => s.id);
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const s of shapes) {
    const b = shapeBounds(s);
    minX = Math.min(minX, b.minX); minY = Math.min(minY, b.minY); maxX = Math.max(maxX, b.maxX); maxY = Math.max(maxY, b.maxY);
  }
  const w = maxX - minX, ht = maxY - minY, u = unitLabel(units());
  const r3 = (v: number) => Math.round(v * 10000) / 10000;
  const single = shapes.length === 1 ? shapes[0] : null;
  const resize = (nw: number, nh: number) => {
    if (w <= 0 || ht <= 0 || nw <= 0 || nh <= 0) return;
    const sx = nw / w, sy = nh / ht;
    void apply("transformShapes", { ids, action: "Resize", transform: { a: sx, b: 0, c: 0, d: sy, tx: minX - minX * sx, ty: minY - minY * sy } });
  };
  return [
    section(single ? (single.text ? "Text" : "Vector") : `${shapes.length} vectors`,
      single ? h("label", { class: "row" }, h("span", { class: "row-label" }, "Name"), h("input", { class: "text", value: single.name, onchange: (e: Event) => void apply("replaceShape", { shape: { ...single, name: (e.target as HTMLInputElement).value } }) })) : null,
      selectRow("Layer", shapes.every((s) => s.layerID === shapes[0].layerID) ? shapes[0].layerID : "", [...(shapes.every((s) => s.layerID === shapes[0].layerID) ? [] : [["", "Mixed"] as [string, string]]), ...doc().layers.map((l) => [l.id, l.name] as [string, string])],
        (layer) => { if (layer) void apply("moveShapesToLayer", { ids, layer }); })),
    section("Position and Size",
      numberRow("X", r3(minX), u, (v) => void apply("translateShapes", { ids, by: { x: v - minX, y: 0 } })),
      numberRow("Y", r3(minY), u, (v) => void apply("translateShapes", { ids, by: { x: 0, y: v - minY } })),
      numberRow("Width", r3(w), u, (v) => resize(v, ht), { min: 0 }),
      numberRow("Height", r3(ht), u, (v) => resize(w, v), { min: 0 })),
    single?.text ? textSection(single, single.text) : null,
    section("Arrange",
      h("div", { class: "button-row" },
        h("button", { class: "button", onclick: () => void apply("mirrorShapes", { ids, horizontally: true }) }, "Mirror ↔"),
        h("button", { class: "button", onclick: () => void apply("mirrorShapes", { ids, horizontally: false }) }, "Mirror ↕"),
        h("button", { class: "button", onclick: () => void apply("deleteShapes", { ids }) }, "Delete"))),
  ];
}

function textSection(shape: Shape, spec: TextSpec) {
  const update = (change: Partial<TextSpec>) => void apply("updateText", { id: shape.id, spec: { ...spec, ...change } });
  return section("Text",
    h("label", { class: "row" }, h("span", { class: "row-label" }, "Text"), h("input", { class: "text", value: spec.string, onchange: (e: Event) => update({ string: (e.target as HTMLInputElement).value }) })),
    h("label", { class: "row" }, h("span", { class: "row-label" }, "Font"), h("input", { class: "text", value: spec.fontName, onchange: (e: Event) => update({ fontName: (e.target as HTMLInputElement).value }) })),
    numberRow("Height", spec.size, unitLabel(units()), (v) => update({ size: v }), { min: 0 }));
}

function noOperation(): Child {
  return section("Toolpaths", h("p", { class: "muted small" }, "Select a toolpath, or use New Toolpath."));
}

// The form for a toolpath. `params` is the core's own JSON, edited in place and sent back whole; the core recalculates nothing until asked.
function operationEditor(op: Operation): Child {
  const kind = opKind(op);
  const { setup, params } = opBody(op);
  const u = unitLabel(units());
  const send = (next: Operation) => apply("updateOperation", { operation: next });
  const withSetup = (change: Partial<typeof setup>): Operation => ({ [kind]: { _0: { setup: { ...setup, ...change }, params } } });
  const withParams = (change: Params): Operation => ({ [kind]: { _0: { setup, params: { ...params, ...change } } } });
  const set = (key: string, value: unknown) => void send(withParams({ [key]: value }));
  const nested = (key: string, field: string, value: unknown) => set(key, { ...(params[key] as Params), [field]: value });
  const tools = project().tools.slice().sort((a, b) => a.number - b.number);
  const tool = tools.find((t) => t.id === setup.toolID);
  const st = status(setup.id);

  const depth = params.depth as Params | undefined;
  const depthSection = depth ? section("Cutting Depths",
    numberRow("Start depth", depth.startDepth as number, u, (v) => nested("depth", "startDepth", v)),
    toggleRow("Cut through the material", depth.overcut !== undefined && depth.overcut !== null, (on) => nested("depth", "overcut", on ? 0 : null)),
    depth.overcut !== undefined && depth.overcut !== null
      ? numberRow("Past the bottom", depth.overcut as number, u, (v) => nested("depth", "overcut", v))
      : numberRow("Cut depth", depth.cutDepth as number, u, (v) => nested("depth", "cutDepth", v)),
    numberRow("Final pass", depth.finalPassDepth as number, u, (v) => nested("depth", "finalPassDepth", v))) : null;

  const direction = "direction" in params
    ? selectRow("Direction", params.direction as string, [["climb", "Climb"], ["conventional", "Conventional"]], (v) => set("direction", v)) : null;
  const allowance = "allowance" in params ? numberRow("Allowance", params.allowance as number, u, (v) => set("allowance", v)) : null;

  const ramp = params.ramp as Params | undefined;
  const rampSection = ramp && typeof ramp === "object" ? section("Ramps",
    toggleRow("Ramp plunges", ramp.isEnabled as boolean, (v) => nested("ramp", "isEnabled", v)),
    ramp.isEnabled ? [
      selectRow("Ramp type", ramp.type as string, [["smooth", "Smooth"], ["zigzag", "Zigzag"], ["spiral", "Spiral"]], (v) => nested("ramp", "type", v)),
      numberRow("Length", ramp.length as number, u, (v) => nested("ramp", "length", v)),
      numberRow("Max angle", ramp.maxAngle as number, "°", (v) => nested("ramp", "maxAngle", v)),
    ] : null) : null;

  const specific: Child[] = [];
  if (kind === "profile") {
    const tabs = params.tabs as Params;
    specific.push(depthSection,
      section("Machine Vectors",
        selectRow("Side", params.side as string, [["outside", "Outside"], ["inside", "Inside"], ["on", "On the line"]], (v) => set("side", v)),
        direction, allowance, toggleRow("Output arcs (G2/G3)", params.preferArcs as boolean, (v) => set("preferArcs", v))),
      section("Tabs",
        toggleRow("Add tabs", tabs.isEnabled as boolean, (v) => nested("tabs", "isEnabled", v)),
        tabs.isEnabled ? [numberRow("Length", tabs.length as number, u, (v) => nested("tabs", "length", v)), numberRow("Thickness", tabs.thickness as number, u, (v) => nested("tabs", "thickness", v))] : null),
      rampSection);
  } else if (kind === "pocket") {
    const raster = typeof params.strategy === "object" && params.strategy !== null && "raster" in (params.strategy as object);
    specific.push(depthSection,
      section("Clearing",
        selectRow("Clearing", raster ? "raster" : "offset", [["offset", "Offset"], ["raster", "Raster"]], (v) => set("strategy", v === "raster" ? { raster: { angle: 0, profilePass: "none" } } : { offset: {} })),
        direction, allowance),
      rampSection);
  } else if (kind === "drill") {
    specific.push(depthSection, section("Drilling",
      numberRow("Peck depth", params.peckDepth as number, u, (v) => set("peckDepth", v)),
      numberRow("Dwell at bottom", params.dwellSeconds as number, "s", (v) => set("dwellSeconds", v))));
  } else if (kind === "vcarve") {
    specific.push(section("V-Carve",
      numberRow("Start depth", params.startDepth as number, u, (v) => set("startDepth", v)),
      numberRow("Flat depth", (params.flatDepth as number) ?? 0, u, (v) => set("flatDepth", v > 0 ? v : null)),
      numberRow("Max pass depth", (params.maxPassDepth as number) ?? 0, u, (v) => set("maxPassDepth", v > 0 ? v : null))),
      section("Order",
        toggleRow("Use vector start points", Boolean(params.useVectorStartPoints), (v) => set("useVectorStartPoints", v)),
        toggleRow("Use vector selection order", Boolean(params.useSelectionOrder), (v) => set("useSelectionOrder", v))));
  } else {
    // The other toolpaths: every plain setting the core's JSON holds, in its own order, labelled from its key.
    specific.push(depthSection, genericSection(kind, params, set), rampSection);
  }

  const warnings = Object.entries(st?.metadata ?? {}).filter(([k]) => k !== "pass");
  return [
    h("section", { class: "section" },
      h("h3", {}, `${kindTitles[kind] ?? kind} Toolpath`),
      h("input", { class: "text wide", value: setup.name, "aria-label": "Name", onchange: (e: Event) => void send(withSetup({ name: (e.target as HTMLInputElement).value })) }),
      toggleRow("Include in export", setup.isEnabled, (v) => void send(withSetup({ isEnabled: v }))),
      selectRow("Tool", setup.toolID, tools.map((t) => [t.id, `T${t.number} · ${t.name}`]), (v) => void send(withSetup({ toolID: v }))),
      tool ? h("p", { class: "muted small" }, toolSummary(tool)) : null,
      h("p", { class: "small" }, `${setup.shapeIDs.length} vector${setup.shapeIDs.length === 1 ? "" : "s"}`),
      h("div", { class: "button-row" },
        h("button", { class: "button", disabled: app.selection.size === 0, onclick: () => void send(withSetup({ shapeIDs: [...app.selection] })) }, `Use Current Selection (${app.selection.size})`),
        h("button", { class: "button", onclick: () => { app.selection = new Set(setup.shapeIDs); refresh(); } }, "Show"))),
    h("section", { class: "section" },
      h("div", { class: "button-row" },
        h("button", { class: "button primary", onclick: () => void busy("Calculating…", () => apply("calculate", { ids: [setup.id] })) }, "Calculate"),
        h("span", { class: "spacer" }),
        h("button", { class: "icon-button", title: "Delete toolpath", "aria-label": "Delete toolpath", onclick: () => void apply("deleteOperation", { id: setup.id }) }, icon(icons.trash, 16))),
      st?.error ? h("p", { class: "error-text" }, st.error) : null,
      st?.isCalculated && !st.error ? h("div", { class: "result" },
        h("p", { class: st.isStale ? "stale-text" : "good-text" }, `${st.toolpathCount} toolpath${st.toolpathCount === 1 ? "" : "s"}, ${st.moveCount.toLocaleString("en-US")} moves${st.isStale ? " (changed since)" : ""}`),
        h("p", { class: "muted small" }, `Estimated time: ${st.duration}`),
        warnings.map(([k, v]) => h("p", { class: k === "warning" ? "warn-text small" : "muted small" }, `${k}: ${v}`))) : null),
    specific,
  ];
}

function toolSummary(t: Tool) {
  return `⌀${t.diameter} ${unitLabel(t.units)} · ${t.spindleRPM} RPM · F${t.feedRate} / P${t.plungeRate} ${feedLabel(t.units)}`;
}

function title(key: string) {
  const words = key.replace(/([A-Z])/g, " $1").toLowerCase();
  return words.charAt(0).toUpperCase() + words.slice(1);
}

function genericSection(kind: string, params: Params, set: (k: string, v: unknown) => void) {
  const rows: Child[] = [];
  for (const [key, value] of Object.entries(params)) {
    if (key === "depth" || key === "ramp") continue;
    if (typeof value === "number") rows.push(numberRow(title(key), value, "", (v) => set(key, v)));
    else if (typeof value === "boolean") rows.push(toggleRow(title(key), value, (v) => set(key, v)));
  }
  return rows.length ? section(kindTitles[kind] ?? kind, rows) : null;
}
