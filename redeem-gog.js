// Redeem GOG keys that Prime Gaming handed out (store=gog.com) into the GOG library.
// Reuses the persistent browser profile (logged into GOG via gog.js), which bypasses the
// captcha that blocks upstream's logged-out redemption. Reads pending codes from the Prime DB,
// redeems each, and records the outcome back into prime-gaming.json.
import { chromium } from 'patchright';
import { jsonDb, datetime, handleSIGINT } from './src/util.js'; // util before config (cfg TDZ)
import { cfg } from './src/config.js';

console.log(datetime(), 'started redeeming GOG keys from Prime');
const REDEEM_MAX = parseInt(process.env.REDEEM_MAX || '0', 10); // 0 = no limit
const DONE = new Set(['claimed and redeemed', 'redeem: not found']);

const pdb = await jsonDb('prime-gaming.json', {});
const pending = [];
for (const [user, games] of Object.entries(pdb.data || {})) {
  if (!games || typeof games !== 'object') continue;
  for (const [, g] of Object.entries(games)) {
    if (g && typeof g === 'object' && g.code && String(g.store || '').includes('gog') && !DONE.has(g.status)) {
      pending.push(g);
    }
  }
}
console.log(`Found ${pending.length} GOG code(s) to redeem${REDEEM_MAX ? ` (limiting to ${REDEEM_MAX})` : ''}.`);
if (!pending.length) process.exit(0);

const context = await chromium.launchPersistentContext(cfg.dir.browser, {
  headless: cfg.headless, viewport: { width: cfg.width, height: cfg.height },
  locale: 'en-US', args: ['--hide-crash-restore-bubble'],
});
handleSIGINT(context);
context.setDefaultTimeout(cfg.timeout);
const page = context.pages().length ? context.pages()[0] : await context.newPage();

await page.goto('https://www.gog.com/en', { waitUntil: 'domcontentloaded' });
if (!await page.locator('.js-menu-account').count()) {
  console.error('Not logged into GOG — run `node gog` first. Skipping redemption.');
  await context.close(); process.exit(1);
}

let redeemed = 0, already = 0, failed = 0, n = 0;
for (const g of pending) {
  if (REDEEM_MAX && n >= REDEEM_MAX) break;
  n++;
  const code = g.code;
  try {
    await page.goto('https://www.gog.com/en/redeem', { waitUntil: 'domcontentloaded' });
    await page.locator('#codeInput').waitFor();
    await page.fill('#codeInput', code);
    const r1p = page.waitForResponse(r => r.request().method() === 'GET' && r.url().startsWith('https://redeem.gog.com/'), { timeout: 30000 });
    await page.click('[type="submit"]'); // Continue (validate)
    const r1 = JSON.parse(await (await r1p).text());
    if (r1.reason?.includes('captcha')) { console.error(`  ${g.title}: GOG captcha (rate limit) — stopping this run`); failed++; break; }
    if (r1.reason === 'code_used') { console.log(`  ${g.title}: already redeemed`); g.status = 'claimed and redeemed'; already++; continue; }
    if (r1.reason === 'code_not_found') { console.error(`  ${g.title}: code not found`); g.status = 'redeem: not found'; failed++; continue; }
    const prod = r1.products?.[0]?.title || g.title;
    const r2p = page.waitForResponse(r => r.request().method() === 'POST' && r.url().startsWith('https://redeem.gog.com/'), { timeout: 30000 });
    await page.click('[type="submit"]'); // Redeem (consume)
    const r2 = JSON.parse(await (await r2p).text());
    if (r2?.type === 'async_processing') {
      await page.locator('h1:has-text("Code redeemed successfully!")').waitFor();
      console.log(`  Redeemed: ${prod}`);
      g.status = 'claimed and redeemed';
      redeemed++;
    } else if (r2?.reason?.includes('captcha')) {
      console.error(`  ${g.title}: GOG captcha on redeem (rate limit) — stopping this run`); failed++; break;
    } else {
      console.log(`  ${g.title}: unexpected redeem response ${JSON.stringify(r2).slice(0, 150)}`); failed++;
    }
  } catch (e) {
    console.error(`  ${g.title}: error ${e.message ? e.message.split('\n')[0] : e}`); failed++;
  }
}
await pdb.write();
console.log(`GOG redemption done: ${redeemed} redeemed, ${already} already, ${failed} failed/skipped.`);
await context.close();
process.exit(0);
