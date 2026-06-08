import puppeteer from 'puppeteer';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { spawn } from 'child_process';
import { readdir, rm } from 'fs/promises';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const PROJECT_DIR = join(__dirname, '..', '..');
const BASE_URL = 'http://localhost:8080';

/* -----------------------------------------------------------
   Helpers
   ----------------------------------------------------------- */

function haxe(cmd) {
  return new Promise((resolve, reject) => {
    const child = spawn('haxe', [cmd], { cwd: PROJECT_DIR, stdio: 'inherit' });
    child.on('close', (code) => code === 0 ? resolve() : reject(new Error(`haxe ${cmd} failed`)));
  });
}

async function cleanupTestInstances() {
  try {
    const dir = join(PROJECT_DIR, 'data', 'config', 'instances');
    const files = await readdir(dir);
    for (const f of files) {
      if (f.startsWith('test-')) {
        await rm(join(dir, f), { force: true });
      }
    }
  } catch { /* dir may not exist yet */ }
}

/* -----------------------------------------------------------
   Test harness
   ----------------------------------------------------------- */

class TestRunner {
  constructor() {
    this.passed = 0;
    this.failed = 0;
    this.suites = [];
  }

  suite(name, fn) {
    this.suites.push({ name, fn });
  }

  async run(description, actual, expected) {
    const ok = actual === expected;
    if (ok) {
      this.passed++;
      console.log(`  \x1b[32m✓\x1b[0m ${description}`);
    } else {
      this.failed++;
      console.log(`  \x1b[31m✗\x1b[0m ${description}  (expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)})`);
    }
  }

  async runContains(description, haystack, needle) {
    const ok = typeof haystack === 'string' && haystack.includes(needle);
    if (ok) {
      this.passed++;
      console.log(`  \x1b[32m✓\x1b[0m ${description}`);
    } else {
      this.failed++;
      console.log(`  \x1b[31m✗\x1b[0m ${description}  (expected to contain ${JSON.stringify(needle)})`);
    }
  }

  async runTruthy(description, value) {
    const ok = Boolean(value);
    if (ok) {
      this.passed++;
      console.log(`  \x1b[32m✓\x1b[0m ${description}`);
    } else {
      this.failed++;
      console.log(`  \x1b[31m✗\x1b[0m ${description}  (value was falsy: ${JSON.stringify(value)})`);
    }
  }

  summary() {
    console.log('\n======  Results  ======');
    console.log(`  Passed: \x1b[32m${this.passed}\x1b[0m`);
    console.log(`  Failed: \x1b[31m${this.failed}\x1b[0m`);
    return this.failed === 0;
  }
}

/* -----------------------------------------------------------
   Import test suites
   ----------------------------------------------------------- */
import runPageTests from './tests/pages.test.js';
import runCrudTests from './tests/crud.test.js';
import runSettingsTests from './tests/settings.test.js';
import runIntegrationTests from './tests/integration.test.js';
import runLifecycleTests from './tests/server_lifecycle.test.js';

/* -----------------------------------------------------------
   Main
   ----------------------------------------------------------- */
(async () => {
  console.log('======  FactorioServerRunner Web Tests  ======\n');

  // 1. Build server
  console.log('\x1b[1;33mBuilding server...\x1b[0m');
  await haxe('compile_server.hxml');
  console.log('\x1b[32mBuild successful\x1b[0m\n');

  // 2. Build web
  console.log('\x1b[1;33mBuilding web...\x1b[0m');
  await haxe('compile_web.hxml');
  console.log('\x1b[32mWeb build successful\x1b[0m\n');

  // 3. Clean old test instances
  await cleanupTestInstances();

  // 4. Start server
  console.log('\x1b[1;33mStarting server...\x1b[0m');
  const server = spawn('hl', ['dist/server.hl'], {
    cwd: PROJECT_DIR,
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env }
  });

  let serverOutput = '';
  server.stdout.on('data', (d) => { serverOutput += d.toString(); });
  server.stderr.on('data', (d) => { serverOutput += d.toString(); });

  // Wait for server to be ready
  await new Promise((resolve) => setTimeout(resolve, 3000));

  // Verify server is reachable
  try {
    const probe = await fetch(BASE_URL);
    if (!probe.ok) throw new Error(`Server probe failed: ${probe.status}`);
    console.log('\x1b[32mServer ready\x1b[0m\n');
  } catch (err) {
    console.error('\x1b[31mServer failed to start\x1b[0m');
    server.kill('SIGTERM');
    process.exit(1);
  }

  // 5. Launch browser
  const browser = await puppeteer.launch({
    headless: true,
    browser: 'firefox',
    executablePath: '/usr/bin/firefox'
  });

  const runner = new TestRunner();

  try {
    // 6. Run test suites
    console.log('--- Page Rendering ---');
    await runPageTests(browser, runner);

    console.log('\n--- Server CRUD ---');
    await runCrudTests(browser, runner);

    console.log('\n--- Settings ---');
    await runSettingsTests(browser, runner);

    console.log('\n--- UI Integration ---');
    await runIntegrationTests(browser, runner);

    console.log('\n--- Server Lifecycle ---');
    await runLifecycleTests(browser, runner);
  } finally {
    await browser.close();
    server.kill('SIGTERM');
    await cleanupTestInstances();
  }

  const ok = runner.summary();

  // Print server output if any tests failed
  if (!ok && serverOutput.length > 0) {
    console.log('\n======  Server Output (last 3000 chars)  == ====');
    console.log(serverOutput.slice(-3000));
  }

  process.exit(ok ? 0 : 1);
})();
