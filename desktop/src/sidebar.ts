import { h, icon, icons, replace } from "./dom";
import type { Layer, Operation } from "./model";
import { kindTitles, opBody, opKind, shapeBounds } from "./model";
import { colorFor } from "./canvas";
import { app, apply, busy, doc, project, refresh, status, subscribe } from "./state";
import { openExport, openValidation } from "./sheets";

/** The left column: Design (layers and vectors) and Toolpaths, with the same two tabs as the Mac. */
export function createSidebar(): HTMLElement {
  const root = h("aside", { class: "sidebar" });
  const render = () => {
    if (!app.state) return;
    replace(root, tabs(), app.tab === "design" ? design() : toolpaths());
  };
  subscribe(render);
  return root;
}

function tabs() {
  const tab = (id: "design" | "toolpaths", title: string) =>
    h("button", { class: `segment ${app.tab === id ? "on" : ""}`, role: "tab", "aria-selected": app.tab === id ? "true" : "false", onclick: () => { app.tab = id; refresh(); } }, title);
  return h("div", { class: "segments sidebar-tabs", role: "tablist" }, tab("design", "Design"), tab("toolpaths", "Toolpaths"));
}

function design() {
  const d = doc();
  const addLayer = h("button", { class: "link-button", onclick: () => void apply("addLayer", {}) }, icon(icons.plus, 14), " New Layer");
  const rows = d.layers.map((layer) => layerRow(layer));
  const list = d.shapes.length === 0
    ? h("p", { class: "empty" }, "Draw with the tools on the canvas, or use File > Import.")
    : null;
  return h("div", { class: "sidebar-body" },
    h("div", { class: "sidebar-head" }, h("h2", {}, "Layers"), addLayer),
    h("div", { class: "layer-list" }, rows), list);
}

function layerRow(layer: Layer) {
  const shapes = doc().shapes.filter((s) => s.layerID === layer.id);
  const edit = (change: Partial<Layer>) => void apply("updateLayer", { layer: { ...layer, ...change } });
  return h("div", { class: "layer" },
    h("div", { class: "layer-row" },
      h("input", { type: "checkbox", checked: layer.isVisible, "aria-label": `Show ${layer.name}`, title: "Visible", onchange: (e: Event) => edit({ isVisible: (e.target as HTMLInputElement).checked }) }),
      h("input", { type: "color", class: "swatch", value: layer.colorHex, title: "Colour", "aria-label": `${layer.name} colour`, onchange: (e: Event) => edit({ colorHex: (e.target as HTMLInputElement).value }) }),
      h("input", { class: "layer-name", value: layer.name, "aria-label": "Layer name", onchange: (e: Event) => edit({ name: (e.target as HTMLInputElement).value }) }),
      h("span", { class: "count" }, shapes.length),
      doc().layers.length > 1 ? h("button", { class: "icon-button", title: "Delete layer", "aria-label": `Delete ${layer.name}`, onclick: () => void apply("deleteLayer", { id: layer.id }) }, icon(icons.trash, 14)) : null),
    h("ul", { class: "shape-list" }, shapes.map((s) => {
      const b = shapeBounds(s);
      const size = isFinite(b.minX) ? `${round(b.maxX - b.minX)} × ${round(b.maxY - b.minY)}` : "";
      return h("li", {
        class: app.selection.has(s.id) ? "on" : "",
        onclick: (e: MouseEvent) => {
          if (e.shiftKey) { app.selection.has(s.id) ? app.selection.delete(s.id) : app.selection.add(s.id); } else app.selection = new Set([s.id]);
          refresh();
        },
      }, h("span", { class: "shape-name" }, s.name || "Vector"), h("span", { class: "shape-size" }, size));
    })));
}

const round = (v: number) => Math.round(v * 1000) / 1000;

const newToolpathKinds = ["profile", "pocket", "drill", "vcarve", "engrave", "chamfer", "holeMill", "prism", "facing", "fluting", "texture", "moulding", "relief3D"];

