/* 极简 DOM 桩：只够跑 module/webroot/index.html 里的渲染逻辑。
   目的不是替代浏览器，而是把 render()/load() 真跑一遍，抓运行时错误与结构问题。
   用法：node .tmp-check/dom-test.js */
const fs = require('fs');
const path = require('path');

class ClassList {
  constructor(node){ this.node = node; this.set = new Set(); }
  _sync(){ this.node._className = [...this.set].join(' '); }
  add(...c){ c.forEach(x => x && this.set.add(x)); this._sync(); }
  remove(...c){ c.forEach(x => this.set.delete(x)); this._sync(); }
  toggle(c, force){
    if (force === undefined) { this.set.has(c) ? this.set.delete(c) : this.set.add(c); }
    else if (force) this.set.add(c); else this.set.delete(c);
    this._sync();
  }
  contains(c){ return this.set.has(c); }
}

class Node {
  constructor(tag){
    this.tagName = String(tag || '').toUpperCase();
    this.children = []; this.parent = null;
    this._text = ''; this._className = '';
    this.classList = new ClassList(this);
    this.style = {}; this.dataset = {}; this.attrs = {};
    this._html = ''; this.value = ''; this.disabled = false; this.selected = false;
    this.onclick = null; this.onchange = null; this.id = '';
  }
  get className(){ return this._className; }
  set className(v){ this._className = v || ''; this.classList.set = new Set(String(v || '').split(/\s+/).filter(Boolean)); }
  get textContent(){
    if (this.children.length === 0) return this._text;
    return this.children.map(c => c.textContent).join('');
  }
  set textContent(v){ this._text = String(v == null ? '' : v); this.children = []; }
  get firstChild(){ return this.children[0] || null; }
  get innerHTML(){ return this._html; }
  set innerHTML(v){ this._html = String(v); this.children = []; }
  appendChild(n){
    if (!n) return n;
    if (n.__frag){ n.children.forEach(c => { c.parent = this; this.children.push(c); }); n.children = []; return n; }
    n.parent = this; this.children.push(n); return n;
  }
  insertBefore(n, ref){
    n.parent = this;
    const i = ref ? this.children.indexOf(ref) : -1;
    if (i < 0) this.children.unshift(n); else this.children.splice(i, 0, n);
    return n;
  }
  querySelector(){ return null; }
  addEventListener(){}
  setAttribute(k, v){ this.attrs[k] = v; }
}

const IDS = {};
function nodeForId(id){
  if (!IDS[id]) { IDS[id] = new Node('div'); IDS[id].id = id; }
  return IDS[id];
}

const documentStub = {
  documentElement: new Node('html'),
  createElement: t => new Node(t),
  createDocumentFragment: () => { const f = new Node('#fragment'); f.__frag = true; return f; },
  querySelector(sel){
    const m = /^#([\w-]+)$/.exec(sel);
    return m ? nodeForId(m[1]) : null;
  }
};
documentStub.documentElement.dataset = {};

const store = {};
globalThis.document = documentStub;
globalThis.localStorage = { getItem: k => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = String(v); } };
globalThis.window = { matchMedia: () => ({ matches: false }) };

/* ---- 假 ksu.exec ---- */
const CALLS = [];
let JSONOUT = {};
let APPSTAT = 'installed=0\nneeded=0';
const ksuStub = {
  exec: async (cmd) => {
    CALLS.push(cmd);
    if (cmd.includes('--json')) return JSON.stringify(JSONOUT);
    if (cmd.includes('--appstat')) return APPSTAT;
    if (cmd.includes('--set')) return 'ok 3';
    if (cmd.includes('--apksync')) return 'installed=1';
    return 'ok';
  }
};
globalThis.ksu = ksuStub;
window.ksu = ksuStub;

