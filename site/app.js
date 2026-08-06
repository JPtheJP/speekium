const REDUCED = matchMedia('(prefers-reduced-motion: reduce)').matches;

/* ============================================================
   0. Hidden tabs freeze transitions mid-flight. Snap everything
      to its end state while we're away, resume when we're back.
   ============================================================ */
const onHide = [];
const root = document.documentElement;
const nav = document.querySelector('nav');

const syncNavSurface = () => nav?.classList.toggle('scrolled', window.scrollY > 24);
syncNavSurface();
addEventListener('scroll', syncNavSurface, { passive: true });

// Also true when the page is opened straight into a background tab. rAF and
// IntersectionObserver are both throttled there, so nothing below may rely
// on them to reach a correct resting state.
if (document.hidden) root.classList.add('settle');
void root.offsetWidth;
root.classList.add('ready');

document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    root.classList.add('settle');
    onHide.forEach(fn => fn());
  } else {
    // Two frames: let the settled styles commit before motion is allowed back.
    requestAnimationFrame(() => requestAnimationFrame(() => root.classList.remove('settle')));
  }
});

/* ============================================================
   1. Scroll reveal
   ============================================================ */
const io = new IntersectionObserver((es) => {
  for (const e of es) {
    if (!e.isIntersecting) continue;
    e.target.classList.add('in');
    io.unobserve(e.target);
  }
}, { threshold: 0.15, rootMargin: '0px 0px -10% 0px' });

document.querySelectorAll('.reveal').forEach(el => {
  // Nobody is watching a background tab; show it rather than risk a blank page.
  if (document.hidden) el.classList.add('in'); else io.observe(el);
});

/* ============================================================
   2. SVG line drawing.

   With vector-effect:non-scaling-stroke the dash pattern is measured in
   SCREEN space, not user units — so a dasharray of getTotalLength() stops
   the line short by exactly the viewBox scale factor. Scale it, and drop
   the dash once drawn so a later resize can never re-clip the path.
   ============================================================ */
function arm(el) {
  const scale = el.getScreenCTM()?.a || 1;
  const len = el.getTotalLength() * scale;
  el.style.strokeDasharray = len;
  el.style.strokeDashoffset = len;
  return len;
}
function release(el, afterMs) {
  el.style.strokeDashoffset = 0;
  setTimeout(() => {
    el.style.strokeDasharray = 'none';
    el.style.strokeDashoffset = '';
  }, afterMs);
}

const glyphs = [...document.querySelectorAll('.draw svg > *')];
glyphs.forEach((el, i) => { arm(el); el.style.setProperty('--i', i % 4); });

const drawIO = new IntersectionObserver((es) => {
  for (const e of es) {
    if (!e.isIntersecting) continue;
    e.target.querySelectorAll('svg > *').forEach((s, i) => release(s, 2000 + i * 130));
    drawIO.unobserve(e.target);
  }
}, { threshold: .45 });

document.querySelectorAll('.draw').forEach(el => {
  if (document.hidden) el.querySelectorAll('svg > *').forEach(s => release(s, 0));
  else drawIO.observe(el);
});

/* ============================================================
   2b. Copy-to-clipboard for the install command.
       navigator.clipboard needs a secure context, so fall back to the
       old execCommand path when the page is opened straight off disk.
   ============================================================ */
document.querySelectorAll('.cmd[data-copy]').forEach(el => {
  el.addEventListener('click', async () => {
    const text = el.dataset.copy;
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.style.cssText = 'position:fixed;opacity:0';
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand('copy'); } catch { /* nothing else to try */ }
      ta.remove();
    }
    el.classList.add('copied');
    clearTimeout(el._t);
    el._t = setTimeout(() => el.classList.remove('copied'), 1800);
  });
});

/* ============================================================
   3. HERO — the headline rolls through languages.
      Chinese is only the first one it happens to say.
   ============================================================ */
