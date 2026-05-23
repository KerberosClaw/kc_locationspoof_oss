const assert = require('assert');
const fs = require('fs');
const vm = require('vm');

const html = fs.readFileSync('host/web/index.html', 'utf8');
const script = html.match(/<script>([\s\S]*)<\/script>/)[1];
const contentViewSwift = fs.readFileSync('locspoof/ContentView.swift', 'utf8');

assert(
  fs.existsSync('locspoof/Walk/WalkStepTrigger.swift'),
  'Swift walk step trigger should remain available for the native app'
);
const walkStepTriggerSwift = fs.readFileSync('locspoof/Walk/WalkStepTrigger.swift', 'utf8');
assert(contentViewSwift.includes('@StateObject private var walkStepTrigger = WalkStepTrigger()'));
assert(contentViewSwift.includes('walkStepTrigger.attach(walk: walk, status: status)'));
assert(contentViewSwift.includes('Toggle("走路時連動步數更新"'));
assert(walkStepTriggerSwift.includes('@AppStorage("walk_step_trigger_enabled")'));
assert(walkStepTriggerSwift.includes('static let shortcutName = "FlipStepFocus"'));
assert(walkStepTriggerSwift.includes('status.isSpoofing'));

assert(html.includes('.theme-handdrawn .panel-tools'));
assert(html.includes('.theme-handdrawn #locateBtn'));
assert(html.includes('overflow-wrap: anywhere'));
assert(html.includes('value="single"'));
assert(html.includes('value="multi"'));
assert(html.includes('單點模式'));
assert(html.includes('多點模式'));
assert(!html.includes('id="stepTriggerToggle"'));
assert(!html.includes('走路時連動步數更新'));
assert(!html.includes('Mac 控制中心'));
assert(!script.includes('/api/step-trigger'));
assert(!script.includes('triggerStepShortcut'));
assert(!script.includes('STEP_TRIGGER'));
const elements = {};
const injectedLocations = [];
const intervals = new Map();
let nextIntervalId = 1;
function classList() {
  const values = new Set();
  return {
    add(value) { values.add(value); },
    remove(value) { values.delete(value); },
    toggle(value, force) {
      if (force === undefined ? !values.has(value) : force) {
        values.add(value);
        return true;
      }
      values.delete(value);
      return false;
    },
    contains(value) { return values.has(value); }
  };
}
const map = {
  setView() { return this; },
  on() {},
  removeLayer() {}
};
const layer = () => ({
  addTo() { return this; }
});

const context = {
  console,
  setInterval(fn) {
    const id = nextIntervalId++;
    intervals.set(id, fn);
    return id;
  },
  clearInterval(id) {
    intervals.delete(id);
  },
  Math,
  Number,
  Date,
  Promise,
  fetch: async (url) => {
    const value = String(url);
    if (value.startsWith('/api/loc')) {
      const parsed = new URL(value, 'http://127.0.0.1');
      const lat = Number(parsed.searchParams.get('lat'));
      const lon = Number(parsed.searchParams.get('lon'));
      injectedLocations.push({ lat, lon });
      return { json: async () => ({ ok: true, seq: injectedLocations.length }) };
    }
    if (value.startsWith('/api/clear')) {
      return { json: async () => ({ ok: true }) };
    }
    if (value.includes('/api/step-trigger')) {
      throw new Error(`unexpected step trigger request: ${value}`);
    }
    return { json: async () => ({}) };
  },
  confirm: () => true,
  navigator: {},
  document: {
    getElementById(id) {
      if (!elements[id]) {
        elements[id] = {
          disabled: false,
          innerHTML: '',
          textContent: '',
          value: id === 'walkSpeed' ? '4'
            : id === 'walkInterval' ? '10'
            : id === 'themeSelect' ? 'default'
            : '',
          checked: false,
          classList: classList(),
          setAttribute(name, value) { this[name] = value; }
        };
      }
      return elements[id];
    },
    body: {
      classList: classList()
    }
  },
  localStorage: {
    data: {},
    getItem(key) { return this.data[key] || null; },
    setItem(key, value) { this.data[key] = String(value); }
  },
  L: {
    map: () => map,
    tileLayer: layer,
    marker: layer,
    circleMarker: layer,
    circle: layer,
    polyline: layer
  }
};

vm.createContext(context);
vm.runInContext(script, context);

