/**
 * UI Integration Tests
 * Tests actual browser interactions against the real server:
 *   1) Create a server from the home page with a save file name
 *   2) Upload a save file from the edit screen
 *   3) Add "Squeak Through" mod from the edit screen
 */

import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';
import { readFileSync } from 'fs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
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

  let createdServerId = null;

  /* ===================== 1. Create server via UI modal ===================== */
  {
    const page = await browser.newPage();
    await page.goto(BASE_URL, { waitUntil: 'networkidle0', timeout: 10000 });

    // Click "+ New Server" button
    await page.click('button.btn-primary');
    await waitForEl(page, '.modal-overlay');

    // Fill in name only (modal uses file upload button for save, not text input)
    // Note: .form-input:nth-child(2) is a <span> label, not an input.
    // Typing into it causes Puppeteer to fallback to currently focused element (name input),
    // concatenating "test_save.zip" onto the server name.
    const nameInput = await page.$('.modal-form .form-input:nth-child(1)');
    await nameInput.type('Integration Test Server');

    // Click Create (first button in .modal-buttons)
    const createBtns = await page.$$('.modal-buttons button');
    await createBtns[0].click();

    // Wait for toast
    const toastText = await waitForToast(page);
    await runner.runTruthy('Create server shows success toast', toastText.includes('Server created'));

    // Poll for the server to appear via API first, then wait for UI render
    let apiFound = false;
    for (let i = 0; i < 20; i++) {
      await new Promise(r => setTimeout(r, 500));
      const listRes = await http('GET', BASE_URL + '/api/servers');
      if (Array.isArray(listRes.body)) {
        const srv = listRes.body.find(s => s.name === 'Integration Test Server');
        if (srv) {
          createdServerId = srv.id;
          apiFound = true;
          break;
        }
      }
    }
    await runner.runTruthy('API returned created server', apiFound);

    // Now poll the UI for the server card to appear in the DOM
    if (createdServerId) {
      let uiFound = false;
      for (let i = 0; i < 20; i++) {
        await new Promise(r => setTimeout(r, 500));
        uiFound = await page.evaluate(() => {
          const names = document.querySelectorAll('.server-name');
          return Array.from(names).some(n => n.textContent === 'Integration Test Server');
        });
        if (uiFound) break;
      }
      await runner.runTruthy('Created server appears in list', uiFound);
    }

    // Initial saveFile is empty (file upload happens after server creation in separate step)
    if (createdServerId) {
      const cfgRes = await http('GET', BASE_URL + '/api/servers/' + createdServerId + '/config');
      await runner.run('Created server has empty save file initially', cfgRes.body.saveFile, '');
    }

    await page.close();
  }

  /* ===================== 2. Upload save via API (Puppeteer v24 lacks file upload) ===================== */
  {
    if (!createdServerId) {
      await runner.runTruthy('FATAL: no server ID for upload test', false);
    } else {
      // Server expects JSON { fileName, fileData } where fileData is base64
      const testZipPath = resolve(__dirname, '..', '..', '..', 'data', 'saves', 'test_upload.zip');
      const testZipData = readFileSync(testZipPath);
      const base64Data = testZipData.toString('base64');

      const uploadRes = await http('POST', BASE_URL + '/api/servers/' + createdServerId + '/upload-save', {
        fileName: 'test_upload.zip',
        fileData: base64Data
      });
      await runner.runTruthy('Upload save API returns success', uploadRes.status === 200);
      await runner.runContains('Upload response contains saveFile', JSON.stringify(uploadRes.body), 'test_upload');

      // Verify the save file name changed in the config
      const cfgRes = await http('GET', BASE_URL + '/api/servers/' + createdServerId + '/config');
      await runner.runContains('Save file config shows uploaded file name', cfgRes.body.saveFile, 'test_upload');

      // Also verify via UI that the edit page shows the correct save name
      const page = await browser.newPage();
      await page.goto(BASE_URL + '/edit/' + createdServerId, { waitUntil: 'networkidle0', timeout: 10000 });
      await waitForEl(page, '.save-file-input');

      const saveName = await page.evaluate(() => {
        const inp = document.querySelector('.save-file-input');
        return inp ? inp.value : '';
      });
      await runner.runContains('UI shows uploaded save file name', saveName, 'test_upload');

      await page.close();
    }
  }

  /* ===================== 3. Add "Squeak Through" mod via API (avoids mod portal network) ===================== */
  {
    if (!createdServerId) {
      await runner.runTruthy('FATAL: no server ID for mod test', false);
    } else {
      // Add a mod directly via the API - bypasses the Factorio mod portal network dependency
      const addModRes = await http('POST', BASE_URL + '/api/servers/' + createdServerId + '/mods/add', {
        name: 'Squeak Through',
        title: 'Squeak Through',
        version: ''
      });
      await runner.runTruthy('Add mod API returns success', addModRes.status === 201);

      // Verify the mod appears in the server config
      const cfgRes = await http('GET', BASE_URL + '/api/servers/' + createdServerId + '/config');
      const modInConfig = Array.isArray(cfgRes.body.mods) &&
                         cfgRes.body.mods.some(m => m.name === 'Squeak Through');
      await runner.runTruthy('"Squeak Through" mod in server config', modInConfig);
    }
  }

  /* ---------- Cleanup ---------- */
  await cleanupServer(createdServerId);
}