(() => {
  // Real code-switched sentences, not translations of "all your languages" —
  // the point isn't that the app speaks seven languages, it's that it follows
  // you across two of them in the same breath. Every pair here is a named,
  // documented mixing pattern (Chinglish, Hinglish, Konglish, Taglish,
  // Spanglish, Franglais) with real usage behind the grammar — e.g. Spanish
  // dev slang actually conjugates loanwords ("pusheaste", not "hiciste
  // push"), and French takes a bare English verb only after "aller + inf."
  // Chinese and Hindi carry two each: they're Canada's two largest
  // international-student populations, and Chinese is the app's original
  // use case. Campus life and dev-desk life both show up, on purpose.
  const PHRASES = [
    ['你帮我 update 一下那个 calendar 吧。', true],
    ['Kal ek important presentation hai.', false],
    ['몇 시에 call 할까요?', true],
    ['Pwede mo bang i-check yung PR ko?', false],
    ['¿Ya pusheaste el branch?', false],
    ['Je vais push ça avant ce soir.', false],
    ['这个 bug 我修了一下午。', true],
    ['Maine yeh PR review kar diya.', false],
  ];
  const HOLD = 2800;

  const roll = document.getElementById('roll');
  if (!roll) return;
  const words = PHRASES.map(([text, cjk], i) => {
    const b = document.createElement('b');
    b.textContent = text;
    if (cjk) b.classList.add('cjk');
    if (i === 0) b.classList.add('on');
    roll.appendChild(b);
    return b;
  });

  if (REDUCED || words.length < 2) return;

  let i = 0;
  setInterval(() => {
    const out = words[i];
    i = (i + 1) % words.length;
    const next = words[i];

    out.classList.replace('on', 'off');
    next.classList.add('on');

    // Once it has left the frame, drop it back below without animating.
    setTimeout(() => {
      out.style.transition = 'none';
      out.classList.remove('off');
      void out.offsetWidth;
      out.style.transition = '';
    }, 950);
  }, HOLD);
})();

/* ============================================================
   4. HUD meter — 14 bars easing toward a moving target, the way
      AppState smooths the mic level. Transform only, so it glides.
   ============================================================ */
(() => {
  const meter = document.getElementById('meter');
  if (!meter) return;
  const N = 14, MIN = .115;
  const bars = [];

  for (let i = 0; i < N; i++) {
    const s = document.createElement('s');
    meter.appendChild(s);
    // Taper the ends: a waveform, not a bar chart.
    const taper = .5 + .5 * Math.sin(((i + 1) / (N + 1)) * Math.PI);
    bars.push({ el: s, taper, v: MIN, target: MIN });
  }

  if (REDUCED) return;

  let live = false;
  new IntersectionObserver(es => { live = es[0].isIntersecting; }, { threshold: .1 })
    .observe(meter.closest('section'));

  let last = 0;
  function frame(ts) {
    requestAnimationFrame(frame);
    if (!live) return;
    if (ts - last > 120) {
      last = ts;
      // Biased upward, or the bars sit near the floor and read as dots.
      for (const b of bars) b.target = MIN + Math.pow(Math.random(), .65) * (1 - MIN);
    }
    for (const b of bars) {
      b.v += (b.target * b.taper - b.v) * .19;   // critically-ish damped
      b.el.style.transform = `scaleY(${Math.max(MIN, b.v)})`;
    }
  }
  requestAnimationFrame(frame);
})();

/* ============================================================
   5. HUD transcript — LocalAgreement-2, dramatised. A trailing
      window stays dim; everything behind it has settled.
   ============================================================ */
