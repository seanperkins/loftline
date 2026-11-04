type Attrs = Record<string, string | number | boolean | ((e: never) => void) | undefined | null>;
export type Child = Node | string | number | null | undefined | false | Child[];

/** A small element builder: `on…` attributes are listeners, and booleans set or drop the attribute. */
export function h<K extends keyof HTMLElementTagNameMap>(tag: K, attrs: Attrs = {}, ...children: Child[]): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v === undefined || v === null || v === false) continue;
    if (k.startsWith("on") && typeof v === "function") el.addEventListener(k.slice(2).toLowerCase(), v as EventListener);
    else if (k === "class") el.className = String(v);
    else if (k === "value") (el as unknown as HTMLInputElement).value = String(v);
    else if (k === "checked") (el as unknown as HTMLInputElement).checked = Boolean(v);
    else el.setAttribute(k, v === true ? "" : String(v));
  }
  append(el, children);
  return el;
}

function append(el: Node, children: Child[]) {
  for (const c of children) {
    if (c === null || c === undefined || c === false) continue;
    if (Array.isArray(c)) append(el, c);
    else el.appendChild(c instanceof Node ? c : document.createTextNode(String(c)));
  }
}

export function replace(el: Element, ...children: Child[]) {
  el.textContent = "";
  append(el, children);
}

/** Inline icon from an SVG path, drawn in the current text colour. */
export function icon(d: string, size = 18): SVGSVGElement {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("width", String(size));
  svg.setAttribute("height", String(size));
  svg.setAttribute("fill", "none");
  svg.setAttribute("stroke", "currentColor");
  svg.setAttribute("stroke-width", "1.7");
  svg.setAttribute("stroke-linecap", "round");
  svg.setAttribute("stroke-linejoin", "round");
  const p = document.createElementNS("http://www.w3.org/2000/svg", "path");
  p.setAttribute("d", d);
  svg.appendChild(p);
  return svg;
}

export const icons = {
  select: "M5 3l6 17 2.5-7 7-2.5z",
  node: "M5 19c4 0 3-14 8-14M4 17h3v3H4zM17 4h3v3h-3zM13 5h4",
  rectangle: "M4 6h16v12H4z",
  roundedRectangle: "M8 6h8a4 4 0 0 1 4 4v4a4 4 0 0 1-4 4H8a4 4 0 0 1-4-4v-4a4 4 0 0 1 4-4z",
  circle: "M12 4a8 8 0 1 0 0 16 8 8 0 0 0 0-16z",
  ellipse: "M12 6c5 0 9 2.7 9 6s-4 6-9 6-9-2.7-9-6 4-6 9-6z",
  polygon: "M12 3l8 4.5v9L12 21l-8-4.5v-9z",
  star: "M12 3l2.7 5.8 6.3.8-4.6 4.3 1.2 6.3L12 17l-5.6 3.2 1.2-6.3L3 9.6l6.3-.8z",
  polyline: "M4 19l6-11 5 7 5-10",
  text: "M5 19L10 5l5 14M7 14h6M16 19v-6M16 13c2.5-1.5 4 0 4 1.5V19M20 16c-3-.5-4 .5-4 1.5s2 2.5 4 0",
  measure: "M3 9h18v6H3zM7 9v3M11 9v3M15 9v3M19 9v3",
  fit: "M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5",
  grid: "M9 3v18M15 3v18M3 9h18M3 15h18",
  tools: "M14 7l3-3 3 3-3 3M17 10l-8 8-4 1 1-4 8-8M4 4l6 6M14 14l6 6",
  play: "M7 4l13 8-13 8z",
  pause: "M8 5v14M16 5v14",
  export: "M12 15V3M8 7l4-4 4 4M5 13v7h14v-7",
  inspector: "M4 5h16v14H4zM15 5v14",
  eye: "M2 12s4-7 10-7 10 7 10 7-4 7-10 7-10-7-10-7zM12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6z",
  plus: "M12 5v14M5 12h14",
  trash: "M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13",
  check: "M4 12l5 5L20 6",
  warning: "M12 3L2 20h20zM12 10v4M12 17v.5",
  start: "M6 5v14M19 5l-9 7 9 7z",
  end: "M18 5v14M5 5l9 7-9 7z",
  stepBack: "M6 5v14M18 5l-9 7 9 7z",
  stepForward: "M18 5v14M6 5l9 7-9 7z",
  retract: "M12 21V7M7 12l5-5 5 5M5 3h14",
  shield: "M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z",
  up: "M12 19V5M6 11l6-6 6 6",
  down: "M12 5v14M6 13l6 6 6-6",
};