/* ---- 跑真正的页面脚本 ---- */
/* 场景 1 的数据必须在页面脚本求值**之前**就位 —— load() 是脚本末尾立即调用的 */
JSONOUT = {
  FIX_POWERKEEPER:1, FIX_BPFMON:1, FIX_TELEPHONY:1, GESTURE:1,
  PEN_WAKE:0, CAPSULE:0, BRUSH:0, AON:0, PEN_REST:0, SETTINGS_SYNC:0, SCREEN_CMD:0,
  NEED_APP:0,
  BRUSH_ERASER:35, BRUSH_DEFAULT_WAVE:36, BRUSH_AI_WAVE:36, BRUSH_LASSO_WAVE:36,
  GESTURE_RING:194, GESTURE_DOUBLE:195, GESTURE_SLIDE_UP:196,
  GESTURE_SLIDE_DOWN:197, GESTURE_TAIL:92,
  SCREEN_SWAP:0, CAPSULE_DIRECT:1, CAPSULE_GATT:1, CAPSULE_FAST:0,
  REFRESH_SECONDS:0, POLL_MS:200, MARKERS:"", BRUSH_MAP:"1:32,2:32,3:33,4:34,10:36"
};
APPSTAT = 'installed=0\nneeded=0';

const html = fs.readFileSync(path.join(__dirname, '..', 'module', 'webroot', 'index.html'), 'utf8');
const script = /<script>([\s\S]*?)<\/script>/.exec(html)[1];
new Function(script + '\n;globalThis.__load = load; globalThis.__cfg = () => CFG;')();

/* ---- 树遍历工具 ---- */
function walk(node, fn, depth){
  fn(node, depth || 0);
  node.children.forEach(c => walk(c, fn, (depth || 0) + 1));
}
function count(node, cls){
  let n = 0;
  walk(node, x => { if (String(x.className).split(/\s+/).includes(cls)) n++; });
  return n;
}
function find(node, cls, out){
  out = out || [];
  walk(node, x => { if (String(x.className).split(/\s+/).includes(cls)) out.push(x); });
  return out;
}
function flat(node){
  const out = [];
  walk(node, (x, d) => {
    const cls = x.className ? '.' + x.className.split(/\s+/).join('.') : '';
    out.push('  '.repeat(d) + x.tagName.toLowerCase() + cls +
      (x.children.length === 0 && x.textContent ? '  "' + x.textContent.slice(0, 60) + '"' : ''));
  });
  return out.join('\n');
}

/* ==========================================================================
   场景 1：默认状态（分组 B 全关、无标记文件）
   ========================================================================== */
setTimeout(async () => {
  await new Promise(r => setTimeout(r, 150));
  const app = nodeForId('app');
  const errs = [];
  const text = app.textContent;

  console.log('=== 场景 1：默认状态 ===');
  console.log('调用过的命令:');
  CALLS.forEach(c => console.log('   ' + c));
  console.log('开关 =', count(app, 'mui-switch'),
              ' 下拉 =', count(app, 'mui-select'),
              ' row =', count(app, 'row'),
              ' 子行(disabled) =', count(app, 'disabled'));

  /* 每个功能项都要有一个开关（fixed 项用 chip 代替）*/
  const nSw = count(app, 'mui-switch');
  // 4 个分类总开关 + 11 个功能项开关 + 5 个手势开关 + 8 个子开关(3 capsule + 1 screen + 4? ) 
  // 4 个分类总开关 + 11 个功能项 + ⑤/⑬ 的 4 个子项 + ⑥ 的 5 个手势 = 24
  if (nSw !== 24) errs.push('开关数量应为 24，实际 ' + nSw);
  const nSel = count(app, 'mui-select');
  // 5 个手势目标 + 9 个波形
  // 5 个手势目标键 + 9 个波形 = 14
  if (nSel !== 14) errs.push('下拉数量应为 14，实际 ' + nSel);

  ['系统修复', '手写笔连接', '手势与书写', '注视感知', 'App / APK',
   'PowerKeeper 修复', '手势桥', '笔刷触感', '注视感知（AON）',
   '开发者选项（SELinux）', '立即对齐 APK 状态', '全部开启', '全部关闭'
  ].forEach(s => { if (!text.includes(s)) errs.push('缺少内容: ' + s); });

  /* 默认：分组 B 全关 → ⑤ 的子开关应全部 disabled；⑥ 开着 → 手势子行不该 disabled */
  const subs = find(app, 'sub');
  const capSubs = subs.filter(r => r.textContent.includes('抢跑') || r.textContent.includes('守护直发') ||
                                   r.textContent.includes('GATT 校正') || r.textContent.includes('亮灭互换'));
  if (capSubs.length !== 4) errs.push('⑤/⑬ 子开关数量应为 4，实际 ' + capSubs.length);
  capSubs.forEach(r => { if (!r.classList.contains('disabled')) errs.push('父项关着，子行却没置灰: ' + r.textContent.slice(0,20)); });

  const gesRows = subs.filter(r => r.children.some(c => String(c.className).includes('ctl')) &&
                                  /轻捏|双击|上滑|下滑|笔尾键/.test(r.textContent));
  if (gesRows.length !== 5) errs.push('手势映射行应为 5，实际 ' + gesRows.length);
  gesRows.forEach(r => { if (r.classList.contains('disabled')) errs.push('⑥ 开着，手势行却置灰: ' + r.textContent.slice(0,20)); });
  // 默认状态：「手势与书写」是混合（⑥ 开、⑦⑫ 关），另外三类要么全开要么全关
  if (count(app, 'ind') !== 1) errs.push('默认状态应恰有 1 个"混合"总开关，实际 ' + count(app, 'ind'));
  // 13 条置灰子行 = ⑤ 的 3 + ⑬ 的 1 + ⑦ 的 9（父项都关着）；⑥ 的 5 条手势行不该灰
  if (count(app, 'disabled') !== 13) errs.push('置灰子行应为 13，实际 ' + count(app, 'disabled'));

  /* 下拉的当前值要对 */
  const selVals = [];
  walk(app, x => {
    if (!String(x.className).includes('mui-select')) return;
    const hit = x.children.find(o => o.selected);
    selVals.push(hit ? hit.value : '');
  });
  ['194','195','196','197','92','32','32','33','34','36','36','36','35','36']
    .forEach((v, i) => { if (selVals[i] !== undefined && String(selVals[i]) !== v) errs.push('下拉 #' + i + ' 期望 ' + v + ' 实际 ' + selVals[i]); });

  console.log('\n下拉当前值 =', selVals.join(','));

  if (errs.length) { console.log('\n✗ 场景 1 失败:'); errs.forEach(e => console.log('   - ' + e)); process.exit(1); }
  console.log('✓ 场景 1 通过');
}, 40);

