// Headless screenshots of the front end, the way scripts/ui.sh checks the Mac app. Run tools/serve.mjs first.
// Usage: node tools/shots.mjs <output folder> [base url]
import { mkdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { chromium } from "playwright";

const out = resolve(process.argv[2] ?? "shots");
const base = process.argv[3] ?? "http://localhost:5174";
const sample = resolve(process.env.LOFTLINE_SAMPLE ?? "../samples/sign.loftline");
mkdirSync(out, { recursive: true });

const browser = await chromium.launch({ args: ["--use-gl=swiftshader", "--enable-webgl", "--ignore-gpu-blocklist", "--enable-unsafe-swiftshader"] });
const failures = [];
for (const scheme of ["light", "dark"]) {
  const page = await (await browser.newContext({ viewport: { width: 1440, height: 900 }, colorScheme: scheme, deviceScaleFactor: 1 })).newPage();
  page.on("pageerror", (e) => failures.push(`${scheme}: ${e.message}`));
  page.on("console", (m) => { if (m.type() === "error") failures.push(`${scheme} console: ${m.text()}`); });
  const shot = (name) => page.screenshot({ path: join(out, `${name}-${scheme}.png`) });
  const settle = () => page.waitForTimeout(400);
  await page.goto(base);
  await page.waitForFunction(() => window.loftline?.app.state);
  await settle();
  await shot("empty");
  await page.evaluate((p) => window.loftline.apply("open", { path: p }), sample);
  await settle();
  await shot("design");
  await page.getByRole("tab", { name: "Toolpaths" }).click();
  await page.evaluate(() => window.loftline.apply("calculate", {}));
  await page.locator(".op-list li").nth(1).click();
  await settle();
  await shot("toolpaths");
  await page.evaluate(() => window.loftline.setCenter("split"));
  await page.waitForTimeout(3000);
  await shot("split");
  await page.evaluate(() => window.loftline.setCenter("3d"));
  await page.waitForTimeout(1200);
  await shot("preview");
  await page.evaluate(() => window.loftline.setCenter("2d"));
  await page.getByRole("button", { name: "Export G-code" }).click();
  await page.waitForTimeout(1500);
  await shot("export");
  await page.keyboard.press("Escape");
  await page.evaluate(() => window.loftline.sheets.openJobSetup());
  await settle();
  await shot("jobsetup");
  await page.keyboard.press("Escape");
  await page.evaluate(() => window.loftline.sheets.openTools());
  await settle();
  await shot("tools");
  await page.keyboard.press("Escape");
  await page.close();
}
await browser.close();
if (failures.length) { console.error(failures.join("\n")); process.exit(1); }
console.log(`screenshots in ${out}`);
