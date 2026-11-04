// Drives the built front end end to end against a real loftline-core, by the same mouse and menu routes a person uses, and checks the
// program it writes is byte for byte the one the command line writes. Run tools/serve.mjs first.
// Usage: node tools/e2e.mjs <loftline-cli> [base url]
import { execFileSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const cli = resolve(process.argv[2]);
const base = process.argv[3] ?? "http://localhost:5174";
const root = fileURLToPath(new URL("../..", import.meta.url));
const sample = join(root, "samples/sign.loftline");
const work = mkdtempSync(join(tmpdir(), "loftline-e2e-"));
let failed = 0;
const check = (ok, what) => { console.log(`${ok ? "ok  " : "FAIL"} ${what}`); if (!ok) failed++; };

// The front end must not be able to make a program: no G-code words in its source.
for (const f of readdirSync(join(root, "desktop/src")).filter((n) => n.endsWith(".ts"))) {
  const text = readFileSync(join(root, "desktop/src", f), "utf8");
  check(!/\bG0?[0-3]\s*[XYZF]|\bM0?[36]\s*[ST]|\bG(20|21|90|91)\b/.test(text), `no program text in desktop/src/${f}`);
}

const browser = await chromium.launch({ args: ["--use-gl=swiftshader", "--enable-webgl", "--ignore-gpu-blocklist", "--enable-unsafe-swiftshader"] });
const page = await (await browser.newContext({ viewport: { width: 1440, height: 900 } })).newPage();
const errors = [];
page.on("pageerror", (e) => errors.push(e.message));
const state = () => page.evaluate(() => window.loftline.app.state);
const menu = async (title, item) => {
  await page.locator(".menu-title", { hasText: new RegExp(`^${title}$`) }).click();
  await page.locator(".menu.open .menu-item", { hasText: item }).first().click();
};
const typePath = async (path) => {
  await page.getByRole("textbox", { name: "Path", exact: true }).fill(path);
  await page.getByRole("button", { name: "OK" }).click();
};
await page.goto(base);
await page.waitForFunction(() => window.loftline?.app.state);

// A new project (directly: the core may hold an earlier run's): draw by mouse, undo and redo.
await page.evaluate(() => window.loftline.apply("new"));
const canvas = page.locator(".design-canvas");
const box = await canvas.boundingBox();
await page.locator('[data-tool="rectangle"]').click();
await page.mouse.move(box.x + 500, box.y + 300);
await page.mouse.down();
await page.mouse.move(box.x + 700, box.y + 450, { steps: 4 });
await page.mouse.up();
await page.waitForFunction(() => window.loftline.app.state.project.document.shapes.length === 1);
check(true, "a rectangle drawn with the mouse reaches the core");
check((await state()).isDirty, "the project is dirty after an edit");
await menu("Edit", /^Undo/);
await page.waitForFunction(() => window.loftline.app.state.project.document.shapes.length === 0);
check(true, "undo");
await menu("Edit", /^Redo/);
await page.waitForFunction(() => window.loftline.app.state.project.document.shapes.length === 1);
check(true, "redo");

// A menu command through the core, and a toolpath on what was drawn.
await page.mouse.click(box.x + 600, box.y + 375);
await page.waitForFunction(() => window.loftline.app.selection.size === 1);
await menu("Design", /^Rotate 90° Left/);
await page.waitForFunction(() => window.loftline.app.state.undoAction === "Rotate");
check(true, "a Design menu command");
await page.getByRole("tab", { name: "Toolpaths" }).click();
await page.getByLabel("New Toolpath").selectOption("profile");
await page.waitForFunction(() => window.loftline.app.state.project.operations.length === 1);
await page.getByRole("button", { name: "Calculate", exact: true }).click();
await page.waitForFunction(() => window.loftline.app.state.statuses[0]?.isCalculated);
const st = (await state()).statuses[0];
check(!st.error && st.moveCount > 0, `Calculate: ${st.moveCount} moves`);

// Save, reopen: the same project.
const saved = join(work, "drawn.loftline");
await menu("File", /^Save As/);
await typePath(saved);
await page.waitForFunction(() => !window.loftline.app.state.isDirty);
const before = (await state()).project.operations.length;
await page.evaluate(() => window.loftline.apply("new"));
await page.evaluate((p) => window.loftline.openProject(p), saved);
await page.waitForFunction((n) => window.loftline.app.state.project.operations.length === n, before);
check(true, "save and reopen");

// The sample: what the UI writes is what the command line writes.
await page.evaluate((p) => window.loftline.openProject(p), sample);
await page.waitForFunction(() => window.loftline.app.state.project.operations.length === 4);
await menu("File", /^Export G-code/);
await page.waitForSelector(".program");
await page.waitForFunction(() => document.querySelector(".program")?.textContent.length > 1000, null, { timeout: 120000 });
const written = join(work, "program.tap");
await page.getByRole("button", { name: "Save…" }).click();
await typePath(written);
await page.waitForFunction(() => !document.querySelector(".sheet"), null, { timeout: 120000 }).catch(() => undefined);
const out = join(work, "cli");
const post = (await state()).post.id;
execFileSync(cli, ["export", sample, "--post", post, "--builtin-only", "--quiet", "--out", out]);
const cliProgram = readFileSync(join(out, readdirSync(out)[0]));
check(readFileSync(written).equals(cliProgram), "the UI's program is the command line's, byte for byte");

// Help comes from the core, and a bad open is shown, not swallowed.
await page.evaluate(() => window.loftline.sheets.openHelp());
await page.waitForSelector(".help-text p");
check((await page.locator(".tool-list li").count()) > 20, "help topics");
await page.keyboard.press("Escape");
await page.evaluate(() => window.loftline.apply("open", { path: "/no/such/file.loftline" }));
await page.waitForSelector(".alert-text");
check(true, "a failed open shows an alert");
check(errors.length === 0, `no page errors ${errors.join("; ")}`);

await browser.close();
if (failed) { console.error(`${failed} check(s) failed`); process.exit(1); }
console.log("all checks passed");
