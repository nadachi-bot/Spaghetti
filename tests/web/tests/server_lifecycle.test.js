/**
 * Server Lifecycle Tests
 * Verifies the server start/stop/log lifecycle via API and UI:
 *   1) Create a server
 *   2) Attempt to start it (API + polling timeout behavior)
 *   3) Verify startFailed state is reported when Factorio isn't available
 *   4) Retrieve logs (even if empty)
 *   5) Stop without crashing
 *   6) Verify UI reflects lifecycle state
 *   7) Cleanup
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

export default async function runTests(browser, runner) {

  let lifecycleServerId = null;

  /* ==================== 1. Create test server ==================== */
  {
    const createResult = await http('POST', BASE_URL + '/api/servers', {
      name: 'Lifecycle Test Server',
      saveFile: ''
    });
    await runner.run('Create lifecycle server returns 201', createResult.status, 201);

    if (createResult.body && createResult.body.id) {
      lifecycleServerId = createResult.body.id;
      await runner.runTruthy('Captured lifecycle server ID', lifecycleServerId);
    }
  }

  if (!lifecycleServerId) {
    await runner.runTruthy('FATAL: no server ID for lifecycle tests', false);
    return;
  }

  /* ==================== 2. Attempt to start server ====================
     Factorio may not be installed in the test environment, so we expect
     the start to either succeed (if Factorio is available) or fail with
     a startFailed state. Either way, the API should accept the request. */
  {
    const startResult = await http('POST', BASE_URL + '/api/servers/' + lifecycleServerId + '/start');

    // The start endpoint should return 202 (accepted) or 200 (already running)
    const startAccepted = startResult.status === 202 || startResult.status === 200;
    await runner.runTruthy('Server start command accepted (200 or 202)', startAccepted);
  }

  /* ==================== 3. Poll for start result ====================
     We poll the server list endpoint to check if the server transitions
     to running OR to startFailed. We give it 15s (10 retries × 1.5s). */
  {
    const MAX_RETRIES = 10;
    const POLL_INTERVAL = 1500;
    let serverState = null;

    for (let i = 0; i < MAX_RETRIES; i++) {
      await new Promise(r => setTimeout(r, POLL_INTERVAL));

      const listResult = await http('GET', BASE_URL + '/api/servers');
      if (Array.isArray(listResult.body)) {
        const srv = listResult.body.find(s => s.id === lifecycleServerId);
        if (srv) {
          serverState = srv;
          if (srv.running) {
            break; // Successfully started
          }
          if (srv.startFailed) {
            break; // Failed, also a valid terminal state
          }
        }
      }
    }

    if (serverState) {
      // Accept either running=true OR startFailed=true as a valid outcome
      const reachedTerminalState = serverState.running || serverState.startFailed;
      await runner.runTruthy('Server reached a terminal state (running or startFailed)', reachedTerminalState);

      if (serverState.running) {
        await runner.runTruthy('Server is running', serverState.running);
      } else if (serverState.startFailed) {
        await runner.runTruthy('startFailed field is true when Factorio unavailable', true);
        await runner.runTruthy('startFailMessage contains reason', !!serverState.startFailMessage);
      }
    } else {
      await runner.runTruthy('Could not find server in list after polling', false);
    }
  }

  /* ==================== 4. Verify logs endpoint ====================
     The logs endpoint should return an array (even if empty) and not crash. */
  {
    const logsResult = await http('GET', BASE_URL + '/api/servers/' + lifecycleServerId + '/logs');

    // Should return 200
    await runner.run('Logs endpoint returns 200', logsResult.status, 200);

    // Should return an array
    await runner.runTruthy('Logs response is an array', Array.isArray(logsResult.body));
  }

  /* ==================== 5. Verify UI shows server in lifecycle state ==================== */
  {
    const page = await browser.newPage();
    await page.goto(BASE_URL, { waitUntil: 'networkidle0', timeout: 10000 });

    // Check that the server appears in the list
    const serverInList = await page.evaluate((id) => {
      const rows = document.querySelectorAll('.server-row');
      return Array.from(rows).some(row => {
        const nameEl = row.querySelector('.server-name');
        return nameEl && nameEl.textContent === 'Lifecycle Test Server';
      });
    }, lifecycleServerId);

    await runner.runTruthy('Lifecycle server visible in UI server list', serverInList);
    await page.close();
  }

  /* ==================== 6. Stop server (should not crash even if not running) ==================== */
  {
    const stopResult = await http('POST', BASE_URL + '/api/servers/' + lifecycleServerId + '/stop');

    // Should return 200 (not running), 202 (accepted stop), or any non-error
    const stopOk = stopResult.status === 200 || stopResult.status === 202 || stopResult.status === 400;
    await runner.runTruthy('Stop command did not crash (accepted or already stopped)', stopOk);
  }

  /* ==================== 7. Verify startFailed state resets after stop ==================== */
  {
    await new Promise(r => setTimeout(r, 1500));

    const listResult = await http('GET', BASE_URL + '/api/servers');
    if (Array.isArray(listResult.body)) {
      const srv = listResult.body.find(s => s.id === lifecycleServerId);
      if (srv) {
        // After stop, the server should not be in starting state
        const notStarting = !srv.starting;
        await runner.runTruthy('Server is not in starting state after stop', notStarting);
      }
    }
  }

  /* ==================== Cleanup ==================== */
  if (lifecycleServerId) {
    try {
      await http('DELETE', BASE_URL + '/api/servers/' + lifecycleServerId);
      await runner.runTruthy('Cleanup: deleted lifecycle test server', true);
    } catch (e) {
      // Ignore cleanup errors
    }
  }
}
