import { h, icon, icons } from "./dom";
import type { Layer, Shape, Vec2 } from "./model";
import { flatten, opBody, shapeBounds, unitLabel } from "./model";
import { app, apply, doc, refresh, subscribe, units } from "./state";

/** The 2D design view: rulers, material, grid, vectors and toolpaths, as on the Mac. All edits go to the core. */
export function createCanvas(onTextTool: (at: Vec2) => void): HTMLElement {
  const canvas = h("canvas", { class: "design-canvas", tabindex: 0, "aria-label": "Design canvas" });
  const palette = h("div", { class: "tool-palette", role: "toolbar", "aria-label": "Drawing tools" });
  const host = h("div", { class: "canvas-host" }, canvas, palette);

  const tools: [string, string, string?][] = [
    ["select", "Select", "S"], ["|", ""], ["rectangle", "Rectangle", "R"], ["roundedRectangle", "Rounded Rectangle"], ["circle", "Circle", "C"], ["ellipse", "Ellipse", "E"],
    ["polygon", "Polygon", "P"], ["star", "Star"], ["|", ""], ["polyline", "Polyline", "L"], ["|", ""], ["text", "Text", "T"],
  ];
  const iconName = (t: string) => (t in icons ? t : "select") as keyof typeof icons;
  const buttons = new Map<string, HTMLElement>();
  for (const [t, title, key] of tools) {
    if (t === "|") { palette.appendChild(h("div", { class: "palette-sep" })); continue; }
    const b = h("button", { class: "tool-button", title: key ? `${title} (${key})` : title, "aria-label": title, "data-tool": t, onclick: () => setTool(t) }, icon(icons[iconName(t)]));
    buttons.set(t, b);
    palette.appendChild(b);
  }
  const setTool = (t: string) => { app.tool = t; polyline = []; refresh(); };

  // View: `scale` screen pixels to a document unit; `ox`, `oy` where document (0,0) lands on screen.
  const RULER = 22;
  let scale = 20, ox = 60, oy = 400, fitted = false;
  let width = 0, height = 0;
  const toScreen = (p: Vec2) => ({ x: ox + p.x * scale, y: oy - p.y * scale });
  const toDoc = (x: number, y: number): Vec2 => ({ x: (x - ox) / scale, y: (oy - y) / scale });

  function fit() {
    if (!app.state) return;
    const job = doc().job;
    const w = width - RULER - 120, h2 = height - RULER - 60;
    scale = Math.max(0.5, Math.min(w / job.width, h2 / job.height));
    ox = RULER + 90 + (w - job.width * scale) / 2;
    oy = RULER + 30 + (h2 + job.height * scale) / 2;
    fitted = true;
    draw();
  }
  host.addEventListener("loftline-fit", fit);

  type Drag =
    | { kind: "pan"; x: number; y: number; ox: number; oy: number }
    | { kind: "move"; start: Vec2; last: Vec2; moved: boolean }
    | { kind: "draw"; start: Vec2; last: Vec2 }
    | { kind: "box"; start: Vec2; last: Vec2 };
  let drag: Drag | null = null;
  let polyline: Vec2[] = [];
  let hover: Vec2 | null = null;

  const snap = (p: Vec2): Vec2 => {
    const g = doc().gridSpacing;
    if (!app.snapToGrid || !g) return p;
    return { x: Math.round(p.x / g) * g, y: Math.round(p.y / g) * g };
  };

  function visibleShapes(): Shape[] {
    const hidden = new Set(doc().layers.filter((l) => !l.isVisible).map((l) => l.id));
    return doc().shapes.filter((s) => !hidden.has(s.layerID));
  }

  function hit(p: Vec2): Shape | null {
    const tol = 6 / scale;
    let best: Shape | null = null, bestD = tol;
    for (const s of visibleShapes()) {
      for (const path of s.paths) {
        const pts = flatten(path, 0.5 / scale);
        for (let i = 1; i < pts.length; i++) {
          const d = distToSegment(p, pts[i - 1], pts[i]);
          if (d <= bestD) { bestD = d; best = s; }
        }
      }
    }
    if (best) return best;
    // Inside a closed vector counts too, smallest first, as a click on a filled letter should.
    let area = Infinity;
    for (const s of visibleShapes()) {
      const b = shapeBounds(s);
      if (p.x < b.minX || p.x > b.maxX || p.y < b.minY || p.y > b.maxY) continue;
      const a = (b.maxX - b.minX) * (b.maxY - b.minY);
      if (a < area && s.paths.some((q) => q.isClosed && pointInside(p, flatten(q, 1 / scale)))) { area = a; best = s; }
    }
    return best;
  }

  canvas.addEventListener("mousedown", (e) => {
    canvas.focus();
    const rect = canvas.getBoundingClientRect();
    const x = e.clientX - rect.left, y = e.clientY - rect.top;
    if (!app.state) return;
    if (e.button === 1 || e.altKey || spaceDown) { drag = { kind: "pan", x, y, ox, oy }; return; }
    const p = toDoc(x, y);
    switch (app.tool) {
      case "select": {
        const s = hit(p);
        if (s) {
          if (e.shiftKey) { app.selection.has(s.id) ? app.selection.delete(s.id) : app.selection.add(s.id); }
          else if (!app.selection.has(s.id)) { app.selection = new Set([s.id]); }
          drag = { kind: "move", start: snap(p), last: snap(p), moved: false };
        } else {
          if (!e.shiftKey) app.selection.clear();
          drag = { kind: "box", start: p, last: p };
        }
        refresh();
        break;
      }
      case "polyline": {
        const q = snap(p);
        if (e.detail >= 2 && polyline.length >= 2) { finishPolyline(); break; }
        polyline.push(q);
        draw();
        break;
      }
      case "text":
        onTextTool(snap(p));
        break;
      default: {
        const q = snap(p);
        drag = { kind: "draw", start: q, last: q };
      }
    }
  });

  function finishPolyline() {
    const points = polyline;
    polyline = [];
    if (points.length >= 2) void apply("addPolyline", { points });
    app.tool = "select";
    refresh();
  }

  window.addEventListener("mousemove", (e) => {
    const rect = canvas.getBoundingClientRect();
    const x = e.clientX - rect.left, y = e.clientY - rect.top;
    if (x >= 0 && y >= 0 && x <= rect.width && y <= rect.height && app.state) {
      hover = toDoc(x, y);
      host.dispatchEvent(new CustomEvent("loftline-cursor", { bubbles: true, detail: hover }));
    }
    if (!drag) { if (app.tool === "polyline" && polyline.length) draw(); return; }
    switch (drag.kind) {
      case "pan": ox = drag.ox + x - drag.x; oy = drag.oy + y - drag.y; break;
      case "move": {
        const q = snap(toDoc(x, y));
        if (q.x !== drag.start.x || q.y !== drag.start.y) drag.moved = true;
        drag.last = q;
        break;
      }
      case "draw": drag.last = snap(toDoc(x, y)); break;
      case "box": drag.last = toDoc(x, y); break;
    }
    draw();
  });

  window.addEventListener("mouseup", () => {
    const d = drag;
    drag = null;
    if (!d || !app.state) return;
    if (d.kind === "move" && d.moved) {
      const by = { x: d.last.x - d.start.x, y: d.last.y - d.start.y };
      void apply("translateShapes", { ids: [...app.selection], by });
    } else if (d.kind === "draw") {
      if (d.start.x !== d.last.x || d.start.y !== d.last.y) {
        const tool = app.tool;
        void apply("addShape", { tool, from: d.start, to: d.last }).then(() => {
          const shapes = doc().shapes;
          if (shapes.length) app.selection = new Set([shapes[shapes.length - 1].id]);
          app.tool = "select";
          refresh();
        });
      }
    } else if (d.kind === "box") {
      const minX = Math.min(d.start.x, d.last.x), maxX = Math.max(d.start.x, d.last.x);
      const minY = Math.min(d.start.y, d.last.y), maxY = Math.max(d.start.y, d.last.y);
      if (maxX - minX > 2 / scale || maxY - minY > 2 / scale) {
        for (const s of visibleShapes()) {
          const b = shapeBounds(s);
          if (b.minX >= minX && b.maxX <= maxX && b.minY >= minY && b.maxY <= maxY) app.selection.add(s.id);
        }
      }
      refresh();
    }
    draw();
  });

  canvas.addEventListener("wheel", (e) => {
    e.preventDefault();
    const rect = canvas.getBoundingClientRect();
    const x = e.clientX - rect.left, y = e.clientY - rect.top;
    if (e.ctrlKey || !e.shiftKey) {
      const before = toDoc(x, y);
      scale = Math.max(0.2, Math.min(5000, scale * Math.exp(-e.deltaY * 0.0015)));
      ox = x - before.x * scale;
      oy = y + before.y * scale;
    } else {
      ox -= e.deltaY;
    }
    draw();
  }, { passive: false });

  let spaceDown = false;
  window.addEventListener("keydown", (e) => {
    if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement || e.target instanceof HTMLSelectElement) return;
    if (e.code === "Space") { spaceDown = true; return; }
    if (e.key === "Escape") { polyline = []; if (app.tool !== "select") setTool("select"); else { app.selection.clear(); refresh(); } }
    if (e.key === "Enter" && app.tool === "polyline") finishPolyline();
    if ((e.key === "Delete" || e.key === "Backspace") && app.selection.size) void apply("deleteShapes", { ids: [...app.selection] });
    if (!e.ctrlKey && !e.metaKey && !e.altKey) {
      const shortcut = tools.find(([, , k]) => k?.toLowerCase() === e.key.toLowerCase());
      if (shortcut) setTool(shortcut[0]);
    }
  });
  window.addEventListener("keyup", (e) => { if (e.code === "Space") spaceDown = false; });

  const ctx = canvas.getContext("2d")!;
  const css = (name: string) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

  function niceStep(): number {
    const want = 60 / scale;
    const mag = 10 ** Math.floor(Math.log10(want));
    for (const m of [1, 2, 5, 10]) if (m * mag >= want) return m * mag;
    return 10 * mag;
  }

  function strokePath(points: Vec2[]) {
    ctx.beginPath();
    points.forEach((p, i) => {
      const s = toScreen(p);
      if (i === 0) ctx.moveTo(s.x, s.y);
      else ctx.lineTo(s.x, s.y);
    });
    ctx.stroke();
  }

  function draw() {
    const dpr = window.devicePixelRatio || 1;
    const rect = host.getBoundingClientRect();
    if (rect.width === 0) return;
    if (width !== rect.width || height !== rect.height) {
      width = rect.width; height = rect.height;
      canvas.width = Math.round(width * dpr);
      canvas.height = Math.round(height * dpr);
      canvas.style.width = `${width}px`;
      canvas.style.height = `${height}px`;
      if (!fitted) { fit(); return; }
    }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = css("--canvas-back");
    ctx.fillRect(0, 0, width, height);
    if (!app.state) return;
    const d = doc(), job = d.job;

    // Material.
    const a = toScreen({ x: 0, y: 0 }), b = toScreen({ x: job.width, y: job.height });
    ctx.save();
    ctx.shadowColor = "rgba(0,0,0,.28)"; ctx.shadowBlur = 8; ctx.shadowOffsetY = 2;
    ctx.fillStyle = css("--material");
    ctx.fillRect(a.x, b.y, b.x - a.x, a.y - b.y);
    ctx.restore();

    // Grid, inside the material: thinned until the lines are at least 8 px apart, with a stronger line at each ruler tick.
    if (d.gridSpacing > 0) {
      let step = d.gridSpacing;
      while (step * scale < 8) step *= 2;
      const major = niceStep();
      for (const [every, alpha] of [[step, 0.06], [major, 0.12]] as const) {
        ctx.beginPath();
        ctx.strokeStyle = `rgba(0,0,0,${alpha})`;
        ctx.lineWidth = 1;
        for (let n = 1; n * every < job.width; n++) { const s = Math.round(toScreen({ x: n * every, y: 0 }).x) + 0.5; ctx.moveTo(s, a.y); ctx.lineTo(s, b.y); }
        for (let n = 1; n * every < job.height; n++) { const s = Math.round(toScreen({ x: 0, y: n * every }).y) + 0.5; ctx.moveTo(a.x, s); ctx.lineTo(b.x, s); }
        ctx.stroke();
      }
    }

    // Origin marker.
    ctx.strokeStyle = "#e0392b"; ctx.lineWidth = 2;
    ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(a.x + 34, a.y); ctx.stroke();
    ctx.fillStyle = "#e0392b"; ctx.font = `11px ${UI_FONT}`; ctx.fillText("✕", a.x + 34, a.y + 4);

    // Vectors, in their layer's colour.
    const layers = new Map<string, Layer>(d.layers.map((l) => [l.id, l]));
    for (const s of visibleShapes()) {
      const selected = app.selection.has(s.id);
      ctx.strokeStyle = selected ? "#1f6feb" : layers.get(s.layerID)?.colorHex || "#000";
      ctx.lineWidth = selected ? 1.8 : 1.2;
      for (const p of s.paths) strokePath(flatten(p, 0.5 / scale));
    }

    // Toolpaths: feed green to deeper orange, rapids dashed red.
    if (app.showToolpaths && app.lines) {
      const selectedOp = app.selectedOp;
      for (const l of app.lines.lines) {
        if (l.operation && app.hiddenOps.has(l.operation)) continue;
        const pts: Vec2[] = [];
        for (let i = 0; i < l.points.length; i += 3) pts.push({ x: l.points[i], y: l.points[i + 1] });
        const color = l.isRapid ? "#d9534f" : colorFor(l.operation);
        ctx.strokeStyle = color;
        ctx.globalAlpha = selectedOp && l.operation !== selectedOp ? 0.35 : 0.95;
        ctx.lineWidth = l.isRapid ? 0.8 : 1;
        ctx.setLineDash(l.isRapid ? [5, 4] : []);
        strokePath(pts);
      }
      ctx.setLineDash([]);
      ctx.globalAlpha = 1;
    }

    // Selection box and handles.
    if (app.selection.size) {
      let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
      for (const s of d.shapes) {
        if (!app.selection.has(s.id)) continue;
        const r = shapeBounds(s);
        minX = Math.min(minX, r.minX); minY = Math.min(minY, r.minY); maxX = Math.max(maxX, r.maxX); maxY = Math.max(maxY, r.maxY);
      }
      if (minX < Infinity) {
        const p = toScreen({ x: minX, y: maxY }), q = toScreen({ x: maxX, y: minY });
        ctx.strokeStyle = "#1f6feb"; ctx.lineWidth = 1; ctx.setLineDash([5, 3]);
        ctx.strokeRect(p.x, p.y, q.x - p.x, q.y - p.y);
        ctx.setLineDash([]);
        ctx.fillStyle = "#fff";
        for (const [hx, hy] of [[p.x, p.y], [q.x, p.y], [p.x, q.y], [q.x, q.y], [(p.x + q.x) / 2, p.y], [(p.x + q.x) / 2, q.y], [p.x, (p.y + q.y) / 2], [q.x, (p.y + q.y) / 2]]) {
          ctx.fillRect(hx - 3.5, hy - 3.5, 7, 7);
          ctx.strokeRect(hx - 3.5, hy - 3.5, 7, 7);
        }
      }
    }

    // Gesture in progress.
    if (drag?.kind === "draw") {
      const s = toScreen(drag.start), e = toScreen(drag.last);
      ctx.strokeStyle = "#1f6feb"; ctx.lineWidth = 1;
      if (["circle", "polygon", "star"].includes(app.tool)) {
        ctx.beginPath(); ctx.arc(s.x, s.y, Math.hypot(e.x - s.x, e.y - s.y), 0, Math.PI * 2); ctx.stroke();
      } else {
        ctx.strokeRect(Math.min(s.x, e.x), Math.min(s.y, e.y), Math.abs(e.x - s.x), Math.abs(e.y - s.y));
      }
    } else if (drag?.kind === "box") {
      const s = toScreen(drag.start), e = toScreen(drag.last);
      ctx.fillStyle = "rgba(31,111,235,.12)"; ctx.strokeStyle = "#1f6feb"; ctx.lineWidth = 1;
      ctx.fillRect(s.x, s.y, e.x - s.x, e.y - s.y);
      ctx.strokeRect(s.x, s.y, e.x - s.x, e.y - s.y);
    } else if (drag?.kind === "move" && drag.moved) {
      const dx = drag.last.x - drag.start.x, dy = drag.last.y - drag.start.y;
      ctx.strokeStyle = "rgba(31,111,235,.65)"; ctx.lineWidth = 1;
      for (const s of d.shapes) {
        if (!app.selection.has(s.id)) continue;
        for (const p of s.paths) strokePath(flatten(p, 1 / scale).map((q) => ({ x: q.x + dx, y: q.y + dy })));
      }
    }
    if (polyline.length) {
      ctx.strokeStyle = "#1f6feb"; ctx.lineWidth = 1.2;
      strokePath(hover ? [...polyline, snap(hover)] : polyline);
    }

    drawRulers();
    for (const [t, el] of buttons) el.classList.toggle("active", t === app.tool);
  }

  function drawRulers() {
    ctx.fillStyle = css("--raised");
    ctx.fillRect(0, 0, width, RULER);
    ctx.fillRect(0, 0, RULER, height);
    ctx.strokeStyle = css("--hairline"); ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(RULER, RULER - 0.5); ctx.lineTo(width, RULER - 0.5); ctx.moveTo(RULER - 0.5, RULER); ctx.lineTo(RULER - 0.5, height); ctx.stroke();
    const step = niceStep();
    ctx.fillStyle = css("--muted"); ctx.strokeStyle = css("--muted"); ctx.font = `10px ${UI_FONT}`;
    ctx.textBaseline = "top";
    const left = toDoc(RULER, 0).x, right = toDoc(width, 0).x;
    ctx.beginPath();
    for (let v = Math.ceil(left / step) * step; v <= right; v += step) {
      const x = Math.round(toScreen({ x: v, y: 0 }).x) + 0.5;
      ctx.moveTo(x, 6); ctx.lineTo(x, RULER);
      ctx.fillText(formatTick(v), x + 3, 3);
      for (let m = 1; m < 5; m++) { const t = Math.round(toScreen({ x: v + (step * m) / 5, y: 0 }).x) + 0.5; ctx.moveTo(t, RULER - 5); ctx.lineTo(t, RULER); }
    }
    const top = toDoc(0, RULER).y, bottom = toDoc(0, height).y;
    for (let v = Math.ceil(bottom / step) * step; v <= top; v += step) {
      const y = Math.round(toScreen({ x: 0, y: v }).y) + 0.5;
      ctx.moveTo(6, y); ctx.lineTo(RULER, y);
      ctx.save(); ctx.translate(3, y - 3); ctx.rotate(-Math.PI / 2); ctx.fillText(formatTick(v), 0, 0); ctx.restore();
      for (let m = 1; m < 5; m++) { const t = Math.round(toScreen({ x: 0, y: v + (step * m) / 5 }).y) + 0.5; ctx.moveTo(RULER - 5, t); ctx.lineTo(RULER, t); }
    }
    ctx.stroke();
    ctx.fillStyle = css("--raised"); ctx.fillRect(0, 0, RULER, RULER);
    ctx.fillStyle = css("--muted"); ctx.fillText(unitLabel(units()), 4, 6);
    ctx.textBaseline = "alphabetic";
  }

  new ResizeObserver(() => draw()).observe(host);
  subscribe(draw);
  // The first reply fits the view once; the same for each opened file (a new design revision with no selection history).
  let lastPath: string | undefined | null = null;
  subscribe(() => {
    const p = app.state?.path;
    if (app.state && p !== lastPath) { lastPath = p; fit(); }
  });
  return host;
}

