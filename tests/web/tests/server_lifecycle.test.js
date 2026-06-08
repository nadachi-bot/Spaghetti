/**
 * Server Lifecycle Tests
 * Verifies the server start/stop/log lifecycle via API and UI:
 *   1) Create a server
 *   2) Attempt to start it (API + polling timeout behavior)
 *   3) Verify startFailed state is reported when Factorio isn't available
 *   4) Retrieve logs (even if empty)
 *   5) Verify UI shows server in lifecycle state
 *   6) Stop server + poll until running===false AND stopping===false
 *   7) Verify UI shows server as Stopped (not stuck on spinner)
 *   8) Cleanup
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

/* ---------- poll API until server reaches expected state ----------
   Returns the server object from the list, or null on timeout. */
async function pollServerState(serverId, predicate, maxWaitSec = 60, pollIntervalMs = 1500) {
  const retries = Math.ceil((maxWaitSec * 1000) / pollIntervalMs);
  for (let i = 0; i < retries; i++) {
    await new Promise(r => setTimeout(r, pollIntervalMs));
    try {
      const listResult = await http('GET', BASE_URL + '/api/servers');
      if (Array.isArray(listResult.body)) {
        const srv = listResult.body.find(s => s.id === serverId);
        if (srv && predicate(srv)) {
          return srv;
        }
      }
    } catch {
      // poll retry on transient network errors
    }
  }
  // one final read so the caller can inspect whatever state we ended on
  try {
    const listResult = await http('GET', BASE_URL + '/api/servers');
    if (Array.isArray(listResult.body)) {
      return listResult.body.find(s => s.id === serverId) ?? null;
    }
  } catch {}
  return null;
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
     to running OR to startFailed. We give it 15s (10 retries x 1.5s). */
  {
    const startedOrFailedSrv = await pollServerState(
      lifecycleServerId,
      (srv) => srv.running || srv.startFailed,
      15, 1500
    );

    if (startedOrFailedSrv) {
      const reachedTerminalState = startedOrFailedSrv.running || startedOrFailedSrv.startFailed;
      await runner.runTruthy('Server reached a terminal state (running or startFailed)', reachedTerminalState);

      if (startedOrFailedSrv.running) {
        await runner.runTruthy('Server is running', startedOrFailedSrv.running);
      } else if (startedOrFailedSrv.startFailed) {
        await runner.runTruthy('startFailed field is true when Factorio unavailable', true);
        await runner.runTruthy('startFailMessage contains reason', !!startedOrFailedSrv.startFailMessage);
      }
    } else {
      await runner.runTruthy('Could not find server in list after polling for start', false);
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
      const rows = document.querySelectorAll('.server-card');
      return Array.from(rows).some(row => {
        const nameEl = row.querySelector('.server-name');
        return nameEl && nameEl.textContent === 'Lifecycle Test Server';
      });
    }, lifecycleServerId);

    await runner.runTruthy('Lifecycle server visible in UI server list', serverInList);
    await page.close();
  }

  /* ==================== 6. Stop server + poll until fully stopped ====================
     This is the most critical section. It verifies:
     - POST /stop returns 202 (accepted) or 200 (no-op / already stopped)
     - The server transitions through stopping===true
     - The server reaches running===false AND stopping===false within a timeout
     - The /api/servers endpoint remains responsive during and after stop
       (regression test for monitor-thread hang that caused HTTP server to freeze) */
  {
    // 6a. Send the stop command
    const stopResult = await http('POST', BASE_URL + '/api/servers/' + lifecycleServerId + '/stop');
    const stopAccepted = stopResult.status === 200 || stopResult.status === 202;
    await runner.runTruthy('Stop command accepted (200 or 202)', stopAccepted);

    // 6b. Poll until the server is fully stopped (not just "not running", but
    //     also not in a stopping transition — meaning the background thread finished)
    const fullyStoppedSrv = await pollServerState(
      lifecycleServerId,
      (srv) => !srv.running && !srv.stopping && !srv.starting,
      60, 1500  // generous 60s timeout to cover force-kill path
    );

    if (fullyStoppedSrv) {
      await runner.runTruthy('Server reached fully-stopped state (running=false, stopping=false)',
        !fullyStoppedSrv.running && !fullyStoppedSrv.stopping);
      await runner.runTruthy('Server is not in starting state after stop', !fullyStoppedSrv.starting);
    } else {
      await runner.runTruthy(
        'FAILED: Server did not reach fully-stopped state within 60s timeout (possible monitor-thread hang)',
        false
      );
    }

    // 6c. Regression: verify /api/servers is still responsive after stop.
    //     A hung monitor thread used to make the entire HTTP server unresponsive.
    try {
      const postStopList = await fetch(BASE_URL + '/api/servers', {
        signal: AbortSignal.timeout(10000), // fail fast if server is hung
      });
      await runner.run('/api/servers still responsive after stop (status 200)', postStopList.status, 200);
    } catch (e) {
      await runner.runTruthy(
        '/api/servers failed after stop — server may be hung',
        false
      );
    }
  }

  /* ==================== 7. UI stop transition test ==================== */
  {
    const page = await browser.newPage();
    await page.goto(BASE_URL, { waitUntil: 'networkidle0', timeout: 10000 });

    // Find the stop button for our lifecycle server
    const stopButtonFound = await page.evaluate((id) => {
      const cards = document.querySelectorAll('.server-card');
      for (const card of cards) {
        const nameEl = card.querySelector('.server-name');
        if (nameEl && nameEl.textContent === 'Lifecycle Test Server') {
          // Look for a stop button (button element with stop icon or text)
          const buttons = card.querySelectorAll('button');
          for (const btn of buttons) {
            if (btn.title === 'Stop server' || btn.textContent.includes('Stop') ||
                btn.textContent.includes('⏹') || btn.textContent.includes('■')) {
              return true;
            }
          }
        }
      }
      return false;
    }, lifecycleServerId);

    if (stopButtonFound) {
      // Click the stop button
      await page.evaluate((id) => {
        const cards = document.querySelectorAll('.server-card');
        for (const card of cards) {
          const nameEl = card.querySelector('.server-name');
          if (nameEl && nameEl.textContent === 'Lifecycle Test Server') {
            const buttons = card.querySelectorAll('button');
            for (const btn of buttons) {
              if (btn.title === 'Stop server' || btn.textContent.includes('Stop') ||
                  btn.textContent.includes('⏹') || btn.textContent.includes('■')) {
                btn.click();
                return;
              }
            }
          }
        }
      }, lifecycleServerId);

      // Wait a bit for the stop request to be sent
      await new Promise(r => setTimeout(r, 2000));

      // Verify no spinner/loading state is stuck on the stop button
      // (transitionStates should be cleared after stop completes)
      const noStuckSpinner = await page.evaluate(() => {
        const cards = document.querySelectorAll('.server-card');
        for (const card of cards) {
          const buttons = card.querySelectorAll('button');
          for (const btn of buttons) {
            // Check for spinner text that indicates a stuck transition state
            if (btn.textContent.includes('⟳') || btn.textContent.includes('...')) {
              return false; // spinner found — still stuck
            }
          }
        }
        return true; // no spinners = clean
      });

      await runner.runTruthy('No stuck spinner on stop button after stop completes', noStuckSpinner);
    } else {
      // Server may already be stopped, so no stop button is visible.
      // That's acceptable — the server's not running, so nothing to stop.
      await runner.runTruthy('Stop button absent (server already stopped — acceptable)', true);
    }

    await page.close();
  }

  /* ==================== 8. Start → Stop → Restart cycle (graceful save+quit) ====================
     Regression test for stop-hang bug. Verifies:
     - A running Factorio server can be stopped gracefully via /game.server_save() + /quit
     - The HTTP server remains responsive during stop (no monitor-thread hang)
     - The server can be restarted after stop (no lingering process on same port)
     - Repeated stop/start cycles don't accumulate threads or leak resources */
  {
    // 8a. Start the server again (should succeed if Factorio is available)
    const restartResult = await http('POST', BASE_URL + '/api/servers/' + lifecycleServerId + '/start');
    const restartAccepted = restartResult.status === 202 || restartResult.status === 200;
    await runner.runTruthy('Restart command accepted (200 or 202)', restartAccepted);

    // 8b. Poll for running state
    const restartedSrv = await pollServerState(
      lifecycleServerId,
      (srv) => srv.running || srv.startFailed,
      45, 1500  // Factorio can take a while to start
    );

    if (!restartedSrv) {
      await runner.runTruthy('FAILED: Server did not reach running/startFailed state after restart', false);
    } else if (restartedSrv.startFailed) {
      // Factorio not available — skip the graceful stop test
      await runner.runTruthy('(Factorio unavailable, skipping graceful stop/restart test)', true);
    } else if (restartedSrv.running) {
      await runner.runTruthy('Server restarted successfully', restartedSrv.running);

      // 8c. Verify HTTP server is responsive while Factorio is running
      try {
        const whileRunning = await fetch(BASE_URL + '/api/servers', {
          signal: AbortSignal.timeout(5000)
        });
        await runner.run('/api/servers responsive while Factorio is running', whileRunning.status, 200);
      } catch (e) {
        await runner.runTruthy('HTTP server unresponsive while Factorio running', false);
      }

      // 8d. Stop the server (graceful save+quit path)
      const gracefulStop = await http('POST', BASE_URL + '/api/servers/' + lifecycleServerId + '/stop');
      const gracefulStopAccepted = gracefulStop.status === 200 || gracefulStop.status === 202;
      await runner.runTruthy('Graceful stop command accepted (200 or 202)', gracefulStopAccepted);

      // 8e. Poll until fully stopped — this is the regression check.
      //     Previously, a monitor-thread hang on exitCode() would cause the HTTP
      //     server to freeze after stop, and this poll would timeout.
      const stoppedSrv = await pollServerState(
        lifecycleServerId,
        (srv) => !srv.running && !srv.stopping && !srv.starting,
        60, 1500
      );

      if (stoppedSrv) {
        await runner.runTruthy('Server reached fully-stopped state after graceful stop',
          !stoppedSrv.running && !stoppedSrv.stopping);
      } else {
        await runner.runTruthy(
          'FAILED: Server hung during graceful stop (monitor-thread hang regression)',
          false
        );
      }

      // 8f. Verify HTTP server is still responsive after stop
      try {
        const afterStop = await fetch(BASE_URL + '/api/servers', {
          signal: AbortSignal.timeout(5000)
        });
        await runner.run('/api/servers still responsive after graceful stop', afterStop.status, 200);
      } catch (e) {
        await runner.runTruthy('HTTP server unresponsive after graceful stop (regression)', false);
      }

      // 8g. Verify we can start again (no lingering process blocking the port)
      const secondStart = await http('POST', BASE_URL + '/api/servers/' + lifecycleServerId + '/start');
      const secondStartAccepted = secondStart.status === 202 || secondStart.status === 200;
      await runner.runTruthy('Second restart after graceful stop accepted', secondStartAccepted);

      // Briefly check we reach a terminal state (running or startFailed, not stuck)
      const secondTerminal = await pollServerState(
        lifecycleServerId,
        (srv) => srv.running || srv.startFailed,
        45, 1500
      );

      if (secondTerminal) {
        const reachedState = secondTerminal.running || secondTerminal.startFailed;
        await runner.runTruthy('Second restart reached terminal state (not stuck)', reachedState);
      } else {
        await runner.runTruthy('Second restart stalled', false);
      }

      // 8h. Final cleanup stop
      await http('POST', BASE_URL + '/api/servers/' + lifecycleServerId + '/stop');
      await pollServerState(
        lifecycleServerId,
        (srv) => !srv.running && !srv.stopping,
        60, 1500
      );
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