function toolpaths() {
  const ops = project().operations;
  const menu = h("select", {
    class: "new-toolpath", "aria-label": "New Toolpath",
    onchange: async (e: Event) => {
      const select = e.target as HTMLSelectElement;
      const kind = select.value;
      select.value = "";
      if (!kind) return;
      const before = new Set(project().operations.map((o) => opBody(o).setup.id));
      if (await apply("addOperation", { kind, shapeIDs: [...app.selection] })) {
        const added = project().operations.find((o) => !before.has(opBody(o).setup.id));
        if (added) app.selectedOp = opBody(added).setup.id;
        refresh();
      }
    },
  },
    h("option", { value: "" }, "+ New Toolpath"),
    newToolpathKinds.map((k) => h("option", { value: k }, kindTitles[k])));
  const showAll = h("button", {
    class: `icon-toggle ${app.showToolpaths ? "on" : ""}`, title: "Show toolpaths in 2D", "aria-label": "Show toolpaths", "aria-pressed": app.showToolpaths ? "true" : "false",
    onclick: () => { app.showToolpaths = !app.showToolpaths; refresh(); },
  }, icon(icons.eye, 16));

  const list = ops.length === 0
    ? h("p", { class: "empty" }, "Select vectors, then add a toolpath.")
    : h("ul", { class: "op-list" }, ops.map((op, i) => opRow(op, i)));

  const job = app.state!.job;

  return h("div", { class: "sidebar-body" },
    h("div", { class: "sidebar-head" }, menu, showAll),
    list,
    h("div", { class: "sidebar-foot" },
      h("div", { class: "foot-row" },
        h("button", { class: "button", disabled: ops.length === 0, onclick: () => void busy("Calculating…", () => apply("calculate", {})) }, "Calculate All"),
        h("span", { class: "spacer" }),
        h("button", { class: "button icon-only", title: "Check Toolpaths", "aria-label": "Check Toolpaths", disabled: ops.length === 0, onclick: () => openValidation() }, icon(icons.shield, 16)),
        h("button", { class: "button", disabled: ops.length === 0, onclick: () => openExport(null) }, "Save All…")),
      h("div", { class: "foot-row small" },
        h("strong", {}, job.hasEstimate ? `Estimated time: ${job.duration}` : "Not calculated"),
        h("span", { class: "spacer" }),
        h("span", { class: "muted" }, `${job.toolLoads} tool${job.toolLoads === 1 ? "" : "s"} · ${job.toolChanges} change${job.toolChanges === 1 ? "" : "s"}`)),
      job.sequence.length > 1 ? h("details", { class: "small" }, h("summary", {}, "Tool changes"), h("ol", { class: "tool-sequence" }, job.sequence.map((t) => h("li", {}, t)))) : null));
}

export function formatDuration(seconds: number): string {
  const s = Math.round(seconds);
  const hh = Math.floor(s / 3600), mm = Math.floor((s % 3600) / 60), ss = s % 60;
  if (hh > 0) return `${hh}h ${String(mm).padStart(2, "0")}m ${String(ss).padStart(2, "0")}s`;
  if (mm > 0) return `${mm}m ${String(ss).padStart(2, "0")}s`;
  return `${ss}s`;
}

function opRow(op: Operation, index: number) {
  const { setup } = opBody(op);
  const st = status(setup.id);
  const tool = project().tools.find((t) => t.id === setup.toolID);
  const mark = !st?.isCalculated ? null
    : st.error ? h("span", { class: "dot bad", title: st.error }, "!")
    : st.isStale ? h("span", { class: "dot stale", title: "Changed since it was calculated" }, "•")
    : h("span", { class: "dot good", title: "Calculated" }, icon(icons.check, 11));
  return h("li", {
    class: app.selectedOp === setup.id ? "on" : "",
    onclick: () => { app.selectedOp = setup.id; refresh(); },
  },
    h("input", { type: "checkbox", checked: setup.isEnabled, "aria-label": `Include ${setup.name} in export`, onclick: (e: Event) => e.stopPropagation(), onchange: (e: Event) => void apply("enableOperation", { id: setup.id, enabled: (e.target as HTMLInputElement).checked }) }),
    h("button", {
      class: `icon-button ${app.hiddenOps.has(setup.id) ? "off" : ""}`, title: "Show in views", "aria-label": `Show ${setup.name}`,
      onclick: (e: Event) => { e.stopPropagation(); app.hiddenOps.has(setup.id) ? app.hiddenOps.delete(setup.id) : app.hiddenOps.add(setup.id); refresh(); },
    }, icon(icons.eye, 15)),
    h("span", { class: "op-color", style: `background:${colorFor(setup.id)}` }),
    h("span", { class: "op-text" },
      h("span", { class: "op-name" }, setup.name),
      h("span", { class: "op-detail" }, `${kindTitles[opKind(op)] ?? opKind(op)}${tool ? ` · T${tool.number}` : ""}`)),
    st?.isCalculated && !st.error ? h("span", { class: "op-time" }, st.duration) : null,
    h("span", { class: "op-order" },
      index > 0 ? h("button", { class: "icon-button tiny", title: "Move up", "aria-label": `Move ${setup.name} up`, onclick: (e: Event) => { e.stopPropagation(); void apply("moveOperation", { id: setup.id, delta: -1 }); } }, icon(icons.up, 11)) : null,
      index < project().operations.length - 1 ? h("button", { class: "icon-button tiny", title: "Move down", "aria-label": `Move ${setup.name} down`, onclick: (e: Event) => { e.stopPropagation(); void apply("moveOperation", { id: setup.id, delta: 1 }); } }, icon(icons.down, 11)) : null),
    mark);
}
