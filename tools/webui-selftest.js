/* Lite 版 WebUI 自检：用极简 DOM 桩把 module/webroot/index.html 真跑一遍。
   目的不是替代浏览器，而是抓运行时错误、命令拼装错误与状态文案错误。

   用法：node tools/webui-selftest.js
   退出码 0 = 全部通过；1 = 有失败（CI 里会拦下来）。 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');

/* ---------------------------------------------------------------- DOM 桩 */
class ClassList {
  constructor(node) { this.node = node; this.set = new Set(); }
  _sync() { this.node._className = [...this.set].join(' '); }
  add(...c) { c.forEach(x => x && this.set.add(x)); this._sync(); }
  remove(...c) { c.forEach(x => this.set.delete(x)); this._sync(); }
  contains(c) { return this.set.has(c); }
}

class Node {
  constructor(tag) {
    this.tagName = String(tag || '').toUpperCase();
    this.children = []; this.parent = null;
    this._text = ''; this._className = '';
    this.classList = new ClassList(this);
    this.style = {}; this.dataset = {}; this.attrs = {};
    this.handlers = {};
    this.value = ''; this.disabled = false; this.id = '';
  }
  get className() { return this._className; }
  set className(v) {
    this._className = v || '';
    this.classList.set = new Set(String(v || '').split(/\s+/).filter(Boolean));
  }
  get textContent() {
    if (this.children.length === 0) return this._text;
    return this.children.map(c => c.textContent).join('');
  }
  set textContent(v) { this._text = String(v == null ? '' : v); this.children = []; }
  appendChild(n) { if (!n) return n; n.parent = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  addEventListener(type, fn) { (this.handlers[type] = this.handlers[type] || []).push(fn); }
  async fire(type) {
    for (const fn of (this.handlers[type] || [])) await fn({ type });
  }
  querySelector() { return null; }
  querySelectorAll() { return []; }
}

const IDS = {};
/* 所有通过 #id 取到的节点都必须挂到 documentElement 下 —— 否则下面基于遍历的
   allByClass()/switches() 找不到它们（第一版就踩了这个：switches() 返回空数组）。 */
const ROOT = new Node('html');
function nodeForId(id) {
  if (!IDS[id]) { IDS[id] = new Node('div'); IDS[id].id = id; ROOT.appendChild(IDS[id]); }
  return IDS[id];
}

const documentStub = {
  documentElement: ROOT,
  createElement: t => new Node(t),
  querySelector(sel) {
    const m = /^#([\w-]+)$/.exec(sel);
    return m ? nodeForId(m[1]) : null;
  },
  querySelectorAll(sel) {
    // 桩只需要支持 "button" 这一种（setBusy 用它统一置 disabled）
    if (sel !== 'button') return [];
    const out = [];
    (function w(n) { for (const c of n.children) { if (c.tagName === 'BUTTON') out.push(c); w(c); } })(ROOT);
    return out;
  }
};
ROOT.dataset = {};

globalThis.document = documentStub;

/* ---------------------------------------------------------------- 假 ksu.exec */
const CALLS = [];
const CFG = { FIX_POWERKEEPER: 1, FIX_BPFMON: 1, FIX_TELEPHONY: 1 };
const STATE = {
  NEED_APP: 0, VERSION: 'v1.0',
  BPFMON_SVC: 'stopped', BPFMON_RUNNING: 0,
  POWERKEEPER_MOUNTED: 1, POWERKEEPER_SEEN: 1, POWERKEEPER_PAYLOAD: 1,
  TELEPHONY_DONE: 1, TELEPHONY_STATE: ' com.qti.phone:absent',
  MARKERS: ''
};
let JSON_BROKEN = false;

function jsonOut() {
  if (JSON_BROKEN) return '';
  return JSON.stringify(Object.assign({}, CFG, STATE));
}

const ksu = {
  exec: async (cmd) => {
    CALLS.push(cmd);
    if (cmd.includes('--json')) return jsonOut();
    if (cmd.includes('--set')) {
      const m = /--set\s+([A-Za-z_][A-Za-z0-9_]*)\s+(\S+)/.exec(cmd);
      if (m) CFG[m[1]] = Number(m[2]);
      return '';
    }
    if (cmd.includes('--sepolicy')) return '';
    if (cmd.includes('--status')) return 'TB378FC HyperOS 修复 Lite  v1.0\n② PowerKeeper 补丁     : 1';
    return '';
  }
};

globalThis.window = { matchMedia: () => ({ matches: false }), ksu: ksu };
globalThis.ksu = ksu;

/* ---------------------------------------------------------------- 加载被测页面 */
const HTML = fs.readFileSync(path.join(__dirname, '..', 'module', 'webroot', 'index.html'), 'utf8');
const scriptMatch = /<script>([\s\S]*?)<\/script>/.exec(HTML);
if (!scriptMatch) { console.log('✗ index.html 里找不到 <script> 块'); process.exit(1); }
vm.runInThisContext(scriptMatch[1], { filename: 'webroot/index.html' });

/* ---------------------------------------------------------------- 工具 */
const sleep = ms => new Promise(r => setTimeout(r, ms));

function walk(node, pred, out) {
  out = out || [];
  for (const c of node.children) { if (pred(c)) out.push(c); walk(c, pred, out); }
  return out;
}
function allByClass(cls) { return walk(documentStub.documentElement, n => n.classList.contains(cls)); }
function switches() { return allByClass('sw'); }
function pills() { return allByClass('st'); }
function texts(cls) { return allByClass(cls).map(n => n.textContent); }
function callsMatching(re) { return CALLS.filter(c => re.test(c)); }

function expect(errs, cond, msg) { if (!cond) errs.push(msg); }

/* ---------------------------------------------------------------- 场景 */
(async () => {
  let failed = 0;

  /* ---- 场景 1：初始渲染 ---- */
  {
    await sleep(60);
    const errs = [];
    const sw = switches();
    expect(errs, sw.length === 3, `应有 3 个开关，实际 ${sw.length}`);
    expect(errs, CFG.FIX_POWERKEEPER === 1 && sw[0].getAttribute('aria-checked') === 'true',
      '② 开关初始应为开（aria-checked=true）');
    expect(errs, sw[1].getAttribute('aria-checked') === 'true', '③ 开关初始应为开');
    expect(errs, sw[2].getAttribute('aria-checked') === 'true', '④ 开关初始应为开');
    expect(errs, pills().length === 3, `应有 3 个状态胶囊，实际 ${pills().length}`);
    expect(errs, texts('n').join('|').includes('PowerKeeper 补丁'), '缺少 ② 标题');
    expect(errs, texts('n').join('|').includes('停 BPF 监视器'), '缺少 ③ 标题');
    expect(errs, texts('n').join('|').includes('停死电话栈'), '缺少 ④ 标题');
    expect(errs, texts('n').join('|').includes('开发者选项 sepolicy'), '缺少 ⑭ 标题');
    expect(errs, texts('fixed').join('') === '常开', '⑭ 应显示为常开');
    expect(errs, callsMatching(/--json/).length >= 1, '启动时应调用一次 --json');
    if (errs.length) { console.log('✗ 场景 1 失败:'); errs.forEach(e => console.log('   - ' + e)); failed++; }
    else console.log('✓ 场景 1 通过：初始渲染 3 开关 + ⑭ 常开项');
  }

  /* ---- 场景 2：拨 ② 关 → 必须发出 --set FIX_POWERKEEPER 0 ---- */
  {
    CALLS.length = 0;
    const sw = switches();
    await sw[0].fire('click');
    await sleep(60);
    const errs = [];
    const set = callsMatching(/--set/);
    expect(errs, set.length === 1, `应恰好发出 1 条 --set，实际 ${set.length}：${set.join(' / ')}`);
    expect(errs, /--set\s+FIX_POWERKEEPER\s+0/.test(set[0] || ''), `--set 参数不对：${set[0]}`);
    expect(errs, CFG.FIX_POWERKEEPER === 0, '桩里的 config 应被改成 0');
    expect(errs, switches()[0].getAttribute('aria-checked') === 'false', '拨完后 ② 应显示为关');
    if (errs.length) { console.log('✗ 场景 2 失败:'); errs.forEach(e => console.log('   - ' + e)); failed++; }
    else console.log('✓ 场景 2 通过：拨 ② 只发一次 --set，且界面跟随');
  }

  /* ---- 场景 3：拨 ③ 开 → --set FIX_BPFMON 1 ---- */
  {
    const errs = [];
    // 先把 ③ 摆成"关"，这样"点一下 = 开"是确定的（不依赖上一个场景留下的状态）
    CFG.FIX_BPFMON = 0;
    CALLS.length = 0;
    await documentStub.querySelector('#refresh').fire('click');
    await sleep(60);
    expect(errs, switches()[1].getAttribute('aria-checked') === 'false', '前置：③ 此时应为关');

    CALLS.length = 0;
    await switches()[1].fire('click');
    await sleep(60);
    const set = callsMatching(/--set/);
    expect(errs, set.length === 1, `应恰好发出 1 条 --set，实际 ${set.length}`);
    expect(errs, /--set\s+FIX_BPFMON\s+1/.test(set[0] || ''), `--set 参数不对：${set[0]}`);
    expect(errs, switches()[1].getAttribute('aria-checked') === 'true', '拨完后 ③ 应显示为开');
    if (errs.length) { console.log('✗ 场景 3 失败:'); errs.forEach(e => console.log('   - ' + e)); failed++; }
    else console.log('✓ 场景 3 通过：拨 ③ 发出正确的 --set');
  }

  /* ---- 场景 4：⑭ 的「重新应用」按钮必须走 --sepolicy ---- */
  {
    CALLS.length = 0;
    const btn = allByClass('btn').find(b => b.textContent.includes('重新应用'));
    const errs = [];
    expect(errs, !!btn, '找不到「重新应用」按钮');
    if (btn) {
      await btn.fire('click');
      await sleep(60);
      expect(errs, callsMatching(/--sepolicy/).length === 1, '应恰好发出 1 次 --sepolicy');
      expect(errs, callsMatching(/--set/).length === 0, '不该顺带发出 --set');
    }
    if (errs.length) { console.log('✗ 场景 4 失败:'); errs.forEach(e => console.log('   - ' + e)); failed++; }
    else console.log('✓ 场景 4 通过：⑭ 按钮走 --sepolicy');
  }

  /* ---- 场景 5：③ 的判别力 —— 监视器在跑时必须说"仍在运行" ---- */
  {
    const errs = [];
    STATE.BPFMON_RUNNING = 1;
    STATE.BPFMON_SVC = 'running';
    CALLS.length = 0;
    await documentStub.querySelector('#refresh').fire('click');
    await sleep(60);
    const t = pills().map(p => p.textContent).join('|');
    expect(errs, /监视器仍在运行/.test(t), `③ 在监视器运行时必须报"仍在运行"，实际状态文案：${t}`);
    expect(errs, !/已停/.test(t), '③ 在监视器运行时不该说"已停"');

    STATE.BPFMON_RUNNING = 0;
    STATE.BPFMON_SVC = 'stopped';
    CALLS.length = 0;
    await documentStub.querySelector('#refresh').fire('click');
    await sleep(60);
    const t2 = pills().map(p => p.textContent).join('|');
    expect(errs, /已停/.test(t2), `③ 在 stopped 时应报"已停"，实际：${t2}`);
    if (errs.length) { console.log('✗ 场景 5 失败:'); errs.forEach(e => console.log('   - ' + e)); failed++; }
    else console.log('✓ 场景 5 通过：③ 的状态文案随实际状态变化（有判别力）');
  }

  /* ---- 场景 6：② 的四种状态文案 ---- */
  {
    const errs = [];
    // 已挂载但进程还没读到（开机早期）—— 这时必须说"稍后会自愈"，不能说"生效了"
    STATE.POWERKEEPER_SEEN = 0;
    STATE.POWERKEEPER_MOUNTED = 1;
    STATE.POWERKEEPER_PAYLOAD = 1;
    CALLS.length = 0;
    await documentStub.querySelector('#refresh').fire('click');
    await sleep(60);
    let t = pills().map(p => p.textContent).join('|');
    expect(errs, /还没读到/.test(t), `已挂载但进程没读到时应如实说明，实际：${t}`);

    // 挂载也没有
    STATE.POWERKEEPER_MOUNTED = 0;
    CALLS.length = 0;
    await documentStub.querySelector('#refresh').fire('click');
    await sleep(60);
    t = pills().map(p => p.textContent).join('|');
    expect(errs, /未挂载/.test(t) && /重启后生效/.test(t), `未挂载时应提示重启后生效，实际：${t}`);

    // payload 都没有
    STATE.POWERKEEPER_PAYLOAD = 0;
    CALLS.length = 0;
    await documentStub.querySelector('#refresh').fire('click');
    await sleep(60);
    t = pills().map(p => p.textContent).join('|');
    expect(errs, /payload 缺失/.test(t), `payload 缺失时应明确报出，实际：${t}`);

    // 全部正常：进程活着且读到补丁
    STATE.POWERKEEPER_MOUNTED = 1;
    STATE.POWERKEEPER_PAYLOAD = 1;
    STATE.POWERKEEPER_SEEN = 1;
    CALLS.length = 0;
    await documentStub.querySelector('#refresh').fire('click');
    await sleep(60);
    t = pills().map(p => p.textContent).join('|');
    expect(errs, /读到了补丁版/.test(t), `一切正常时应说进程读到了补丁版，实际：${t}`);
    if (errs.length) { console.log('✗ 场景 6 失败:'); errs.forEach(e => console.log('   - ' + e)); failed++; }
    else console.log('✓ 场景 6 通过：② 的四种状态文案正确');
  }

  /* ---- 场景 7：开关标签不能被读成"监视器在运行" ----
     真实踩过的坑：③ 卡片原来是「停 BPF 监视器  开 · 已停（…）」，
     「开」是"这项修复启用了吗"，紧跟在标题后面却被读成"监视器：开"。 */
  {
    const errs = [];
    STATE.BPFMON_RUNNING = 0;
    STATE.BPFMON_SVC = 'stopped';
    CFG.FIX_BPFMON = 1;
    CALLS.length = 0;
    await documentStub.querySelector('#refresh').fire('click');
    await sleep(60);

    const sub = texts('d').join('|');
    expect(errs, /修复已启用/.test(sub), `开关状态应写明"修复已启用"，实际副标题：${sub}`);
    // 不能出现孤零零的"开"/"关"当开关标签（会被读成被修对象的运行状态）
    expect(errs, !/(^|\|)\s*开\s*(\||$)/.test(sub), `副标题里不该出现裸的"开"，实际：${sub}`);
    expect(errs, !/(^|\|)\s*关\s*(\||$)/.test(sub), `副标题里不该出现裸的"关"，实际：${sub}`);

    // ③ 那一行必须同时把"修复启用"和"监视器已停"说清楚
    const line3 = texts('d').find(x => x.includes('BPF 监视器'));
    expect(errs, !!line3, `找不到 ③ 的副标题，实际：${sub}`);
    expect(errs, line3 && /修复已启用/.test(line3) && /BPF 监视器已停/.test(line3),
      `③ 副标题应同时说清"修复已启用"和"监视器已停"，实际：${line3}`);
    if (errs.length) { console.log('✗ 场景 8 失败:'); errs.forEach(e => console.log('   - ' + e)); failed++; }
    else console.log('✓ 场景 7 通过：开关标签不会被误读成"监视器在运行"');
  }

  /* ---- 场景 8：--json 读不到时必须给出可读错误，且不崩 ---- */
  {
    const errs = [];
    JSON_BROKEN = true;
    CALLS.length = 0;
    await documentStub.querySelector('#refresh').fire('click');
    await sleep(60);
    const ver = documentStub.querySelector('#ver').textContent;
    const log = documentStub.querySelector('#log').textContent;
    expect(errs, /读取失败/.test(ver), `读不到状态时 #ver 应显示"读取失败"，实际：${ver}`);
    expect(errs, /读取失败/.test(log), `读不到状态时应写进操作日志，实际日志尾部：${log.slice(-80)}`);
    expect(errs, switches().length === 3, '出错后界面结构不该被破坏');
    JSON_BROKEN = false;
    await documentStub.querySelector('#refresh').fire('click');
    await sleep(60);
    expect(errs, /版本 v1\.0/.test(documentStub.querySelector('#ver').textContent), '恢复后应能正常刷新');
    if (errs.length) { console.log('✗ 场景 8 失败:'); errs.forEach(e => console.log('   - ' + e)); failed++; }
    else console.log('✓ 场景 8 通过：读不到状态时给出可读错误且可恢复');
  }

  console.log('');
  if (failed) { console.log(`✗ 有 ${failed} 个场景失败`); process.exit(1); }
  console.log('全部场景通过 ✓');
})();