/* ==========================================================================
   场景 2：全部开启 + 有标记文件
   ========================================================================== */
setTimeout(async () => {
  await new Promise(r => setTimeout(r, 400));
  JSONOUT = Object.assign({}, JSONOUT, {
    PEN_WAKE:1, CAPSULE:1, BRUSH:1, AON:1, PEN_REST:1, SETTINGS_SYNC:1, SCREEN_CMD:1,
    NEED_APP:1, MARKERS:"disable-brush disable-aon"
  });
  APPSTAT = 'installed=1\nneeded=1';
  const app = nodeForId('app');
  CALLS.length = 0;
  // 直接调页面里的 load()
  try { await globalThis.__load(); }
  catch (e) { console.log('!! __load() 抛错:', e && e.stack || e); }

  const errs = [];
  const text = app.textContent;
  console.log('DEBUG MARKERS =', JSON.stringify(globalThis.__cfg().MARKERS));
  console.log('DEBUG CFG keys =', Object.keys(globalThis.__cfg()).length);
  console.log('DEBUG app 首个子节点 =', app.children[0] && app.children[0].className);
  console.log('\n=== 场景 2：全开 + 标记文件 ===');
  console.log('调用过的命令:');
  CALLS.forEach(c => console.log('   ' + c));
  console.log('开关 =', count(app, 'mui-switch'), ' 下拉 =', count(app, 'mui-select'),
              ' 混合总开关 =', count(app, 'ind'));

  if (!text.includes('存在标记文件')) errs.push('没有提示标记文件');
  if (!text.includes('disable-brush')) errs.push('标记内容没列出来');
  if (!text.includes('已安装')) errs.push('APK 已安装状态没显示');
  if (!text.includes('有功能需要它')) errs.push('"有功能需要它" 没显示');
  /* 全开时子开关都不该置灰 */
  const capSubs = find(app, 'sub').filter(r => /抢跑|守护直发|GATT 校正|亮灭互换/.test(r.textContent));
  capSubs.forEach(r => { if (r.classList.contains('disabled')) errs.push('父项开着，子行却置灰: ' + r.textContent.slice(0,20)); });
  if (count(app, 'disabled') !== 0) errs.push('全开时不该有置灰行，实际 ' + count(app, 'disabled'));

  if (errs.length) { console.log('\n✗ 场景 2 失败:'); errs.forEach(e => console.log('   - ' + e)); process.exit(1); }
  console.log('✓ 场景 2 通过');
  console.log('\n=== 场景 2 结构（前 3 层）===');
  console.log(flat(app).split('\n').slice(0, 40).join('\n'));
}, 400);


