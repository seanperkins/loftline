// The only way to the Swift core. In the Tauri shell a request goes through the Rust command; in a plain browser (headless checks,
// tools/serve.mjs) through POST /core. Every program, toolpath and edit comes back from the core: nothing here computes them.
let nextID = 1;

declare global {
  interface Window { __TAURI_INTERNALS__?: { invoke(cmd: string, args?: unknown): Promise<unknown> } }
}

export const inShell = () => typeof window.__TAURI_INTERNALS__ !== "undefined";

async function send(line: string): Promise<string> {
  const shell = window.__TAURI_INTERNALS__;
  if (shell) return (await shell.invoke("core_call", { request: line })) as string;
  const response = await fetch("/core", { method: "POST", body: line });
  return response.text();
}

export class CoreError extends Error {}
/** The core refused a change built on a view older than the project: an assistant changed it since (spec 2). */
export class StaleError extends CoreError {}

// One at a time, like the core itself: a reply always answers the request before it.
let queue: Promise<unknown> = Promise.resolve();

/** `rev`: the change revision the request was built from, on requests that change the project (state.ts `apply`). */
export function call<T>(method: string, params: unknown = {}, rev?: number): Promise<T> {
  const id = nextID++;
  const run = async (): Promise<T> => {
    const raw = await send(JSON.stringify(rev === undefined ? { id, method, params } : { id, method, params, rev }));
    let reply: { id?: number; result?: T; error?: string; code?: string };
    try {
      reply = JSON.parse(raw);
    } catch {
      throw new CoreError("The core sent a reply that can't be read.");
    }
    if (reply.error !== undefined) throw reply.code === "stale" ? new StaleError(reply.error) : new CoreError(reply.error);
    if (reply.id !== id) throw new CoreError("The core's reply doesn't match the request.");
    return reply.result as T;
  };
  const result = queue.then(run, run);
  queue = result.catch(() => undefined);
  return result;
}