async function runActiveIntervals(limit = 100) {
  for (let i = 0; i < limit; i++) {
    await Promise.resolve();
    if (!intervals.size) {
      await new Promise((resolve) => setImmediate(resolve));
      if (!intervals.size) break;
    }
    const callbacks = [...intervals.values()];
    await Promise.all(callbacks.map((fn) => fn()));
  }
}

(async () => {

assert.strictEqual(typeof context.distanceMeters, 'function');
assert.strictEqual(typeof context.interpolateCoordinate, 'function');
assert.strictEqual(typeof context.buildWalkPoints, 'function');
assert.strictEqual(typeof context.resolveWalkStart, 'function');
assert.strictEqual(typeof context.applyTheme, 'function');
assert.strictEqual(typeof context.setPanelCollapsed, 'function');
assert.strictEqual(typeof context.getMaxMultiTargets, 'function');
assert.strictEqual(typeof context.canAppendMultiTarget, 'function');
assert.strictEqual(typeof context.appendMultiTarget, 'function');
assert.strictEqual(typeof context.setLocation, 'function');
assert.strictEqual(typeof context.startWalkTo, 'function');
assert.strictEqual(typeof context.queueMultiTarget, 'function');

const meters = context.distanceMeters(
  { lat: 25, lon: 121 },
  { lat: 25.001, lon: 121 }
);
assert(Math.abs(meters - 111.2) < 0.5, `expected about 111.2m, got ${meters}`);

const mid = context.interpolateCoordinate(
  { lat: 0, lon: 0 },
  { lat: 10, lon: 20 },
  0.25
);
assert.strictEqual(mid.lat, 2.5);
assert.strictEqual(mid.lon, 5);

const points = context.buildWalkPoints(
  { lat: 25, lon: 121 },
  { lat: 25.001, lon: 121 },
  4,
  10
);
assert(points.length >= 10, `expected multiple walking points, got ${points.length}`);
assert.strictEqual(points[points.length - 1].lat, 25.001);
assert.strictEqual(points[points.length - 1].lon, 121);

const realLocation = { lat: 25, lon: 121 };
const spoofedLocation = { lat: 25.002, lon: 121.002 };
assert.strictEqual(context.resolveWalkStart(null, realLocation), realLocation);
assert.strictEqual(context.resolveWalkStart(spoofedLocation, realLocation), spoofedLocation);

assert.strictEqual(context.getMaxMultiTargets(), 20);
assert.strictEqual(context.canAppendMultiTarget(new Array(19), 0), true);
assert.strictEqual(context.canAppendMultiTarget(new Array(19), 1), false);

const queue = [];
for (let i = 0; i < 20; i++) {
  const added = context.appendMultiTarget(queue, { lat: i, lon: i + 1 });
  assert.strictEqual(added, true, `expected target ${i + 1} to append`);
}
assert.strictEqual(queue.length, 20);
assert.deepStrictEqual(queue[0], { lat: 0, lon: 1 });
assert.deepStrictEqual(queue[19], { lat: 19, lon: 20 });
assert.strictEqual(context.appendMultiTarget(queue, { lat: 99, lon: 100 }), false);
assert.strictEqual(queue.length, 20);

context.applyTheme('default');
assert.strictEqual(elements.themeSelect.value, 'default');
assert.strictEqual(context.document.body.classList.contains('theme-handdrawn'), false);

context.applyTheme('handdrawn');
assert.strictEqual(elements.themeSelect.value, 'handdrawn');
assert.strictEqual(context.document.body.classList.contains('theme-handdrawn'), true);

context.setPanelCollapsed(true);
assert.strictEqual(elements.panel.classList.contains('is-collapsed'), true);
assert.strictEqual(elements.collapseBtn.textContent, '展開');

context.setPanelCollapsed(false);
assert.strictEqual(elements.panel.classList.contains('is-collapsed'), false);
assert.strictEqual(elements.collapseBtn.textContent, '收合');

injectedLocations.length = 0;
await context.setLocation(0, 0);
await context.startWalkTo({ lat: 0, lon: 0.001 }, { mode: 'single' });
elements.modeSelect.value = 'multi';
assert.strictEqual(context.queueMultiTarget({ lat: 0, lon: 0.002 }), true);
await runActiveIntervals();
const finalInjected = injectedLocations[injectedLocations.length - 1];
assert(
  Math.abs(finalInjected.lon - 0.002) < 1e-12,
  `expected queued multi target B to run after single target A, got ${JSON.stringify(finalInjected)}`
);

console.log('walk helpers ok');
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