// A canvas font string cannot read a CSS variable.
const UI_FONT = 'system-ui, "Segoe UI", "Noto Sans", "Liberation Sans", sans-serif';

function formatTick(v: number): string {
  const r = Math.round(v * 1000) / 1000;
  return String(r === 0 ? 0 : r);
}

const palette = ["#3f8cff", "#3fbf5f", "#f0913a", "#b267e6", "#e0564f", "#2bb7b3", "#c9a227"];
export function colorFor(op?: string): string {
  if (!op || !app.state) return palette[0];
  const i = app.state.project.operations.findIndex((o) => opBody(o).setup.id === op);
  return palette[Math.max(0, i) % palette.length];
}

function distToSegment(p: Vec2, a: Vec2, b: Vec2): number {
  const dx = b.x - a.x, dy = b.y - a.y;
  const len = dx * dx + dy * dy;
  const t = len > 0 ? Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len)) : 0;
  return Math.hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy));
}

function pointInside(p: Vec2, poly: Vec2[]): boolean {
  let inside = false;
  for (let i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    if (poly[i].y > p.y !== poly[j].y > p.y && p.x < ((poly[j].x - poly[i].x) * (p.y - poly[i].y)) / (poly[j].y - poly[i].y) + poly[i].x) inside = !inside;
  }
  return inside;
}
