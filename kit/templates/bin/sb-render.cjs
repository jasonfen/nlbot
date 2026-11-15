// sb-render.cjs — render a SilverBullet page in headless Chromium and print its
// visible text (plus a screenshot), to check Space Lua queries and templates
// actually render before telling ${HUMAN_NAME} they work.
//
//   SBU=<user>:<password> PROFILE=/tmp/bot-sb-profile \
//   WAIT=45000 NODE_PATH=<dir-with-playwright>/node_modules \
//   node sb-render.cjs <page-name> <screenshot.png>
//
// A fresh PROFILE must sync and index the whole space before query widgets fill
// in, so queries render EMPTY with a short WAIT. Use WAIT=45000 on first use,
// then reuse the same PROFILE with ~15000. An empty list on a cold profile is
// not a broken query; test a known-good page (one whose query you have seen render) as a control.
// Needs Playwright (npm install playwright) somewhere on NODE_PATH; it has no install of its own.
// SBU is a BROWSER login (user:password), not the API token in .sb-token. Before the
// 2026-09-22 multi-space cutover it came from SB_USER in the repo's stale compose copy;
// that file is gone and the live stack sets no SB_USER, so the password now has to be
// supplied by hand (${HUMAN_NAME} holds it). With the Runtime API live, ./bin/sb.sh lua/query/shot
// covers most of what this script was built for.
// Added 2026-09-11. Output is capped at MAXCHARS (default 2500): a long list that
// seems to stop early is probably this cap, not the page.
const { chromium } = require('playwright');
(async () => {
  const i = process.env.SBU.indexOf(':'); const user = process.env.SBU.slice(0, i), pass = process.env.SBU.slice(i + 1);
  const b = await chromium.launchPersistentContext(process.env.PROFILE, { viewport: { width: 1100, height: 1400 } });
  const p = b.pages()[0] || await b.newPage();
  const errs = []; p.on('console', m => { if (m.type() === 'error') errs.push(m.text()); });
  await p.goto('http://127.0.0.1:${SB_PORT}/.auth');
  if (await p.$('input[name=username]')) { await p.fill('input[name=username]', user); await p.fill('input[name=password]', pass);
  await Promise.all([p.waitForNavigation(), p.keyboard.press('Enter')]); }
  await p.goto('http://127.0.0.1:${SB_PORT}/' + (process.argv[2] || 'journals'));
  await p.waitForTimeout(+(process.env.WAIT||8000));
  if (process.env.SCROLL === 'bottom') {  // the editor only renders lines near the viewport
    await p.evaluate(() => { const s = document.querySelector('.cm-scroller'); if (s) s.scrollTop = s.scrollHeight; });
    await p.waitForTimeout(3000);
  }
  await p.screenshot({ path: process.argv[3] });
  const txt = await p.evaluate(() => document.body.innerText);
  console.log(txt.slice(0, +(process.env.MAXCHARS || 2500)));  // MAXCHARS: default output is capped at 2500 chars, so long lists LOOK truncated
  console.log('--- console errors:', errs.length ? errs.slice(0, 5).join(' | ') : 'none');
  await b.close();
})().catch(e => { console.error('RENDER-FAIL', e.message); process.exit(1); });
