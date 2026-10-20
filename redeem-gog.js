// Redeem GOG keys that Prime Gaming handed out (store=gog.com) into the GOG library.
// Reuses the persistent browser profile (logged into GOG via gog.js), which bypasses the
// captcha that blocks upstream's logged-out redemption. Reads pending codes from the Prime DB,
// redeems each, and records the outcome back into prime-gaming.json.
import { chromium } from 'patchright';
import { jsonDb, datetime, handleSIGINT } from './src/util.js'; // util before config (cfg TDZ)
import { cfg } from './src/config.js';

// Pre-fetch Cloudflare clearance cookies via FlareSolverr so the browser context
// already has a valid cf_clearance token before loading gog.com, preventing the
// Cloudflare JS challenge from blocking the login check.
const FLARESOLVERR_URL = process.env.FLARESOLVERR_URL || 'http://192.168.2.5:8191/v1';

async function fetchClearanceCookies(targetUrl) {
  try {
    const resp = await fetch(FLARESOLVERR_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ cmd: 'request.get', url: targetUrl, maxTimeout: 60000 }),
    });
    if (!resp.ok) { console.error(`FlareSolverr HTTP ${resp.status} — skipping`); return []; }
    const data = await resp.json();
    if (data.status !== 'ok') { console.error(`FlareSolverr status=${data.status} — skipping`); return []; }
    return data.solution?.cookies || [];
  } catch (e) {
    console.error('FlareSolverr unreachable:', e.message?.split('\n')[0], '— skipping');
    return [];
  }
}

console.log(datetime(), 'started redeeming GOG keys from Prime');
const REDEEM_MAX = parseInt(process.env.REDEEM_MAX || '0', 10); // 0 = no limit
const DONE = new Set(['claimed and redeemed', 'redeem: not found', 'redeem: expired']);

// The "Continue"/"Redeem" button is disabled until the code field validates client-side
// (Angular). Clicking before it enables fires no request, so the validate waitForResponse
// times out (observed 2026-06-24). Wait for the enabled button, then click.
async function clickWhenEnabled(page, sel = '[type="submit"]') {
  await page.locator(`${sel}:not([disabled])`).first().waitFor({ state: 'visible', timeout: 20000 });
  await page.locator(sel).first().click();
}

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

// Inject FlareSolverr Cloudflare-clearance cookies once before the login check.
try {
  const fsCookies = await fetchClearanceCookies('https://www.gog.com/en');
  if (fsCookies.length) {
    const toInject = fsCookies
      .filter(c => c.name && c.value && (c.domain || '').includes('gog.com'))
      .map(c => ({
        name: c.name, value: c.value,
        domain: c.domain.startsWith('.') ? c.domain : `.${c.domain}`,
        path: c.path || '/',
        ...(c.expires && c.expires > 0 ? { expires: c.expires } : {}),
        httpOnly: !!c.httpOnly, secure: !!c.secure,
        sameSite: ['Strict', 'Lax', 'None'].includes(c.sameSite) ? c.sameSite : 'Lax',
      }));
    if (toInject.length) {
      await context.addCookies(toInject);
      console.log(`Injected ${toInject.length} FlareSolverr cookie(s) for gog.com`);
    }
  }
} catch (e) {
  console.error('FlareSolverr cookie injection failed:', e.message ? e.message.split('\n')[0] : e);
}

// Confirm login via userData.json instead of GOG's changing menu markup (the
// .js-menu-account header element is gone since ~10/2026). gog.com sits behind
// Cloudflare and routinely flakes its first load, so retry a few times before
// giving up. Failing to confirm login is NOT a crash: the daily `node gog` step
// refreshes the session, so any unredeemed keys simply carry to the next run.
// Exit 0 on deferral so the wrapper never reports a false crash.
let isLoggedIn = false, gogUser = '';
const LOGIN_TRIES = 3;
for (let attempt = 1; attempt <= LOGIN_TRIES && !isLoggedIn; attempt++) {
  try {
    await page.goto('https://www.gog.com/en', { waitUntil: 'domcontentloaded' });
    const uResp = await context.request.get('https://www.gog.com/userData.json');
    if (!uResp.ok()) throw new Error(`userData.json HTTP ${uResp.status()}`);
    const uAccount = await uResp.json();
    if (uAccount && uAccount.isLoggedIn) { isLoggedIn = true; gogUser = uAccount.username || ''; }
    else throw new Error('GOG session not logged in');
  } catch (e) {
    console.error(`GOG login check attempt ${attempt}/${LOGIN_TRIES} failed:`, e.message ? e.message.split('\n')[0] : e);
    if (attempt < LOGIN_TRIES) await page.waitForTimeout(3000);
  }
}
if (!isLoggedIn) {
  console.log(`REDEEM_DEFERRED: GOG not confirmed logged-in after ${LOGIN_TRIES} tries — deferring ${pending.length} pending key(s) to next run.`);
  await context.close(); process.exit(0);
}
console.log(`Signed in as ${gogUser || 'gog-user'}`);

let redeemed = 0, already = 0, expired = 0, failed = 0, n = 0;
for (const g of pending) {
  if (REDEEM_MAX && n >= REDEEM_MAX) break;
  n++;
  const code = g.code;
  try {
    await page.goto('https://www.gog.com/en/redeem', { waitUntil: 'domcontentloaded' });
    await page.locator('#codeInput').waitFor();
    await page.fill('#codeInput', code);
    const r1p = page.waitForResponse(r => r.request().method() === 'GET' && r.url().startsWith('https://redeem.gog.com/'), { timeout: 45000 });
    await clickWhenEnabled(page); // Continue (validate)
    const r1 = JSON.parse(await (await r1p).text());
    if (r1.reason?.includes('captcha')) { console.error(`  ${g.title}: GOG captcha (rate limit) — stopping this run`); failed++; break; }
    if (r1.reason === 'code_used') { console.log(`  ${g.title}: already redeemed`); g.status = 'claimed and redeemed'; already++; continue; }
    // Expired or not-found codes are TERMINAL — mark done so they aren't retried forever.
    if (r1.reason === 'code_expired') { console.log(`  ${g.title}: code EXPIRED — marking terminal`); g.status = 'redeem: expired'; expired++; continue; }
    if (r1.reason === 'code_not_found') { console.log(`  ${g.title}: code not found — marking terminal`); g.status = 'redeem: not found'; expired++; continue; }
    const prod = r1.products?.[0]?.title || g.title;
    if (cfg.dryrun) { console.log(`  DRYRUN=1 -> ${prod}: code validates, skipping redeem submit`); continue; }
    const r2p = page.waitForResponse(r => r.request().method() === 'POST' && r.url().startsWith('https://redeem.gog.com/'), { timeout: 45000 });
    await clickWhenEnabled(page); // Redeem (consume)
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
console.log(`GOG redemption done: ${redeemed} redeemed, ${already} already, ${expired} expired/terminal, ${failed} failed.`);
console.log(`REDEEM_SUMMARY redeemed=${redeemed} already=${already} expired=${expired} failed=${failed}`);
await context.close();
process.exit(0);