(() => {
  const LINES = [
    '帮我 review 一下这个 PR。',
    'この feature、今日中に ship\u00a0できる？',
    '이 버그 fix하고 바로\u00a0deploy할게요.',
    'कल client के साथ एक important meeting\u00a0है।',
    'ช่วย review ไฟล์นี้ก่อน meeting\u00a0ได้ไหม?',
    'இந்த PR-ஐ இன்று review\u00a0பண்ணலாம்.',
    'Write the release notes and send them to the\u00a0team.',
    '¿Puedes revisar el PR antes del\u00a0almuerzo?'
  ];
  const SCENES = [
    { kind:'code', title:'Workspace', state:'Local agent', label:'Prompt', placeholder:'Describe the change…' },
    { kind:'chat', title:'Product team', state:'6 members', label:'You', placeholder:'Say a message…' },
    { kind:'terminal', title:'Local session', state:'zsh', label:'Prompt', placeholder:'Describe what to run…' },
    { kind:'note', title:'Untitled', state:'Writing', label:'Quick note', placeholder:'Start speaking…' },
    { kind:'chat', title:'Project room', state:'4 members', label:'You', placeholder:'Say a message…' },
    { kind:'code', title:'Workspace', state:'Local agent', label:'Prompt', placeholder:'Describe the change…' },
    { kind:'note', title:'Untitled', state:'Writing', label:'Quick note', placeholder:'Start speaking…' },
    { kind:'code', title:'Workspace', state:'Local agent', label:'Prompt', placeholder:'Describe the change…' }
  ];
  const CJK = 44, WORD = 62, PUNCT = 110, HOLD = 500, DONE = 1700, GAP = 950;

  const hud = document.getElementById('hud');
  const line = document.getElementById('line');
  const inner = document.getElementById('inner');
  const caret = document.getElementById('caret');
  const insertText = document.getElementById('insertText');
  const insertLine = insertText?.closest('.insert-line');
  const macWindow = document.getElementById('macWindow');
  const sceneTitle = document.getElementById('sceneTitle');
  const sceneState = document.getElementById('sceneState');
  const insertLabel = document.getElementById('insertLabel');
  if (!hud || !line || !inner || !caret || !macWindow || !sceneTitle || !sceneState || !insertLabel) return;

  let insertSwap = 0, insertDone = 0, pendingInsert = '';
  let sceneTimer = 0, pendingScene = null, sceneInitialized = false;

  function settleInsert(text) {
    if (!insertText || !insertLine) return;
    clearTimeout(insertSwap);
    clearTimeout(insertDone);
    insertText.textContent = text;
    insertText.classList.remove('placeholder', 'fresh');
    insertLine.classList.remove('changing', 'inserting');
  }

  function insert(text) {
    if (!insertText || !insertLine) return;
    pendingInsert = text;
    clearTimeout(insertSwap);
    clearTimeout(insertDone);

    if (REDUCED || document.hidden) { settleInsert(text); return; }

    // Hide the old line before its width changes, reveal the new sentence as
    // one continuous pass, then return the document cursor at the new end.
    insertLine.classList.remove('inserting');
    insertLine.classList.add('changing');
    insertSwap = setTimeout(() => {
      settleInsert(text);
      void insertText.offsetWidth;
      insertText.classList.add('fresh');
      insertLine.classList.add('inserting');
      insertDone = setTimeout(() => insertLine.classList.remove('inserting'), 380);
    }, 90);
  }

  function applyScene(scene) {
    macWindow.dataset.scene = scene.kind;
    sceneTitle.textContent = scene.title;
    sceneState.textContent = scene.state;
    insertLabel.textContent = scene.label;
    pendingInsert = scene.placeholder;
    settleInsert(scene.placeholder);
    insertText.classList.add('placeholder');
  }

  function changeScene(index, immediate = false) {
    const scene = SCENES[index % SCENES.length];
    clearTimeout(sceneTimer);
    pendingScene = scene;

    if (immediate || REDUCED || document.hidden) {
      applyScene(scene);
      macWindow.classList.remove('switching');
      pendingScene = null;
      return;
    }

    macWindow.classList.add('switching');
    // The outgoing scene reaches opacity 0 before the data-scene selector
    // changes, so the two app surfaces can never cross-fade over each other.
    sceneTimer = setTimeout(() => {
      applyScene(scene);
      pendingScene = null;
      requestAnimationFrame(() => requestAnimationFrame(() => macWindow.classList.remove('switching')));
    }, 280);
  }

  onHide.push(() => { if (pendingInsert) settleInsert(pendingInsert); });
  onHide.push(() => {
    if (pendingScene) applyScene(pendingScene);
    pendingScene = null;
    macWindow.classList.remove('switching');
  });

  // Latin arrives as whole words, CJK a character at a time — which is how the
  // model actually emits them, and far smoother than a uniform typewriter.
  // Each token absorbs its trailing space so no empty spans end up in the flow.
  const split = s => s.match(/[A-Za-z0-9][A-Za-z0-9'’-]*\s*|[\s\S]\s*/g) || [];

  const cost = t => {
    const w = t.trim();
    if (/^[，。、,.!?！？]$/.test(w)) return PUNCT;
    if (/^[A-Za-z0-9]/.test(w)) return WORD + Math.min(w.length, 9) * 4;
    return CJK;
  };

  let toks = [], ends = [], events = [], span = 0, clock = 0, at = 0, prev = 0, li = -1;

  // Measure once per line: one forced layout, then every position is cached.
  function build(text) {
    inner.textContent = '';
    toks = split(text).map(t => {
      const s = document.createElement('span');
      s.className = 'tok';
      s.textContent = t;
      inner.appendChild(s);
      return s;
    });
    const left = inner.getBoundingClientRect().left;
    ends = toks.map(s => s.getBoundingClientRect().right - left);

    events = [];
    let t = 0;
    toks.forEach((s, i) => { events.push({ t, i }); t += cost(s.textContent); });
    events.push({ t: t + HOLD, commit: true });
    events.push({ t: t + HOLD + DONE, clear: true });
    span = t + HOLD + DONE + GAP;
  }

  function reveal(i) {
    toks[i].classList.add('shown');
    line.style.width = (ends[i] + 3) + 'px';
    caret.style.transform = `translate3d(${ends[i]}px,-50%,0)`;
  }

  function next() {
    li = (li + 1) % LINES.length;
    if (!sceneInitialized) {
      changeScene(li, true);
      sceneInitialized = true;
    }
    build(LINES[li]);
    hud.dataset.phase = 'live';
    // Snap the caret home rather than let it glide back across the capsule.
    caret.style.transition = 'none';
    caret.style.transform = 'translate3d(0,-50%,0)';
    void caret.offsetWidth;
    caret.style.transition = '';
    clock = 0; at = 0;
  }

  function showStatic() {
    changeScene(0, true);
    sceneInitialized = true;
    build(LINES[0]);
    toks.forEach(s => s.classList.add('shown'));
    line.style.width = (ends[ends.length - 1] + 3) + 'px';
    hud.dataset.phase = 'done';
    insert(LINES[0]);
    // Drop the schedule build() just made, or a resuming loop would replay it
    // from the middle instead of starting a fresh line.
    events = []; span = 0;
  }

  if (REDUCED) { showStatic(); return; }

  let live = false;
  new IntersectionObserver(es => { live = es[0].isIntersecting; }, { threshold: .1 })
    .observe(hud.closest('section'));

  // Wait for the webfont, or the first line is measured in the fallback metrics.
  document.fonts.ready.then(() => {
    // Nothing is scheduled yet, so the first frame that runs calls next()
    // itself — which is also how a background tab picks up when it returns.
    if (document.hidden) showStatic();

    requestAnimationFrame(function frame(ts) {
      requestAnimationFrame(frame);
      if (!live) { prev = ts; return; }
      if (!prev) prev = ts;
      clock += Math.min(ts - prev, 100);   // clamp, so a stall doesn't skip ahead
      prev = ts;

      while (at < events.length && clock >= events[at].t) {
        const e = events[at++];
        if (e.commit) { hud.dataset.phase = 'done'; insert(LINES[li]); } // final pass, then type at the cursor
        else if (e.clear) {
          toks.forEach(s => s.classList.remove('shown'));
          line.style.width = '0px';
          changeScene((li + 1) % LINES.length);
        }
        else reveal(e.i);
      }
      if (clock >= span) next();
    });
  });
})();

/* ============================================================
   6. VOICE SHORTCUTS — a short spoken trigger expands into saved text.
   ============================================================ */
(() => {
  const demo = document.getElementById('shortcutDemo');
  const trigger = document.getElementById('shortcutTrigger');
  const result = document.getElementById('shortcutResult');
  const state = document.getElementById('shortcutState');
  if (!demo || !trigger || !result || !state) return;

  const ITEMS = [
    ['shortcut github', 'https://github.com/yourname'],
    ['shortcut signature', 'Maya Chen · Product Designer'],
    ['shortcut email', 'Thanks — I’ll review this and get back to you shortly.'],
  ];

  let index = 0, live = false, resolveTimer = 0, nextTimer = 0;

  function clear() {
    clearTimeout(resolveTimer);
    clearTimeout(nextTimer);
  }

  function resolved() {
    demo.dataset.phase = 'resolve';
    state.textContent = 'Expanded';
  }

  function cycle() {
    clear();
    const [spoken, replacement] = ITEMS[index];
    trigger.textContent = spoken;
    result.textContent = replacement;
    state.textContent = 'Listening';
    demo.dataset.phase = '';
    void demo.offsetWidth;
    demo.dataset.phase = 'listen';

    if (REDUCED || document.hidden) { resolved(); return; }
    resolveTimer = setTimeout(resolved, 1550);
    nextTimer = setTimeout(() => {
      index = (index + 1) % ITEMS.length;
      cycle();
    }, 4100);
  }

  new IntersectionObserver(es => {
    live = es[0].isIntersecting;
    if (live) cycle(); else clear();
  }, { threshold: .2 }).observe(demo);

  onHide.push(() => { clear(); resolved(); });
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden && live && !REDUCED) cycle();
  });
})();

