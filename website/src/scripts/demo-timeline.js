const demos = [];
let raf = 0;
const reduced = window.matchMedia('(prefers-reduced-motion: reduce)');

function targets(demo, cue) {
  return cue.sel ? demo.root.querySelectorAll(cue.sel) : [demo.root];
}

function apply(demo, cue) {
  for (const el of targets(demo, cue)) {
    if (cue.add) el.classList.add(...[].concat(cue.add));
    if (cue.remove) el.classList.remove(...[].concat(cue.remove));
    if (cue.vars) for (const [k, v] of Object.entries(cue.vars)) el.style.setProperty(k, v);
  }
}

function reset(demo) {
  demo.root.classList.add('is-resetting');
  for (const cue of demo.cues) {
    for (const el of targets(demo, cue)) {
      if (cue.add) el.classList.remove(...[].concat(cue.add));
      if (cue.vars) for (const k of Object.keys(cue.vars)) el.style.removeProperty(k);
    }
  }
  demo.next = 0;
  void demo.root.offsetWidth;
  demo.root.classList.remove('is-resetting');
}

function tick(now) {
  let active = 0;
  for (const demo of demos) {
    if (!demo.running) continue;
    active += 1;
    const t = now - demo.start;
    if (t >= demo.cycle) {
      reset(demo);
      demo.start = now;
      continue;
    }
    while (demo.next < demo.cues.length && demo.cues[demo.next].at <= t) {
      apply(demo, demo.cues[demo.next]);
      demo.next += 1;
    }
  }
  raf = active ? requestAnimationFrame(tick) : 0;
}

function start(demo) {
  reset(demo);
  demo.running = true;
  demo.start = performance.now();
  demo.root.classList.add('is-live');
  if (!raf) raf = requestAnimationFrame(tick);
}

function stop(demo) {
  demo.running = false;
  demo.root.classList.remove('is-live');
  reset(demo);
}

const observer = new IntersectionObserver(
  (entries) => {
    for (const entry of entries) {
      const demo = demos.find((d) => d.root === entry.target);
      if (!demo) continue;
      if (entry.isIntersecting) start(demo);
      else if (demo.running) stop(demo);
    }
  },
  { threshold: 0.35 }
);

function finalize(demo) {
  observer.unobserve(demo.root);
  stop(demo);
  demo.root.classList.add('is-resetting');
  for (const cue of demo.cues) if (cue.at <= demo.finalAt) apply(demo, cue);
  void demo.root.offsetWidth;
  demo.root.classList.remove('is-resetting');
  demo.root.classList.add('is-final');
}

export function mountDemo(root, { cycle, cues, finalAt = cycle }) {
  const demo = { root, cycle, finalAt, cues: [...cues].sort((a, b) => a.at - b.at), next: 0, running: false, start: 0 };
  demos.push(demo);
  if (reduced.matches) finalize(demo);
  else observer.observe(root);
}

reduced.addEventListener('change', () => {
  if (reduced.matches) for (const demo of demos) finalize(demo);
});
