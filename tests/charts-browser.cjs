// Optional browser checks: requires Playwright on the development machine only.
// node tests/charts-browser.cjs [path-to-generated-report.html]
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {pathToFileURL} = require('node:url');
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root = path.resolve(__dirname, '..');
const js = fs.readFileSync(path.join(root, 'report-charts.js'), 'utf8');
const css = fs.readFileSync(path.join(root, 'report-charts.css'), 'utf8');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'laptop-checkup-chart-browser-'));
const fixture = {
  duration:20,
  phases:[{id:'gpu',label:'GPU',start:0,end:10},{id:'combo',label:'CPU+GPU',start:10,end:20}],
  cpu:[[0,3000,125,80],[1,2900,120,null],[2,2800,110,90],[10,2200,100,95],[20,2100,100,96]],
  gpu:[[0,60,2100,105,100,0,105],[1,80,2000,100,100,1,105],[2,87,1900,90,100,1,105],[10,87,1750,75,100,1,105],[20,87,1700,71,100,null,105]],
  fps:[{label:'GPU',points:[[1,200],[2,195],[3,180]]},{label:'CPU+GPU',points:[[1,150],[2,140],[3,130]]}],
  cinebench:[{label:'CPU',points:[[1,17000],[2,15000]]},{label:'CPU+GPU',points:[[1,13000],[2,12000]]}]
};
function writeFixture(name, data) {
  const target = path.join(temp, name);
  const json = JSON.stringify(data).replaceAll('<', '\\u003c');
  fs.writeFileSync(target, `<!doctype html><html lang="ru"><meta charset="utf-8"><style>
    :root{--bg:white;--fg:#1f2328;--mut:#57606a;--line:#d0d7de;--card:#f6f8fa}
    body{font:15px system-ui;margin:0;padding:16px;max-width:1000px}${css}</style>
    <nav class="report-tabs" role="tablist" hidden>
    <button id="tab-report" role="tab" aria-controls="panel-report" aria-selected="true">Отчёт</button>
    <button id="tab-charts" role="tab" aria-controls="panel-charts" aria-selected="false">Графики</button></nav>
    <section id="panel-report">Synthetic browser fixture</section>
    <section id="panel-charts" hidden><select id="chart-phase"><option value="all">Весь замер</option></select>
    <div id="chart-phase-legend"></div><div id="cpu-charts" class="chart-grid"></div>
    <div id="gpu-charts" class="chart-grid"></div><div id="performance-charts" class="chart-grid"></div></section>
    <script id="chart-data" type="application/json">${json}</script><script>${js}</script></html>`);
  return pathToFileURL(target).href;
}
(async () => {
  const browser = await chromium.launch({headless:true, ...(process.env.CHROME_BIN ? {executablePath:process.env.CHROME_BIN} : {})});
  let checks = 0;
  const check = (condition, message) => { assert(condition, message); checks++; };
  try {
    const page = await browser.newPage({viewport:{width:1200,height:900}});
    const errors = [], network = [];
    page.on('pageerror', error => errors.push(error.message));
    page.on('request', request => { if (!request.url().startsWith('file:')) network.push(request.url()); });
    await page.goto(writeFixture('full.html', fixture));
    check(await page.locator('#panel-report').isVisible() && !await page.locator('#panel-charts').isVisible(), 'Open on the summary tab');
    await page.locator('#tab-charts').click();
    check(await page.locator('#panel-charts').isVisible(), 'Open charts using the tab');
    check(await page.locator('.chart-card svg:visible').count() === 9, 'Render all nine charts');
    check(await page.locator('#chart-phase option').count() === 3, 'Expose all recorded phases');
    const cpuPath = await page.locator('#cpu-charts .chart-card').first().locator('path').getAttribute('d');
    check((cpuPath.match(/M/g) || []).length >= 2, 'Leave gaps for missing sensor readings');
    check(await page.locator('#gpu-charts rect[fill="#dc4444"]').count() > 0, 'Mark observed thermal limiting');
    await page.locator('#chart-phase').selectOption('1');
    check((await page.locator('#cpu-charts .chart-card').first().locator('svg').textContent()).includes('CPU+GPU'), 'Filter the sensor timeline by phase');
    check((await page.locator('#performance-charts .chart-card').first().locator('svg').textContent()).includes('0:00'), 'Keep the rendering-time FPS axis independent of the sensor filter');
    const cpuPlot = page.locator('#cpu-charts svg').first();
    await cpuPlot.hover({position:{x:100,y:80}});
    check(await page.locator('#gpu-charts line.chart-cursor[visibility="visible"]').count() === 4, 'Synchronize the cursor across sensor charts');
    await cpuPlot.focus();
    await page.keyboard.press('End');
    check((await page.locator('#cpu-charts .chart-readout').first().textContent()).startsWith('0:20'), 'Support keyboard inspection of sensor values');
    await page.setViewportSize({width:390,height:844});
    check(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), 'Fit the graphs on a mobile screen');
    await page.locator('#tab-charts').focus();
    await page.keyboard.press('ArrowLeft');
    check(await page.locator('#panel-report').isVisible(), 'Support keyboard tab navigation');
    await page.goto(writeFixture('empty.html',{duration:1,phases:[],cpu:[],gpu:[],fps:[],cinebench:[]}));
    await page.locator('#tab-charts').click();
    check(await page.locator('.chart-card svg:visible').count() === 0, 'Do not draw invented lines for missing data');
    check(await page.locator('.chart-empty:visible').count() === 9, 'Explain missing data in every empty chart');
    if (process.argv[2]) {
      await page.setViewportSize({width:1200,height:900});
      await page.goto(pathToFileURL(path.resolve(process.argv[2])).href);
      await page.locator('#tab-charts').click();
      check(await page.locator('.chart-card').count() === 9, 'Render the real PowerShell-generated report');
      check(await page.locator('#cpu-charts svg:visible').count() === 3, 'Read recorded CPU sensors from the real report');
      check(await page.locator('#gpu-charts svg:visible').count() === 4, 'Read recorded GPU sensors from the real report');
      await page.screenshot({path:path.join(temp,'preview.png'),fullPage:true});
      console.log(`Screenshot: ${path.join(temp,'preview.png')}`);
    }
    check(network.length === 0, 'Make no network requests from a standalone HTML file');
    check(errors.length === 0, `No browser errors: ${errors.join('; ')}`);
    console.log(`PASS: ${checks} browser checks`);
  } finally {
    await browser.close();
    // Keep an explicitly requested preview screenshot until the developer inspects it.
    if (!process.argv[2]) fs.rmSync(temp,{recursive:true,force:true});
  }
})().catch(error => { console.error(error); process.exitCode=1; });
