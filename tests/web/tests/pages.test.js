/**
 * Page Rendering Tests
 * Verifies the SPA pages load correctly, overlays are not stuck, and key elements are present.
 */

const BASE_URL = 'http://localhost:8080';

export default async function runTests(browser, runner) {

  // --- Servers Page ---

  {
    const page = await browser.newPage();
    await page.goto(BASE_URL, { waitUntil: 'networkidle0', timeout: 10000 });

    // The modal overlays should have the "hidden" class on load
    const overlaysHidden = await page.evaluate(() => {
      const overlays = document.querySelectorAll('.log-modal, .console-modal');
      if (overlays.length === 0) return false;
      return Array.from(overlays).every(el => el.classList.contains('hidden'));
    });
    await runner.runTruthy('Log/Console modals are hidden on page load', overlaysHidden);

    // Page title should be present
    const title = await page.evaluate(() => {
      const h1 = document.querySelector('h1.page-title');
      return h1 ? h1.textContent : '';
    });
    await runner.runContains('Servers page has correct title', title, 'Spaghetti');

    // Navigation bar should have Servers and Settings links
    const navLinks = await page.evaluate(() => {
      return Array.from(document.querySelectorAll('.nav-link')).map(el => el.textContent);
    });
    await runner.runTruthy('Nav contains Servers link', navLinks.includes('Servers'));
    await runner.runTruthy('Nav contains Settings link', navLinks.includes('Settings'));

    // "+ New Server" button should be visible
    const newServerBtn = await page.evaluate(() => {
      const btns = Array.from(document.querySelectorAll('button'));
      return btns.some(b => b.textContent.trim() === '+ New Server');
    });
    await runner.run('+ New Server button exists', newServerBtn, true);

    // Server list container should exist
    const serverList = await page.evaluate(() => {
      return document.querySelector('.server-list') !== null;
    });
    await runner.runTruthy('Server list container exists', serverList);

    await page.close();
  }

  // --- Settings Page ---

  {
    const page = await browser.newPage();
    await page.goto(BASE_URL + '/settings', { waitUntil: 'networkidle0', timeout: 10000 });

    // Settings page should have a title
    const title = await page.evaluate(() => {
      const h1 = document.querySelector('h1');
      return h1 ? h1.textContent : '';
    });
    await runner.runContains('Settings page has title', title, 'Settings');

    // Settings form should have port input
    const portInput = await page.evaluate(() => {
      const inputs = document.querySelectorAll('input');
      let found = null;
      for (const inp of inputs) {
        if (inp.type === 'number' || inp.getAttribute('data-setting') === 'port') {
          found = inp;
          break;
        }
      }
      return found ? true : false;
    });
    await runner.runTruthy('Settings page has port input', portInput);

    await page.close();
  }

  // --- Edit Page (404 or empty for non-existent server ID) ---
  // We skip detailed edit page testing here; CRUD tests cover the edit flow.

  // --- SPA Routing ---

  {
    const page = await browser.newPage();
    await page.goto(BASE_URL + '/edit/nonexistent', { waitUntil: 'networkidle0', timeout: 10000 });

    // Edit page should have loaded (even if server not found)
    const title = await page.evaluate(() => {
      const h1 = document.querySelector('h1');
      return h1 ? h1.textContent : '';
    });
    await runner.runContains('Edit page renders for any ID', title, 'Edit');

    await page.close();
  }
}
