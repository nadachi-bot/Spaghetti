/**
 * Settings Tests
 * Verifies GET and PUT /api/settings operations against the real server.
 */

const BASE_URL = 'http://localhost:8080';

async function http(method, url, body) {
  const opts = { method, headers: {} };
  if (body !== undefined) {
    opts.headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(body);
  }
  const res = await fetch(url, opts);
  let data = null;
  if (res.status !== 204) {
    try { data = await res.json(); } catch { /* non-json response */ }
  }
  return { status: res.status, body: data };
}

export default async function runTests(browser, runner) {

  // --- GET Settings ---

  {
    const getResult = await http('GET', BASE_URL + '/api/settings');
    await runner.run('Get settings returns 200', getResult.status, 200);

    const settings = getResult.body;
    await runner.runTruthy('Settings response is an object', settings != null);

    if (settings) {
      await runner.runTruthy('Settings contains port field', 'port' in settings);
      await runner.run('Default port is 8080', settings.port, 8080);
      await runner.runTruthy('Settings contains factorioUsername field', 'factorioUsername' in settings);
      // Token should NOT be returned for security
      await runner.run('Settings does not contain factorioToken field', 'factorioToken' in settings, false);
    }
  }

  // --- PUT Settings: Update port ---

  {
    const testPort = Math.floor(Math.random() * 10000) + 20000;
    const updateResult = await http('PUT', BASE_URL + '/api/settings', {
      port: testPort
    });
    await runner.run('Update settings returns 200', updateResult.status, 200);

    const resp = updateResult.body;
    await runner.runTruthy('Update response contains status field', resp != null && 'status' in resp);
    if (resp) {
      await runner.run('Status is "saved"', resp.status, 'saved');
    }

    // Verify the port was actually saved
    const getResult = await http('GET', BASE_URL + '/api/settings');
    const settings = getResult.body;
    if (settings) {
      await runner.run('Updated port persists', settings.port, testPort);
    }

    // Restore original port (8080) so tests don't affect server state
    await http('PUT', BASE_URL + '/api/settings', { port: 8080 });
  }

  // --- Verify settings page renders with settings data ---

  {
    const page = await browser.newPage();
    await page.goto(BASE_URL + '/settings', { waitUntil: 'networkidle0', timeout: 10000 });

    // Settings form should have submitted or be loadable
    const title = await page.evaluate(() => {
      const h1 = document.querySelector('h1');
      return h1 ? h1.textContent : '';
    });
    await runner.runContains('Settings page title contains "Settings"', title, 'Settings');

    // Save button should exist
    const saveBtn = await page.evaluate(() => {
      const btns = Array.from(document.querySelectorAll('button'));
      return btns.some(b => b.textContent.includes('Save'));
    });
    await runner.runTruthy('Settings page has Save button', saveBtn);

    await page.close();
  }
}

