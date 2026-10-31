const calm = matchMedia('(prefers-reduced-motion: reduce)').matches;
const $ = id => document.getElementById(id);

/* ---------- The tube: the page drains as you read it ---------- */
const tubeLabel = document.querySelector('.tube-label');
function drain() {
  const room = document.documentElement.scrollHeight - innerHeight;
  const left = room > 0 ? Math.max(0, 1 - scrollY / room) : 1;
  document.documentElement.style.setProperty('--left', left);
  tubeLabel.textContent = left < 0.02 ? 'last drop' : `${Math.round(left * 100)}% left`;
}
addEventListener('scroll', drain, { passive: true });
addEventListener('resize', drain);
drain();

/* ---------- The hero: drops fall and ripple; a click makes one too ---------- */
const canvas = $('ripples'), hero = canvas.parentElement, pen = canvas.getContext('2d');
const DROP = new Path2D('M0 -22 C0 -22 -14 -5 -14 6 A14 14 0 0 0 14 6 C14 -5 0 -22 0 -22 Z');
const FALL = 900, LIFE = 3200;
let drops = [], width = 0, height = 0, nextDrop = 0, heroVisible = true;

function size() {
  const scale = Math.min(devicePixelRatio, 2);
  width = hero.clientWidth; height = hero.clientHeight;
  canvas.width = width * scale; canvas.height = height * scale;
  pen.setTransform(scale, 0, 0, scale, 0, 0);
}
function color() { return getComputedStyle(document.documentElement).getPropertyValue('--accent').trim(); }
function addDrop(x, y, now, fall = FALL) { drops.push({ x, y, start: now, fall }); }
function ring(x, y, r, alpha, tint) {
  if (r <= 0) return;
  pen.globalAlpha = alpha; pen.strokeStyle = tint; pen.lineWidth = 1;
  pen.beginPath(); pen.ellipse(x, y, r, r * 0.3, 0, 0, Math.PI * 2); pen.stroke();
}
function paint(now) {
  pen.clearRect(0, 0, width, height);
  const tint = color(), reach = Math.max(width, height) * 0.5;
  drops = drops.filter(d => now - d.start < d.fall + LIFE);
  for (const d of drops) {
    const t = now - d.start;
    if (t < d.fall) {
      const p = t / d.fall, y = d.y * p * p, stretch = 1 + p * 0.35;
      pen.save(); pen.translate(d.x, y); pen.scale(0.42 / Math.sqrt(stretch), 0.42 * stretch);
      pen.globalAlpha = 0.55 * Math.min(1, p * 5); pen.fillStyle = tint; pen.fill(DROP); pen.restore();
    } else {
      const a = (t - d.fall) / LIFE;
      for (let k = 0; k < 4; k++) ring(d.x, d.y, (a - k * 0.08) * reach, 0.42 * (1 - a) ** 2, tint);
    }
  }
  pen.globalAlpha = 1;
}
function frame(now) {
  if (heroVisible) {
    if (now > nextDrop) {
      const side = Math.random() < 0.5 ? 0.06 + Math.random() * 0.17 : 0.77 + Math.random() * 0.17;
      addDrop(width * side, height * (0.62 + Math.random() * 0.3), now);
      nextDrop = now + 2600 + Math.random() * 2200;
    }
    paint(now);
  }
  requestAnimationFrame(frame);
}
size();
addEventListener('resize', size);
if (calm) {
  const tint = color();
  for (const r of [120, 220, 340]) ring(width / 2, height * 0.8, r, 0.2, tint);
} else {
  new IntersectionObserver(([entry]) => { heroVisible = entry.isIntersecting; }).observe(hero);
  hero.addEventListener('pointerdown', event => {
    if (event.target.closest('a')) return;
    const box = hero.getBoundingClientRect();
    addDrop(event.clientX - box.left, event.clientY - box.top, performance.now(), 0);
  });
  addDrop(width / 2, height * 0.9, performance.now(), 1100);
  nextDrop = performance.now() + 2400;
  requestAnimationFrame(frame);
}

/* ---------- The pool: the real rule, on sample accounts ---------- */
const ACCOUNTS = [
  { plan: 'Claude', name: 'Max', start: 58 },
  { plan: 'Claude', name: 'Team', start: 84 },
  { plan: 'Codex', name: 'Pro', start: 66 },
  { plan: 'Codex', name: 'Plus', start: 38 },
  { plan: 'Antigravity', name: 'Ultra', start: 92 },
  { plan: 'Z.ai', name: 'Coding', start: 72 },
];
const AGENTS = [
  { name: 'reviewer', steps: [['Codex', 'gpt-6.1-sol'], ['Z.ai', 'glm-5.3']] },
  { name: 'advisor', steps: [['Antigravity', 'gemini-4-argon']] },
  { name: 'builder', steps: [['Claude', 'sonnet-5.5'], ['Z.ai', 'glm-5.3']] },
];
const COSTS = [22, 17, 26, 19], LOG_LINES = 3;
let picked = -1, runs = 0;
const pool = $('pool'), log = $('log');

