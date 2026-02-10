const http = require('http');
const puppeteer = require('puppeteer');
const fs = require('fs');
const path = require('path');

const PORT = 18790;
const DEBUG_PORT = 9222;
const USER_DATA_DIR = path.join(__dirname, 'chrome-data');
const COOKIES_FILE = path.join(__dirname, 'cookies.json');

let browser = null;

// Ensure dirs exist
if (!fs.existsSync(USER_DATA_DIR)) fs.mkdirSync(USER_DATA_DIR, { recursive: true });

// Get or launch browser with persistent profile
async function getBrowser() {
  if (browser && browser.connected) return browser;
  console.log('[browser] launching with remote debugging on port', DEBUG_PORT);
  browser = await puppeteer.launch({
    headless: 'new',
    userDataDir: USER_DATA_DIR,
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-dev-shm-usage',
      '--disable-gpu',
      '--no-first-run',
      '--disable-extensions',
      `--remote-debugging-port=${DEBUG_PORT}`,
      '--remote-debugging-address=127.0.0.1'
    ]
  });
  console.log('[browser] launched. Connect via chrome://inspect (port forward 9222)');
  return browser;
}

// Create a page with user agent
async function createPage() {
  const br = await getBrowser();
  const page = await br.newPage();
  await page.setUserAgent(
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
  );
  // Also set extra cookies from cookies.json if they exist
  if (fs.existsSync(COOKIES_FILE)) {
    try {
      const cookies = JSON.parse(fs.readFileSync(COOKIES_FILE, 'utf-8'));
      if (cookies.length > 0) await page.setCookie(...cookies);
    } catch {}
  }
  return page;
}

// Check product availability
async function checkAvailability(url) {
  const page = await createPage();

  try {
    await page.goto(url, { waitUntil: 'networkidle2', timeout: 30000 });

    // Wait for availability block
    try {
      await page.waitForSelector('#product-quantity-block', { timeout: 10000 });
    } catch {}

    const result = await page.evaluate(() => {
      const el = document.getElementById('product-quantity-block');
      if (!el) return { status: 'unknown', quantity: 0, text: 'Availability block not found' };

      const quantity = parseInt(el.getAttribute('data-quantity') || '0', 10);
      const text = el.textContent.trim();
      const classes = el.className;

      return {
        status: quantity > 0 ? 'available' : 'not_available',
        quantity,
        text,
        classes
      };
    });

    const productName = await page.evaluate(() => {
      const h1 = document.querySelector('h1');
      return h1 ? h1.textContent.trim() : '';
    });

    // Check address status
    const addressInfo = await page.evaluate(() => {
      const btn = document.querySelector('.HeaderATDToggler__Link, [data-auth-place="HeaderDeliveryBot"]');
      return {
        hasAddress: btn ? !btn.classList.contains('_no_delivery') : false,
        addressText: btn?.textContent?.trim().substring(0, 100) || ''
      };
    });

    return { ...result, productName, url, ...addressInfo };
  } finally {
    await page.close();
  }
}

// HTTP server
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);

  // Health check
  if (url.pathname === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      status: 'ok',
      browser: browser?.connected || false,
      debugPort: DEBUG_PORT,
      hint: 'SSH port forward 9222, then open chrome://inspect'
    }));
    return;
  }

  // Open vkusvill.ru in browser (for manual setup via DevTools)
  if (url.pathname === '/open') {
    const targetUrl = url.searchParams.get('url') || 'https://vkusvill.ru/';
    try {
      const page = await createPage();
      await page.goto(targetUrl, { waitUntil: 'networkidle2', timeout: 30000 });
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        status: 'opened',
        url: targetUrl,
        hint: 'Page is open. Connect via chrome://inspect to interact manually.'
      }));
    } catch (err) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: err.message }));
    }
    return;
  }

  // Save cookies from current browser session
  if (url.pathname === '/save-cookies') {
    try {
      const br = await getBrowser();
      const pages = await br.pages();
      if (pages.length === 0) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'No pages open' }));
        return;
      }
      const cookies = await pages[0].cookies();
      fs.writeFileSync(COOKIES_FILE, JSON.stringify(cookies, null, 2));
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'saved', count: cookies.length }));
    } catch (err) {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: err.message }));
    }
    return;
  }

  // Check availability
  if (url.pathname === '/check') {
    const productUrl = url.searchParams.get('url');

    if (!productUrl) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Missing url parameter' }));
      return;
    }

    if (!productUrl.includes('vkusvill.ru')) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Only vkusvill.ru URLs are supported' }));
      return;
    }

    try {
      console.log(`[check] ${productUrl}`);
      const result = await checkAvailability(productUrl);
      console.log(`[check] result: ${result.status} (qty=${result.quantity})`);

      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(result));
    } catch (err) {
      console.error(`[check] error: ${err.message}`);
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: err.message }));
    }
    return;
  }

  // 404
  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({
    error: 'Not found',
    endpoints: {
      'GET /health': 'health check',
      'GET /open?url=': 'open URL in browser for manual setup via DevTools',
      'GET /save-cookies': 'save cookies from current browser session',
      'GET /check?url=': 'check product availability'
    }
  }));
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[vv-checker] API on http://127.0.0.1:${PORT}`);
  console.log(`[vv-checker] Chrome DevTools on port ${DEBUG_PORT} (SSH forward to connect)`);
  console.log(`[vv-checker] Setup flow:`);
  console.log(`  1. ssh -L 9222:127.0.0.1:9222 user@server`);
  console.log(`  2. curl http://127.0.0.1:${PORT}/open?url=https://vkusvill.ru/`);
  console.log(`  3. chrome://inspect → Configure → localhost:9222`);
  console.log(`  4. Set address manually in the remote browser`);
  console.log(`  5. curl http://127.0.0.1:${PORT}/save-cookies`);
});

// Pre-launch browser
getBrowser().catch(err => console.error('[browser] failed to launch:', err.message));

// Graceful shutdown
process.on('SIGTERM', async () => {
  console.log('[vv-checker] shutting down...');
  if (browser) await browser.close();
  server.close();
  process.exit(0);
});

process.on('SIGINT', async () => {
  console.log('[vv-checker] shutting down...');
  if (browser) await browser.close();
  server.close();
  process.exit(0);
});