/* ============================================================
   7. FOOTER — several threads braid past each other, then damp into
      one single line. However many voices go in, one sentence
      comes out. Change THREADS and the figure redraws itself.
   ============================================================ */
(() => {
  const svg = document.getElementById('braid');
  if (!svg) return;

  const W = 1200, MID = 100, AMP = 54;     // viewBox is 0 0 1200 200
  const PERIOD = 620;                      // px per full weave
  const MERGE_FROM = 620, MERGE_TO = 980;  // where the strands resolve into one
  const STEP = 8;

  const threads = [...svg.querySelectorAll('.thread')];
  const beads = [...svg.querySelectorAll('.bead')];
  const N = threads.length;

  // Each strand is the same wave at a different phase, with its amplitude
  // smoothstepped to zero — so they converge onto one line instead of
  // being cut off at it.
  function shape(i) {
    const phase = (i / N) * Math.PI * 2;
    let d = '';
    for (let x = 0; x <= W; x += STEP) {
      const t = Math.min(1, Math.max(0, (x - MERGE_FROM) / (MERGE_TO - MERGE_FROM)));
      const damp = 1 - t * t * (3 - 2 * t);
      const y = MID + AMP * damp * Math.sin((x / PERIOD) * Math.PI * 2 + phase);
      d += (x ? 'L' : 'M') + x + ' ' + y.toFixed(1);
    }
    return d;
  }

  threads.forEach((p, i) => p.setAttribute('d', shape(i)));

  const lens = threads.map(p => p.getTotalLength());
  threads.forEach(arm);
  void svg.getBoundingClientRect();   // commit the undrawn state before releasing

  if (REDUCED) { threads.forEach(p => release(p, 0)); return; }

  threads.forEach((p, i) => {
    p.style.transitionDelay = (i * 0.14) + 's';
    release(p, 2600 + i * 140);
  });

  // A frozen bead stranded mid-thread reads as a bug, so park them.
  onHide.push(() => beads.forEach(b => { b.style.opacity = 0; }));

  const ease = t => t < .5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
  const RUN = 5600, HOLD = 1100, FADE = 700, START = 2300;
  const cycle = RUN + HOLD + FADE;
  let t0 = null;

  requestAnimationFrame(function frame(ts) {
    requestAnimationFrame(frame);
    if (t0 === null) t0 = ts;
    const t = ts - t0 - START;
    if (t < 0) return;

    const p = t % cycle;
    let u, a;
    if (p < RUN) { u = ease(p / RUN); a = Math.min(1, p / 420); }
    else if (p < RUN + HOLD) { u = 1; a = 1; }
    else { u = 1; a = 1 - (p - RUN - HOLD) / FADE; }

    beads.forEach((b, i) => {
      const pt = threads[i].getPointAtLength(u * lens[i]);
      b.setAttribute('cx', pt.x);
      b.setAttribute('cy', pt.y);
      b.style.opacity = a;
    });
  });
})();