pool.innerHTML = ACCOUNTS.map((a, i) => `<div class="glass" id="glass${i}"><div class="glass-water"></div>
  <div class="glass-text">${a.plan}<span>${a.name}</span></div><div class="glass-left"></div></div>`).join('');
$('runs').innerHTML = AGENTS.map((a, i) => `<button class="run" type="button" data-agent="${i}">${a.name}<span>${a.steps.map(s => s[1]).join(' → ')}</span></button>`).join('');

function showPool() {
  ACCOUNTS.forEach((a, i) => {
    const glass = $('glass' + i);
    glass.style.setProperty('--level', a.left);
    glass.classList.toggle('low', a.left < 25);
    glass.classList.remove('picked');
    glass.querySelector('.glass-left').textContent = `${a.left}%`;
  });
  if (picked >= 0) { const glass = $('glass' + picked); void glass.offsetWidth; glass.classList.add('picked'); }
}
function addLog(html) {
  log.querySelector('.log-empty')?.remove();
  log.insertAdjacentHTML('beforeend', `<li>${html}</li>`);
  while (log.children.length > LOG_LINES) log.firstElementChild.remove();
}
function refill() {
  ACCOUNTS.forEach(a => { a.left = a.start; });
  picked = -1; runs = 0;
  log.innerHTML = '<li class="log-empty">Pick an agent.</li>';
  showPool();
}
function run(agent) {
  for (const [i, [plan, model]] of agent.steps.entries()) {
    const open = ACCOUNTS.filter(a => a.plan === plan && a.left > 0).sort((x, y) => y.left - x.left);
    if (!open.length) { addLog(`<span class="warm">${plan} has nothing left, next in the list</span>`); continue; }
    const account = open[0];
    account.left = Math.max(0, account.left - COSTS[runs++ % COSTS.length]);
    picked = ACCOUNTS.indexOf(account);
    addLog(`<b>${agent.name}</b> → ${plan} ${account.name} · ${model} · ${account.left}% left`);
    showPool();
    return;
  }
  picked = -1;
  showPool();
  const dry = ACCOUNTS.every(a => a.left === 0);
  addLog(dry ? '<span class="warm">That was the last drop.</span>' : `<span class="warm">${agent.name} can't start: every model in its list is out.</span>`);
}
$('runs').addEventListener('click', event => {
  const button = event.target.closest('[data-agent]');
  if (button) run(AGENTS[button.dataset.agent]);
});
$('refill').addEventListener('click', refill);
refill();

/* ---------- The panel: real screenshots, with their tabs live ---------- */
const VIEWS = {
  limits: { word: 'limit', image: 'panel-limits.png', height: 1104, text: 'Usage left on each account, and when it resets.' },
  agents: { word: 'agent', image: 'panel-agents.png', height: 754, text: 'Turn agents on and off, and see what each one falls back on.' },
  stats: { word: 'stat', image: 'panel-stats.png', height: 1332, text: 'Tokens, API prices and agents by day, project, account and model. Open a project.' },
  project: { word: 'project', image: 'panel-project.png', height: 998, text: 'Who did the work on a project: you, or your agents, and on which models.' },
};
for (const view of Object.values(VIEWS)) new Image().src = `media/${view.image}`;
const PROJECT_ROW = { top: 594, height: 44 };   // the atlas row, in screenshot pixels
function showView(name) {
  const view = VIEWS[name], image = $('panel-image');
  image.src = `media/${view.image}`; image.height = view.height;
  image.alt = `The lastdrop panel, ${name} view`;
  $('glance-word').textContent = view.word;
  $('glance-text').textContent = view.text;
  $('hot-project').hidden = name !== 'stats';
  $('hot-back').hidden = name !== 'project';
  const hot = $('hot-project');
  hot.style.top = `${(PROJECT_ROW.top / view.height) * 100}%`;
  hot.style.height = `${(PROJECT_ROW.height / view.height) * 100}%`;
}
$('panel').addEventListener('click', event => {
  const button = event.target.closest('[data-view]');
  if (button) showView(button.dataset.view);
});

/* ---------- The last drop: it fills the download button ---------- */
const download = $('download'), button = $('final-download'), lastDrop = $('last-drop');
if (!calm) {
  button.classList.add('dry');
  new IntersectionObserver(([entry], watcher) => {
    if (!entry.isIntersecting) return;
    watcher.disconnect();
    download.style.setProperty('--fall', `${button.offsetTop - 18}px`);
    download.classList.add('falling');
    lastDrop.addEventListener('animationend', () => {
      button.classList.remove('dry');
      button.classList.add('hit');
    }, { once: true });
  }, { threshold: 0.65 }).observe(download);
}

$('copy').addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText($('copy').querySelector('code').textContent);
    $('copy-state').textContent = 'Copied';
    setTimeout(() => { $('copy-state').textContent = 'Copy'; }, 1600);
  } catch { /* Selecting the text by hand still works. */ }
});
