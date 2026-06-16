/**
 * Mod Search & Add Tests
 * Tests the two-step mod search flow:
 *   1) Search for "Squeak Through" from the edit page
 *   2) Verify search results appear
 *   3) Click Add on a result
 *   4) Verify mod appears in server config
 *
 * Also tests the direct API path as a fallback.
 */

const BASE_URL = 'http://localhost:8080';

/* ---------- http helper ---------- */
async function http(method, url, body) {
  const opts = { method, headers: {} };
  if (body !== undefined) {
    opts.headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(body);
  }
  const res = await fetch(url, opts);
  let data = null;
  if (res.status !== 204) {
    try { data = await res.json(); } catch { /* non-json */ }
  }
  return { status: res.status, body: data };
}

/* ---------- wait for selector ---------- */
async function waitForEl(page, selector, timeout = 8000) {
  return page.waitForSelector(selector, { timeout });
}

/* ---------- wait for toast ---------- */
async function waitForToast(page, timeout = 8000) {
  await waitForEl(page, '.toast', timeout);
  return page.evaluate(() => {
    const t = document.querySelector('.toast');
    return t ? t.textContent : '';
  });
}

/* ---------- cleanup helper ---------- */
async function cleanupServer(serverId) {
  if (!serverId) return;
  try { await http('DELETE', BASE_URL + '/api/servers/' + serverId); } catch { /* ignore */ }
}

export default async function runTests(browser, runner) {
  let testServerId = null;

  /* -- Create test server -- */
  {
    const createResult = await http('POST', BASE_URL + '/api/servers', {
      name: 'Mod Search Test Server',
      saveFile: ''
    });
    await runner.run('Create server returns 201', createResult.status, 201);
    if (createResult.body) {
      testServerId = createResult.body.id;
    }
  }

  if (!testServerId) {
    await runner.runTruthy('FATAL: Could not create test server', false);
    return;
  }

  /* -- 1. Search for "Squeak Through" via UI -- */
  {
    const page = await browser.newPage();
    await page.goto(BASE_URL + '/edit/' + testServerId, { waitUntil: 'networkidle0', timeout: 10000 });

    // Wait for mod search input
    await waitForEl(page, '.mod-search-input');

    // Type "Squeak Through" in search input
    await page.click('.mod-search-input');
    // Clear any existing value first
    await page.evaluate(() => {
      const inp = document.querySelector('.mod-search-input');
      if (inp) inp.value = '';
    });
    await page.type('.mod-search-input', 'Squeak Through');

    // Click Search button
    await page.click('.mod-add-btn');

    // Wait for search results container to populate
    // Results should appear within timeout
    let resultsAppeared = false;
    for (let i = 0; i < 20; i++) {
      await new Promise(r => setTimeout(r, 500));
      resultsAppeared = await page.evaluate(() => {
        const rows = document.querySelectorAll('.mod-search-result-row');
        return rows.length > 0;
      });
      if (resultsAppeared) break;
    }
    await runner.runTruthy('Search results appear after clicking Search', resultsAppeared);

    // Verify at least one result row contains "Squeak Through" in title
    if (resultsAppeared) {
      const hasSqueakResult = await page.evaluate(() => {
        const rows = document.querySelectorAll('.mod-search-result-row');
        return Array.from(rows).some(row => {
          const title = row.querySelector('.mod-title');
          return title && title.textContent && title.textContent.includes('Squeak');
        });
      });
      await runner.runTruthy('Search results contain Squeak Through mod', hasSqueakResult);
    }

    /* -- 2. Click Add on first result -- */
    {
      const addBtns = await page.$$('.btn-mod-add');
      if (addBtns.length > 0) {
        await addBtns[0].click();

        // Wait for success toast
        const toastText = await waitForToast(page);
        await runner.runTruthy('Add mod shows success toast', toastText.includes('Added mod'));
      } else {
        await runner.runTruthy('Add button found in search results', false);
      }

      // Verify search results cleared after add
      const resultsCleared = await page.evaluate(() => {
        const rows = document.querySelectorAll('.mod-search-result-row');
        return rows.length === 0;
      });
      await runner.runTruthy('Search results cleared after Add', resultsCleared);
    }

    /* -- 3. Verify mod in server config via API -- */
    {
      // Give server a moment to save
      await new Promise(r => setTimeout(r, 1000));

      const cfgRes = await http('GET', BASE_URL + '/api/servers/' + testServerId + '/config');
      const modInConfig = Array.isArray(cfgRes.body.mods) &&
                          cfgRes.body.mods.some(m => m.name === 'Squeak Through');
      await runner.runTruthy('"Squeak Through" mod appears in server config', modInConfig);
    }

    await page.close();
  }

  /* -- 4. Direct API add mod (fallback path test) -- */
  {
    // Add another mod directly via API to verify the add endpoint still works
    const addModRes = await http('POST', BASE_URL + '/api/servers/' + testServerId + '/mods/add', {
      name: 'Even Swordsier',
      title: 'Even Swordsier',
      version: ''
    });
    await runner.runTruthy('Direct API add mod returns 201', addModRes.status === 201);

    // Verify both mods exist
    const cfgRes = await http('GET', BASE_URL + '/api/servers/' + testServerId + '/config');
    const hasSqueak = Array.isArray(cfgRes.body.mods) &&
                      cfgRes.body.mods.some(m => m.name === 'Squeak Through');
    const hasSwordsier = Array.isArray(cfgRes.body.mods) &&
                         cfgRes.body.mods.some(m => m.name === 'Even Swordsier');
    await runner.runTruthy('Both mods exist in config', hasSqueak && hasSwordsier);
  }

  /* -- Cleanup -- */
  await cleanupServer(testServerId);
}
