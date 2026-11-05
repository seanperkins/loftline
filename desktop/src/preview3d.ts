import * as THREE from "three";
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js";
import { call } from "./core";
import { h, icon, icons, replace } from "./dom";
import { opBody } from "./model";
import { colorFor } from "./canvas";
import { app, showError, subscribe } from "./state";
import { formatDuration } from "./sidebar";

interface Summary { totalTime: number; duration: string; job: { width: number; height: number; thickness: number }; toolpaths: { name: string; diameter: number; moves: number }[] }
interface Frame { positions: string; normals: string; colors: string; indices: string; tip?: [number, number, number]; toolpathIndex?: number; time: number }

const decode = (s: string): ArrayBuffer => {
  const bin = atob(s);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes.buffer;
};

/** The 3D preview: the core's material-removal simulation and mesh, drawn with three.js instead of SceneKit. */
export function createPreview(): HTMLElement {
  const view = h("div", { class: "preview-view" });
  const overlay = h("div", { class: "preview-overlay" });
  const controls = h("div", { class: "preview-controls" });
  const root = h("div", { class: "preview" }, h("div", { class: "preview-stage" }, view, overlay), controls);

  // No WebGL (a virtual machine, a remote desktop, an old driver) must not take the rest of the app with it.
  let renderer: THREE.WebGLRenderer;
  try {
    renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: true });
  } catch {
    replace(view, h("p", { class: "no-webgl" }, "The 3D preview needs WebGL, which this computer's graphics driver doesn't offer. Everything else works."));
    return root;
  }
  renderer.setClearColor(0x292929);
  view.appendChild(renderer.domElement);
  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(40, 1, 0.01, 10000);
  camera.up.set(0, 0, 1);
  const orbit = new OrbitControls(camera, renderer.domElement);
  orbit.enableDamping = false;
  scene.add(new THREE.AmbientLight(0xffffff, 0.75));
  const key = new THREE.DirectionalLight(0xffffff, 1.5); key.position.set(-1, -1, 3); scene.add(key);
  const fill = new THREE.DirectionalLight(0xffffff, 0.5); fill.position.set(2, 1, 1); scene.add(fill);

  const stock = new THREE.Mesh(new THREE.BufferGeometry(), new THREE.MeshPhongMaterial({ vertexColors: true, shininess: 12, side: THREE.DoubleSide }));
  scene.add(stock);
  const toolMark = new THREE.Mesh(new THREE.ConeGeometry(0.5, 1, 20), new THREE.MeshPhongMaterial({ color: 0xc0c4cc }));
  toolMark.rotation.x = -Math.PI / 2;
  toolMark.visible = false;
  scene.add(toolMark);
  const lines = new THREE.Group();
  scene.add(lines);

  const draw = () => renderer.render(scene, camera);
  orbit.addEventListener("change", draw);
  const resize = () => {
    const r = view.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) return;
    renderer.setPixelRatio(window.devicePixelRatio || 1);
    renderer.setSize(r.width, r.height, false);
    renderer.domElement.style.width = `${r.width}px`;
    renderer.domElement.style.height = `${r.height}px`;
    camera.aspect = r.width / r.height;
    camera.updateProjectionMatrix();
    draw();
  };
  new ResizeObserver(resize).observe(view);

  let summary: Summary | null = null;
  let time = 0, playing = false, seeking = false, pending: number | null = null;
  let revision = -1, sign = "";
  let showTool = true, showLines = true, speed = 20;

  const fitCamera = (s: Summary) => {
    const { width, height, thickness } = s.job;
    const size = Math.max(width, height);
    orbit.target.set(width / 2, height / 2, -thickness / 2);
    // Far enough that the whole sheet fits in this view's width and height, from the Mac's three-quarter angle.
    const tan = Math.tan((camera.fov * Math.PI) / 360);
    const distance = Math.max(height * 0.75 / tan, width * 0.56 / (tan * Math.max(camera.aspect, 0.2)));
    camera.position.set(width / 2, height / 2 - distance * 0.72, distance * 0.69);
    camera.near = size / 500; camera.far = size * 50;
    camera.updateProjectionMatrix();
    orbit.update();
    toolMark.scale.setScalar(Math.max(size / 40, 0.01));
  };

  const updateLines = () => {
    lines.clear();
    if (!showLines || !app.lines) { draw(); return; }
    for (const l of app.lines.lines) {
      if (l.operation && app.hiddenOps.has(l.operation)) continue;
      const geometry = new THREE.BufferGeometry();
      geometry.setAttribute("position", new THREE.Float32BufferAttribute(l.points, 3));
      const material = l.isRapid
        ? new THREE.LineDashedMaterial({ color: 0xd9534f, dashSize: 0.2, gapSize: 0.15, transparent: true, opacity: 0.55 })
        : new THREE.LineBasicMaterial({ color: new THREE.Color(colorFor(l.operation)), transparent: true, opacity: 0.8 });
      const line = new THREE.Line(geometry, material);
      if (l.isRapid) line.computeLineDistances();
      lines.add(line);
    }
    draw();
  };

  async function seek(t: number, detail = 60_000) {
    if (seeking) { pending = t; return; }
    seeking = true;
    try {
      const frame = await call<Frame>("simSeek", { time: t, maxVertices: detail });
      time = t;
      const g = stock.geometry;
      g.setAttribute("position", new THREE.BufferAttribute(new Float32Array(decode(frame.positions)), 3));
      g.setAttribute("normal", new THREE.BufferAttribute(new Float32Array(decode(frame.normals)), 3));
      g.setAttribute("color", new THREE.BufferAttribute(new Float32Array(decode(frame.colors)), 3));
      g.setIndex(new THREE.BufferAttribute(new Uint32Array(decode(frame.indices)), 1));
      g.computeBoundingSphere();
      toolMark.visible = showTool && !!frame.tip && t < (summary?.totalTime ?? 0);
      if (frame.tip) toolMark.position.set(frame.tip[0], frame.tip[1], frame.tip[2] + toolMark.scale.y / 2);
      renderControls(frame);
      draw();
    } catch (e) {
      showError("Preview", e instanceof Error ? e.message : String(e));
      playing = false;
    } finally {
      seeking = false;
      if (pending !== null) { const n = pending; pending = null; void seek(n, detail); }
    }
  }

  let playStart = 0, playFrom = 0;
  function tick(now: number) {
    if (!playing || !summary) return;
    const total = summary.totalTime;
    const rate = total / Math.max(speed, 1);
    const t = Math.min(total, playFrom + ((now - playStart) / 1000) * rate);
    if (!seeking) void seek(t, 40_000);
    if (t >= total) { playing = false; void seek(total, 160_000); return; }
    requestAnimationFrame(tick);
  }
  const play = () => {
    if (!summary) return;
    if (time >= summary.totalTime) time = 0;
    playing = true; playFrom = time; playStart = performance.now();
    requestAnimationFrame(tick);
    renderControls(null);
  };
  const pause = () => { playing = false; void seek(time, 160_000); };

  function renderControls(frame: Frame | null) {
    if (!summary) { replace(controls, h("p", { class: "muted small pad" }, app.busy ?? "Calculate toolpaths to preview the cut.")); return; }
    const total = summary.totalTime;
    const name = frame?.toolpathIndex !== undefined ? summary.toolpaths[frame.toolpathIndex]?.name : undefined;
    replace(overlay, h("div", { class: "hud" },
      name ? h("strong", {}, name) : null,
      h("div", {}, `Estimated time ${formatDuration(total)}`),
      h("div", {}, `${summary.toolpaths.length} toolpath${summary.toolpaths.length === 1 ? "" : "s"}`)));
    replace(controls,
      h("div", { class: "control-row" },
        h("button", { class: "button icon-only", title: "To start", "aria-label": "To start", onclick: () => { playing = false; void seek(0, 160_000); } }, icon(icons.start, 15)),
        h("button", { class: "button icon-only", title: playing ? "Pause" : "Play", "aria-label": playing ? "Pause" : "Play", onclick: () => { playing ? pause() : play(); } }, icon(playing ? icons.pause : icons.play, 15)),
        h("button", { class: "button icon-only", title: "To end", "aria-label": "To end", onclick: () => { playing = false; void seek(total, 160_000); } }, icon(icons.end, 15))),
      h("div", { class: "control-row" },
        h("input", {
          class: "scrub", type: "range", min: 0, max: Math.max(total, 0.001), step: "any", value: time, "aria-label": "Simulation time",
          oninput: (e: Event) => { playing = false; void seek(Number((e.target as HTMLInputElement).value), 40_000); },
          onchange: (e: Event) => void seek(Number((e.target as HTMLInputElement).value), 160_000),
        }),
        h("span", { class: "muted small nowrap" }, `${formatDuration(time)} / ${formatDuration(total)}`),
        h("select", { class: "select compact", "aria-label": "Speed", onchange: (e: Event) => { speed = Number((e.target as HTMLSelectElement).value); if (playing) play(); } },
          [[60, "Fit (60 s)"], [20, "Fit (20 s)"], [5, "Fit (5 s)"]].map(([v, t]) => h("option", { value: v, ...(v === speed ? { selected: true } : {}) }, t)))),
      h("div", { class: "control-row" },
        h("label", { class: "row toggle compact" }, h("input", { type: "checkbox", checked: showTool, onchange: (e: Event) => { showTool = (e.target as HTMLInputElement).checked; toolMark.visible = showTool && time < total; draw(); } }), "Tool"),
        h("label", { class: "row toggle compact" }, h("input", { type: "checkbox", checked: showLines, onchange: (e: Event) => { showLines = (e.target as HTMLInputElement).checked; updateLines(); } }), "Toolpaths")));
  }

  async function restart() {
    if (!app.state) return;
    const anyCalculated = app.state.statuses.some((s) => s.isCalculated && !s.error);
    const enabled = app.state.project.operations.some((o) => opBody(o).setup.isEnabled);
    if (!anyCalculated && !enabled) { summary = null; renderControls(null); return; }
    summary = await call<Summary>("simStart", {});
    resize();
    fitCamera(summary);
    time = summary.totalTime;
    await seek(time, 160_000);
    updateLines();
  }

  subscribe(() => {
    if (!app.state || app.center === "2d") return;
    const nextSign = JSON.stringify([app.state.designRevision, app.state.side, app.state.statuses.map((s) => [s.id, s.isCalculated, s.isStale, s.moveCount]), app.state.project.operations.map((o) => opBody(o).setup.isEnabled)]);
    if (nextSign !== sign || revision < 0) {
      sign = nextSign; revision = app.state.designRevision;
      void restart().catch((e) => showError("Preview", e instanceof Error ? e.message : String(e)));
    }
    updateLines();
    resize();
  });
  return root;
}