/* ==========================================================================
   场景 3/4：真实交互 —— 单项开关 & 分类总开关（重点：总开关只能触发一次 --set）
   ========================================================================== */
function rowByText(root, txt){
  let hit = null;
  walk(root, x => {
    if (hit) return;
    if (String(x.className).split(/\s+/).includes('row') && x.textContent.includes(txt)) hit = x;
  });
  return hit;
}
function switchOf(node){
  let hit = null;
  walk(node, x => { if (!hit && String(x.className).split(/\s+/).includes('mui-switch')) hit = x; });
  return hit;
}
function selectVal(sel){
  const hit = sel.children.find(o => o.selected);
  return hit ? hit.value : '';
}

setTimeout(async () => {
  await new Promise(r => setTimeout(r, 700));
  const app = nodeForId('app');
  const errs = [];
  console.log('\n=== 场景 3：单项开关（关掉 ⑨ 笔休眠档）===');
  CALLS.length = 0;

  const row = rowByText(app, '笔休眠档');
  if (!row) { console.log('✗ 找不到「笔休眠档」行'); process.exit(1); }
  const sw = switchOf(row);
  if (!sw || !sw.classList.contains('on')) { console.log('✗ 该行开关不是打开状态'); process.exit(1); }
  sw.onclick();
  await new Promise(r => setTimeout(r, 80));
  CALLS.forEach(c => console.log('   ' + c));

  const sets = CALLS.filter(c => c.includes('--set'));
  if (sets.length !== 1) errs.push('应只有 1 次 --set，实际 ' + sets.length);
  if (sets[0] && !sets[0].includes("PEN_REST '0'")) errs.push('--set 参数不对: ' + sets[0]);
  if (!CALLS.some(c => c.includes('--apksync'))) errs.push('改了分组 B 的项却没有调 --apksync');
  // 界面要立刻反映（乐观更新）
  const sw2 = switchOf(rowByText(app, '笔休眠档'));
  if (!sw2 || sw2.classList.contains('on')) errs.push('开关没有立刻变成关');
  if (errs.length) { console.log('✗ 场景 3 失败:'); errs.forEach(e => console.log('   - ' + e)); process.exit(1); }
  console.log('✓ 场景 3 通过');

  /* ---- 场景 4：分类总开关 ---- */
  console.log('\n=== 场景 4：分类总开关「手写笔连接」→ 全开 ===');
  const cats = find(app, 'cat');
  const conn = cats.find(c => c.textContent.includes('手写笔连接'));
  if (!conn) { console.log('✗ 找不到「手写笔连接」分类'); process.exit(1); }
  const msw = switchOf(conn.children.find(c => String(c.className).includes('head')));
  console.log('   总开关当前状态:', msw.className);
  CALLS.length = 0;
  msw.onclick();
  await new Promise(r => setTimeout(r, 100));
  CALLS.forEach(c => console.log('   ' + c));

  const sets2 = CALLS.filter(c => c.includes('--set'));
  if (sets2.length !== 1) { errs.push('总开关应只触发 1 次 --set，实际 ' + sets2.length); }
  else {
    ['PEN_WAKE', 'CAPSULE', 'PEN_REST', 'SCREEN_CMD'].forEach(k => {
      if (!sets2[0].includes(k + " '1'")) errs.push('总开关漏了 ' + k + ': ' + sets2[0]);
    });
  }
  // 4 个成员都该变成开
  ['手写笔休眠唤醒', '吸附电量胶囊', '笔休眠档', '屏幕亮/灭告诉笔'].forEach(t => {
    const r = rowByText(app, t);
    const s = r && switchOf(r);
    if (!s || !s.classList.contains('on')) errs.push('总开关后「' + t + '」没变成开');
  });
  if (count(app, 'ind') !== 0) errs.push('全开后不该还有混合总开关');
  if (errs.length) { console.log('✗ 场景 4 失败:'); errs.forEach(e => console.log('   - ' + e)); process.exit(1); }
  console.log('✓ 场景 4 通过');
  console.log('\n全部场景通过 ✓');
}, 700);
