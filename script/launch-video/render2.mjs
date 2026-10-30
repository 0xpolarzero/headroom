// Render with supersampling (SS: device scale factor) and motion blur (SUB sub-frames per frame,
// spread over a 180° shutter, averaged by ffmpeg's tmix), then downscale to 1080p with Lanczos.
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { chromium } = require('/Users/polarzero/.npm/_npx/9833c18b2d85bc59/node_modules/playwright-core');
import { spawn } from 'child_process';
import path from 'path';
const dir = path.dirname(new URL(import.meta.url).pathname);
const SS = +(process.env.SS || 2), SUB = +(process.env.SUB || 2), FPS = 60, SHUTTER = .5;
const T0 = +(process.env.T0 || 0), T1 = process.env.T1 ? +process.env.T1 : null;
const browser = await chromium.launch({ executablePath: process.env.HOME + '/Library/Caches/ms-playwright/chromium_headless_shell-1247/chrome-headless-shell-mac-arm64/chrome-headless-shell', args: ['--use-angle=metal', '--enable-gpu'] });
try {
  const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: SS });
  await page.goto('file://' + dir + '/' + (process.env.PAGE || 'launch.html'));
  await page.waitForFunction(() => window.render && document.fonts.status === 'loaded');
  await page.evaluate(() => Promise.all([...document.images].map(i => i.decode())));
  const dur = T1 ?? await page.evaluate(() => window.DURATION), frames = Math.round((dur - T0) * FPS);
  const ff = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(FPS * SUB), '-i', '-',
    '-vf', `tmix=frames=${SUB}:weights=${Array(SUB).fill(1).join(' ')},select='eq(mod(n\\,${SUB})\\,${SUB - 1})',setpts=N/${FPS}/TB,scale=1920:1080:flags=lanczos`,
    '-r', String(FPS), '-c:v', 'libx264', '-preset', 'slow', '-crf', '14', '-pix_fmt', 'yuv420p', '-movflags', '+faststart',
    `${dir}/${process.env.OUT || 'out.mp4'}`], { stdio: ['pipe', 'inherit', 'inherit'] });
  for (let f = 0; f < frames; f++) for (let k = 0; k < SUB; k++) {
    // sub-frames lead up to the frame time, so motion trails behind
    const t = T0 + f / FPS - (SUB - 1 - k) / (SUB - 1 || 1) * SHUTTER / FPS;
    await page.evaluate(t => window.render(Math.max(0, t)), t);
    const png = await page.screenshot({ type: 'png' });
    if (!ff.stdin.write(png)) await new Promise(r => ff.stdin.once('drain', r));
  }
  ff.stdin.end();
  await new Promise(r => ff.on('close', r));
} finally { await browser.close(); }
