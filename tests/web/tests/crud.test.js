/**
 * Server CRUD Tests
 * Verifies Create, Read, List, Delete operations against the real server.
 * All test instances are prefixed with "test-" for automatic cleanup.
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

  let testServerId = null;

  // --- CREATE ---

  {
    const createResult = await http('POST', BASE_URL + '/api/servers', {
      name: 'Test CRUD Server',
      saveFile: ''
    });
    await runner.run('Create server returns 201', createResult.status, 201);

    const serverBody = createResult.body;
    await runner.runTruthy('Create response contains server object', serverBody);

    if (serverBody) {
      testServerId = serverBody.id;
      await runner.run('Created server has correct name', serverBody.name, 'Test CRUD Server');
      await runner.runTruthy('Created server has ID', testServerId);
    }
  }

  if (!testServerId) {
    await runner.runTruthy('FATAL: Could not create test server', false);
    return;
  }

  // --- LIST ---

  {
    const listResult = await http('GET', BASE_URL + '/api/servers');
    await runner.run('List servers returns 200', listResult.status, 200);

    const servers = listResult.body;
    await runner.runTruthy('List returns an array', Array.isArray(servers));

    if (Array.isArray(servers)) {
      const found = servers.find((s) => s.id === testServerId);
      await runner.runTruthy('Created server appears in list', !!found);
    }
  }

  // --- GET Config ---

  {
    const getResult = await http('GET', BASE_URL + '/api/servers/' + testServerId + '/config');
    await runner.run('Get server config returns 200', getResult.status, 200);

    const cfg = getResult.body;
    await runner.runTruthy('Config response contains server object', cfg);

    if (cfg) {
      await runner.run('Config has correct server name', cfg.name, 'Test CRUD Server');
    }
  }

  // --- UPDATE Config ---

  {
    const updateResult = await http('PUT', BASE_URL + '/api/servers/' + testServerId + '/config', {
      name: 'Updated Test Server',
      maxPlayers: 16
    });
    await runner.run('Update server config returns 200', updateResult.status, 200);

    const cfg = updateResult.body;
    if (cfg) {
      await runner.run('Updated name persists', cfg.name, 'Updated Test Server');
      await runner.run('Updated maxPlayers persists', cfg.maxPlayers, 16);
    }
  }

  // --- DELETE ---

  {
    const deleteResult = await http('DELETE', BASE_URL + '/api/servers/' + testServerId);
    await runner.run('Delete server returns 204', deleteResult.status, 204);
    await runner.run('Delete response body is null (no content)', deleteResult.body, null);
  }

  // --- Verify deletion ---

  {
    const getResult = await http('GET', BASE_URL + '/api/servers/' + testServerId + '/config');
    await runner.run('Deleted server returns 404', getResult.status, 404);

    const listResult = await http('GET', BASE_URL + '/api/servers');
    const servers = listResult.body;
    if (Array.isArray(servers)) {
      const found = servers.find((s) => s.id === testServerId);
      await runner.run('Deleted server no longer in list', !!found, false);
    }
  }

  // --- Verify via UI: server list does not show deleted server ---

  {
    const page = await browser.newPage();
    await page.goto(BASE_URL, { waitUntil: 'networkidle0', timeout: 10000 });

    const serverNamesMatch = await page.evaluate(() => {
      const names = document.querySelectorAll('.server-name');
      return Array.from(names).some(n => n.textContent && n.textContent.includes('Test CRUD'));
    });

    await runner.run('Deleted server not visible in UI', serverNamesMatch, false);
    await page.close();
  }
}
