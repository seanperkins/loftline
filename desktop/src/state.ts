import { call, CoreError, StaleError } from "./core";
import type { Lines, Operation, State } from "./model";
import { opBody } from "./model";

export type CenterMode = "2d" | "split" | "3d";
export type Tab = "design" | "toolpaths";

/** What the window shows. The project itself lives in the core; `state` is its last reply. */
export const app = {
  state: null as State | null,
  selection: new Set<string>(),
  selectedOp: null as string | null,
  tab: "design" as Tab,
  center: "2d" as CenterMode,
  tool: "select",
  showToolpaths: true,
  snapToGrid: true,
  showInspector: true,
  hiddenOps: new Set<string>(),
  lines: null as Lines | null,
  busy: null as string | null,
};

type Listener = () => void;
const listeners = new Set<Listener>();
export const subscribe = (l: Listener) => listeners.add(l);
export const refresh = () => listeners.forEach((l) => l());

export const project = () => app.state!.project;
export const doc = () => app.state!.project.document;
export const units = () => doc().units;
export const operation = (id: string | null): Operation | undefined => app.state!.project.operations.find((o) => opBody(o).setup.id === id);
export const status = (id: string) => app.state!.statuses.find((s) => s.id === id);

/** Whether "Let assistants edit open documents" is on: the window polls the core's assistant status only then. */
export let liveLink = false;
export const setLiveLink = (on: boolean) => { liveLink = on; };

/** Set by sheets.ts: errors are shown, never swallowed. */
export let showError: (title: string, message: string) => void = (t, m) => console.error(t, m);
export const setErrorHandler = (f: typeof showError) => { showError = f; };

/** A change to the project. It carries the change revision the window was drawn from, so one built on a view an assistant has
 *  since changed is refused rather than undoing the assistant's work; the window then refetches and says so. */
/** `rev`: the revision the change was built from, when that is older than the window's (a form opened earlier). */
export async function apply(method: string, params: unknown = {}, rev?: number): Promise<boolean> {
  try {
    const next = await call<State>(method, params, method === "state" ? undefined : rev ?? app.state?.changeRevision);
    setState(next);
    return true;
  } catch (e) {
    if (e instanceof StaleError) {
      setState(await call<State>("state"));
      showError("LoftLine", e.message);
      return false;
    }
    showError("LoftLine", e instanceof CoreError || e instanceof Error ? e.message : String(e));
    return false;
  }
}

export function setState(next: State) {
  app.state = next;
  const shapes = new Set(next.project.document.shapes.map((s) => s.id));
  for (const id of [...app.selection]) if (!shapes.has(id)) app.selection.delete(id);
  if (app.selectedOp && !next.project.operations.some((o) => opBody(o).setup.id === app.selectedOp)) app.selectedOp = null;
  refresh();
  void reloadLines();
}

/** The calculated toolpaths' lines, for the 2D and 3D views. They come from the core's own motion code. */
export async function reloadLines() {
  try {
    app.lines = await call<Lines>("toolpathLines", {});
    refresh();
  } catch {
    app.lines = null;
  }
}

export async function busy<T>(label: string, work: () => Promise<T>): Promise<T> {
  app.busy = label;
  refresh();
  try {
    return await work();
  } finally {
    app.busy = null;
    refresh();
  }
}
