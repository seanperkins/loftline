// Drives the built front end end to end against a real loftline-core, by the same mouse and menu routes a person uses, and checks the
// program it writes is byte for byte the one the command line writes. Run tools/serve.mjs first.
// Usage: node tools/e2e.mjs <loftline-cli> [base url]
import { execFileSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { request } from "node:http";
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

const wait = Number(process.env.E2E_WAIT ?? 120000);
const row = (label) => page.locator(`label.row:has(.row-label:text-is("${label}"))`).locator("select, input").first();
const until = (f, arg) => page.waitForFunction(f, arg, { timeout: wait });
const applyJob = async () => { await page.getByRole("button", { name: "Apply" }).click(); await until(() => !document.querySelector(".sheet")); };
const sampleJSON = () => JSON.parse(readFileSync(sample, "utf8"));
const openEdited = async (name, change) => {
  const object = sampleJSON();
  change(object);
  const file = join(work, name);
  writeFileSync(file, JSON.stringify(object));
  await page.evaluate((path) => window.loftline.apply("open", { path }), file);
  await until((n) => window.loftline.app.state.path?.endsWith(n), name);
};
// One group of checks: a failure is reported and the next group still runs.
const section = async (name, body) => {
  try {
    await body();
  } catch (e) {
    check(false, `${name}: ${e.message.split("\n")[0]}`);
    await page.evaluate(() => { document.querySelector(".sheet-host")?.replaceChildren(); document.querySelector(".sheet-host")?.classList.remove("open"); document.body.click(); });
  }
};

// The text tool: what the sheet sends is what the core's decoder takes.
await section("text tool", async () => {
  await page.evaluate(() => window.loftline.apply("new"));
  await page.locator('[data-tool="text"]').click();
  await page.mouse.click(box.x + 500, box.y + 300);
  await page.getByRole("button", { name: "Add", exact: true }).click();
  await until(() => window.loftline.app.state.project.document.shapes[0]?.text);
  check(!(await page.locator(".alert-text").count()), "the text tool makes text");
});

// V-carve's pass limit reaches the field the toolpath reads.
await section("V-carve pass depth", async () => {
  await menu("Edit", /^Select All/);
  await page.getByRole("tab", { name: "Toolpaths" }).click();
  await page.getByLabel("New Toolpath").selectOption("vcarve");
  await until(() => window.loftline.app.state.project.operations.length === 1);
  await row("Max pass depth").fill("0.05");
  await row("Max pass depth").blur();
  await until(() => window.loftline.app.state.undoAction === "Edit Toolpath");
  const vcarve = (await state()).project.operations[0].vcarve._0.params;
  check(vcarve.passDepth === 0.05, "V-carve's Max pass depth sets passDepth");
  check(await row("Max pass depth").inputValue() === "0.05", "and shows it");
});

// Job Setup: Z zero on the spoilboard, and a units switch converts what the form doesn't show.
await section("Job Setup", async () => {
  await menu("Job", /^Job Setup/);
  await row("Z zero").selectOption("spoilboard");
  await applyJob();
  check((await state()).project.document.job.zZero === "spoilboard", "Z zero on the spoilboard");
  await page.evaluate(() => {
    const d = window.loftline.app.state.project.document;
    return window.loftline.apply("setJob", { units: d.units, gridSpacing: d.gridSpacing, job: { ...d.job, zZero: "materialTop", datumOffset: { x: 0.5, y: 0.25 }, touchOffSpot: { x: 1, y: 2 }, plungeGap: 0.1 } });
  });
  const inInches = (await state()).project.document.job;
  await menu("Job", /^Job Setup/);
  await row("Units").selectOption("millimeter");
  await until((w) => [...document.querySelectorAll(".sheet input.number")].some((i) => Number(i.value) === w), inInches.width * 25.4);
  await applyJob();
  const inMM = (await state()).project.document;
  check(inMM.units === "millimeter" && inMM.job.width === inInches.width * 25.4, "the units switch converts the material");
  check(inMM.job.datumOffset.x === 12.7 && inMM.job.touchOffSpot.y === 50.8 && Math.abs(inMM.job.plungeGap - 2.54) < 1e-9, "and the datum offset, touch-off spot and plunge gap");
});

// A post only the project has: posted from its copy, and named in the pickers.
await section("carried post", async () => {
  await openEdited("carried.loftline", (o) => { o.postProfileID = "carried-post"; o.postSnapshot.id = "carried-post"; o.postSnapshot.name = "Carried"; });
  await menu("File", /^Export G-code/);
  await until(() => document.querySelector(".program")?.textContent.length > 1000);
  check(await row("Post processor").inputValue() === "carried-post", "Export G-code names the project's own post");
  check(!(await page.locator(".sheet .error-text").count()), "and posts with it");
  await page.getByRole("button", { name: "Close" }).click();
  await menu("Toolpaths", /^Save All/);
  await until(() => document.querySelector(".sheet table tbody tr"));
  check(await row("Post processor").inputValue() === "carried-post", "Save All names it too");
  check(!(await page.locator(".sheet .error-text").count()), "and posts with it");
  await page.getByRole("button", { name: "Close" }).click();
});

// A machine that isn't installed stays the project's.
await section("missing machine", async () => {
  await openEdited("machine.loftline", (o) => { o.machineID = "gone"; delete o.machineSnapshot; delete o.machineInferredFor; });
  await menu("Job", /^Job Setup/);
  await until(() => [...document.querySelectorAll(".sheet select option")].some((o) => o.value === "gone"));
  check(await row("Machine").inputValue() === "gone", "Job Setup shows the project's own machine");
  await page.getByRole("button", { name: "Cancel" }).click();
});

// A two-sided job: the side on show is what posts, and the window says so.
await section("two-sided job", async () => {
  await page.evaluate((path) => window.loftline.apply("open", { path }), sample);
  await until(() => window.loftline.app.state.project.operations.length === 4);
  await page.evaluate(() => {
    const d = window.loftline.app.state.project.document;
    return window.loftline.apply("setJob", { units: d.units, gridSpacing: d.gridSpacing, job: { ...d.job, twoSided: { flip: "leftRight" } } });
  });
  check((await page.locator(".status-bar").textContent()).includes("Top side"), "the status bar says which side");
  await menu("View", /^Show Bottom Side/);
  await until(() => window.loftline.app.state.side === "bottom");
  check((await page.locator(".status-bar").textContent()).includes("Bottom side"), "Show Bottom Side");
  await menu("File", /^Export G-code/);
  await until(() => document.querySelector(".sheet .coverage"));
  check((await page.locator(".sheet .coverage").textContent()).includes("Bottom side"), "Export G-code says what the program covers");
  await page.getByRole("button", { name: "Close" }).click();
});

// The test server is this computer's only: another site's page, or another host's name, can't reach the core.
await section("test server", async () => {
  const probe = (headers) => new Promise((resolve, reject) => {
    const u = new URL(base);
    const r = request({ host: u.hostname, port: u.port, path: "/core", method: "POST", headers }, (res) => { res.resume(); resolve(res.statusCode); });
    r.on("error", reject);
    r.end('{"id":1,"method":"state"}');
  });
  check(await probe({}) === 200, "the test server answers this computer");
  check(await probe({ origin: "http://evil.example" }) === 403, "and refuses another site's page");
  check(await probe({ host: "evil.example" }) === 403, "and another host's name");
});

// Help > Connect an AI Assistant… shows the bundled MCP server and the settings to paste (nothing is clicked that writes).
await section("assistant", async () => {
  await menu("Help", /^Connect an AI Assistant/);
  await until(() => document.querySelector(".sheet pre.code"));
  const text = await page.locator(".sheet").textContent();
  check(text.includes("loftline-mcp") && text.includes("mcpServers") && text.includes("claude mcp add loftline"), "Connect an AI Assistant shows the server and its settings");
  check(await page.getByRole("button", { name: /^Copy/ }).count() === 3, "with three Copy buttons");
  await page.getByRole("button", { name: "Close" }).click();
});

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
