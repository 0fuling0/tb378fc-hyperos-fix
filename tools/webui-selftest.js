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

/* service.sh 的 need_app() 在桩里的对应物：七个分组 B 功能只要有一项"生效开"就需要 APK。
   MARKERS 里的 disable-* 会把对应功能强制关掉，必须算进去 —— 否则"界面说需要、实际已卸"。
   WebUI 现在直接信 NEED_APP（而不是自己按 config 算），所以桩也得真的维护它。 */
const NEED_GATE = {
  PEN_WAKE: 'disable', CAPSULE: 'disable-capsule', BRUSH: 'disable-brush',
  AON: 'disable-aon', PEN_REST: 'disable-rest', SETTINGS_SYNC: null,
  SCREEN_CMD: 'disable-screen'
};
function recomputeNeedApp() {
  const off = new Set(String(JSONOUT.MARKERS || '').split(/\s+/).filter(Boolean));
  JSONOUT.NEED_APP = Object.keys(NEED_GATE).some(k =>
    !(NEED_GATE[k] && off.has(NEED_GATE[k])) && Number(JSONOUT[k]) === 1) ? 1 : 0;
}

const ksuStub = {
  exec: async (cmd) => {
    CALLS.push(cmd);
    if (cmd.includes('--json')) { recomputeNeedApp(); return JSON.stringify(JSONOUT); }
    if (cmd.includes('--appstat')) return APPSTAT;
    if (cmd.includes('--set')) {
      /* 真机上 --set 会落盘，下一次 --json 就能读到。
         桩也必须这样：否则"重载后映射还在不在"这类断言永远看到旧值（假失败）。 */
      const seg = cmd.slice(cmd.indexOf('--set') + 5);
      const re = /([A-Za-z_][A-Za-z0-9_]*)\s+'((?:[^']|'\\'')*)'/g;
      let m;
      while ((m = re.exec(seg))) {
        const raw = m[2].replace(/'\\''/g, "'");
        const num = Number(raw);
        JSONOUT[m[1]] = (raw !== '' && !isNaN(num)) ? num : raw;
      }
      return 'ok 3';
    }
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
/* 一行"标题"（.pri 里的文字，不含右侧控件与下方说明）。
   为什么要它：rowByText 是子串匹配，会被**别的行的说明文字**骗到 ——
   ⑥ 自己的 d 里就写着"捏/双击/上滑/下滑"，于是 rowByText(app,'双击') 拿到的是 ⑥ 那一行
   （没有下拉框 → 场景 6 直接崩）。所以按 .pri 精确匹配。 */
function priOf(row){
  let t = '';
  walk(row, x => { if (!t && String(x.className).split(/\s+/).includes('pri')) t = x.textContent.trim(); });
  return t;
}
/* 二级功能项行：.row 且 .pri 恰好等于 t（⑥ 的标题是 "⑥" + "手势桥" → "⑥手势桥"） */
function rowByTitle(root, t){
  let hit = null;
  walk(root, x => {
    if (hit) return;
    const cls = String(x.className).split(/\s+/);
    if (cls.includes('row') && !cls.includes('sub') && priOf(x) === t) hit = x;
  });
  return hit;
}
/* 三级子行（.row.sub），同样按 .pri 精确匹配 */
function subRow(root, t){
  let hit = null;
  walk(root, x => {
    if (hit) return;
    const cls = String(x.className).split(/\s+/);
    if (cls.includes('row') && cls.includes('sub') && priOf(x) === t) hit = x;
  });
  return hit;
}
/* 行里的下拉框；找不到返回 null（而不是让调用方崩在 children 上） */
function selOf(row){
  if (!row) return null;
  let h = null;
  walk(row, x => { if (!h && String(x.className).split(/\s+/).includes('sel')) h = x; });
  return h;
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
  console.log('开关 =', count(app, 'sw'),
              ' 下拉 =', count(app, 'sel'),
              ' row =', count(app, 'row'),
              ' 子行(disabled) =', count(app, 'disabled'));

  /* 每个功能项都要有一个开关（fixed 项用 chip 代替）*/
  const nSw = count(app, 'sw');
  // 4 个分类总开关 + 11 个功能项开关 + 5 个手势开关 + 8 个子开关(3 capsule + 1 screen + 4? ) 
  // 4 个分类总开关 + 11 个功能项 + ⑤/⑬ 的 4 个子项 + ⑥ 的 5 个手势 = 24
  if (nSw !== 24) errs.push('开关数量应为 24，实际 ' + nSw);
  const nSel = count(app, 'sel');
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
    if (!String(x.className).includes('sel')) return;
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
  console.log('开关 =', count(app, 'sw'), ' 下拉 =', count(app, 'sel'),
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
  walk(node, x => { if (!hit && String(x.className).split(/\s+/).includes('sw')) hit = x; });
  return hit;
}
function selectVal(sel){
  if (!sel) return '<没有下拉框>';
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

  /* ---- 场景 5：三级（子项）开关必须跟随二级（父项）----
     回归点（两代）：
       第一代——子开关只看自己那个键，父项关掉后子开关还显示为"开"（只是变灰）；
       第二代——显示跟上了，但拨父项**只写父项自己**，于是把 ⑤ 打开后三个子项还是灭的
                （它们自己的值就是 0），用户看到的仍然是"三级开关不跟随"。
     现在的契约：拨父项 = 拨整组（自己 + 三级子项），两个方向都要写。 */
  console.log('\n=== 场景 5：三级子开关跟随二级父项 ===');
  const errs5 = [];
  const SUBNAMES = ['抢跑', '守护直发', 'GATT 校正'];
  const subStates = () => SUBNAMES.map(n => {
    const r = subRow(app, n);
    const s = r && switchOf(r);
    return s && s.classList.contains('on');
  });
  const parentRow = () => rowByText(app, '吸附电量胶囊');

  if (!switchOf(parentRow()).classList.contains('on')) errs5.push('前置条件不对：⑤ 该是开');

  // 关掉 ⑤ → 三个子项应立刻全部变成"关"，并且**写进 config**
  CALLS.length = 0;
  switchOf(parentRow()).onclick();
  await new Promise(r => setTimeout(r, 100));
  const afterOff = subStates();
  if (afterOff.some(v => v)) errs5.push('⑤ 关掉后子项还显示为开: ' + JSON.stringify(afterOff));
  const setOff = CALLS.filter(c => c.includes('--set')).join(' ');
  SUBNAMES.forEach(n => {
    const key = { '抢跑': 'CAPSULE_FAST', '守护直发': 'CAPSULE_DIRECT', 'GATT 校正': 'CAPSULE_GATT' }[n];
    if (!setOff.includes(key + " '0'")) errs5.push('⑤ 关掉时没把 ' + key + " 一起写 0: " + setOff);
  });

  // 再开回来 → 三个子项必须全部变成"开"（这才是用户说的"跟随"）
  CALLS.length = 0;
  switchOf(parentRow()).onclick();
  await new Promise(r => setTimeout(r, 100));
  const afterOn = subStates();
  if (afterOn.some(v => !v)) errs5.push('⑤ 开回来后子项没跟着开: ' + JSON.stringify(afterOn));
  const setOn = CALLS.filter(c => c.includes('--set')).join(' ');
  SUBNAMES.forEach(n => {
    const key = { '抢跑': 'CAPSULE_FAST', '守护直发': 'CAPSULE_DIRECT', 'GATT 校正': 'CAPSULE_GATT' }[n];
    if (!setOn.includes(key + " '1'")) errs5.push('⑤ 打开时没把 ' + key + " 一起写 1: " + setOn);
  });

  // ⑥ 的手势行：开关与下拉必须一致（以前开关看"值≠-1"、下拉看 parentOn，两者会打架）
  CALLS.length = 0;
  const gesRow = subRow(app, '轻捏');
  const gesSw = switchOf(gesRow);
  const selVal = selectVal(selOf(gesRow));
  if (gesSw.classList.contains('on') !== (selVal !== '-1')) {
    errs5.push('手势行开关与下拉不一致: 开关=' + (gesSw.classList.contains('on') ? 'on' : 'off') + ' 下拉=' + selVal);
  }
  // ⑥ 关掉 → 手势行整行置灰，且开关与下拉同时变成"关"
  switchOf(rowByTitle(app, '⑥手势桥')).onclick();
  await new Promise(r => setTimeout(r, 100));
  const gesRow2 = subRow(app, '轻捏');
  const gesSw2 = switchOf(gesRow2);
  if (gesSw2.classList.contains('on')) errs5.push('⑥ 关掉后手势开关还是开的');
  if (selectVal(selOf(gesRow2)) !== '-1') errs5.push('⑥ 关掉后手势下拉应显示「关闭」，实际 ' + selectVal(selOf(gesRow2)));
  if (!gesRow2.classList.contains('disabled')) errs5.push('⑥ 关掉后手势行没置灰');

  if (errs5.length) { console.log('✗ 场景 5 失败:'); errs5.forEach(e => console.log('   - ' + e)); process.exit(1); }
  console.log('✓ 场景 5 通过');

  /* ---- 场景 6：⑥ 打开时把"关掉(-1)"的手势补成默认键码 ----
     为什么单独测：手势映射的值是键码不是 1/0，级联规则不一样 ——
       打开 ⑥ → 把 -1 的那些补成默认键码（否则用户开了 ⑥ 但五条手势全是"关闭"，还是没反应）
       关掉 ⑥ → **不动**映射（那存的是"用户选了哪个键"，清掉就丢了他的选择） */
  console.log('\n=== 场景 6：⑥ 打开时补默认键码 ===');
  const errs6 = [];
  const GESKEYS = [['轻捏', 'GESTURE_RING', 194], ['双击', 'GESTURE_DOUBLE', 195],
                   ['上滑', 'GESTURE_SLIDE_UP', 196], ['下滑', 'GESTURE_SLIDE_DOWN', 197],
                   ['笔尾键', 'GESTURE_TAIL', 92]];

  // 造一个"从没配过手势"的状态：⑥ 关、五条全是 -1
  JSONOUT = Object.assign({}, JSONOUT, {
    GESTURE: 0, GESTURE_RING: -1, GESTURE_DOUBLE: -1, GESTURE_SLIDE_UP: -1,
    GESTURE_SLIDE_DOWN: -1, GESTURE_TAIL: -1
  });
  await globalThis.__load();
  await new Promise(r => setTimeout(r, 100));

  GESKEYS.forEach(([n]) => {
    const r = subRow(app, n);
    if (!r) { errs6.push('找不到手势行 ' + n); return; }
    if (!r.classList.contains('disabled')) errs6.push('⑥ 关着，' + n + ' 行却没置灰');
    if (switchOf(r) && switchOf(r).classList.contains('on')) errs6.push('⑥ 关着，' + n + ' 开关却是开的');
  });

  // 打开 ⑥ → 五条手势都要被补成默认键码
  CALLS.length = 0;
  const rowG = rowByTitle(app, '⑥手势桥');
  if (!rowG) { console.log('✗ 找不到「⑥ 手势桥」行'); process.exit(1); }
  switchOf(rowG).onclick();
  await new Promise(r => setTimeout(r, 100));
  const set6 = CALLS.filter(c => c.includes('--set')).join(' ');
  if (!set6.includes("GESTURE '1'")) errs6.push("打开 ⑥ 没写 GESTURE '1': " + set6);
  GESKEYS.forEach(([n, k, def]) => {
    if (!set6.includes(k + " '" + def + "'")) errs6.push('打开 ⑥ 没把 ' + k + ' 补成 ' + def + ': ' + set6);
  });
  GESKEYS.forEach(([n, k, def]) => {
    const r = subRow(app, n);
    if (!r) { errs6.push('打开 ⑥ 后找不到手势行 ' + n); return; }
    if (!switchOf(r).classList.contains('on')) errs6.push('打开 ⑥ 后 ' + n + ' 开关没跟着开');
    const got = selectVal(selOf(r));
    if (got !== String(def)) errs6.push('打开 ⑥ 后 ' + n + ' 下拉应是 ' + def + '，实际 ' + got);
  });

  // 再关掉 ⑥ → 只写 GESTURE 自己，不许抹掉映射（用户选的键要留住）
  CALLS.length = 0;
  switchOf(rowByTitle(app, '⑥手势桥')).onclick();
  await new Promise(r => setTimeout(r, 100));
  const set6b = CALLS.filter(c => c.includes('--set')).join(' ');
  if (!set6b.includes("GESTURE '0'")) errs6.push("关掉 ⑥ 没写 GESTURE '0': " + set6b);
  GESKEYS.forEach(([n, k]) => {
    if (set6b.includes(k + ' ')) errs6.push('关掉 ⑥ 不该动 ' + k + '（那是用户选的键）: ' + set6b);
  });
  // 重新读一遍：映射还在，没有被写成 -1
  JSONOUT = Object.assign({}, JSONOUT, { GESTURE: 1 });
  await globalThis.__load();
  await new Promise(r => setTimeout(r, 100));
  GESKEYS.forEach(([n, k, def]) => {
    const r = subRow(app, n);
    if (!r) { errs6.push('重载后找不到手势行 ' + n); return; }
    const got = selectVal(selOf(r));
    if (got !== String(def)) errs6.push(n + ' 的映射被抹掉了：期望 ' + def + ' 实际 ' + got);
  });

  if (errs6.length) { console.log('✗ 场景 6 失败:'); errs6.forEach(e => console.log('   - ' + e)); process.exit(1); }
  console.log('✓ 场景 6 通过');

  /* ---- 场景 7："需不需要 APK"只能有一个来源 ----
     回归点：WebUI 原来自己按 config 算 anyAppOn()，而模块算的是 need_app()（还看 disable-* 标记）。
     标记文件把功能强制关掉时两者相反：模块认为七项全关（不装 APK），界面却写「有功能需要它」，
     甚至 APK 已被卸载还这么写。现在界面直接读 --json 的 NEED_APP。 */
  console.log('\n=== 场景 7：NEED_APP 单一来源（标记文件强制关） ===');
  const errs7 = [];
  JSONOUT = Object.assign({}, JSONOUT, {
    PEN_WAKE: 1, CAPSULE: 1, BRUSH: 1, AON: 1, PEN_REST: 1, SETTINGS_SYNC: 0, SCREEN_CMD: 1,
    MARKERS: "disable disable-capsule disable-brush disable-aon disable-rest disable-screen"
  });
  await globalThis.__load();
  await new Promise(r => setTimeout(r, 100));
  const text7 = app.textContent;
  if (Number(globalThis.__cfg().NEED_APP) !== 0) {
    errs7.push('桩没把 NEED_APP 算成 0（前置条件错）: ' + globalThis.__cfg().NEED_APP);
  }
  if (!text7.includes('当前没有功能需要它')) {
    errs7.push('标记文件把功能都强制关了，界面却说需要 APK（说明还在用本地 anyAppOn 算）');
  }
  if (text7.includes('有功能需要它') && !text7.includes('当前没有功能需要它')) {
    errs7.push('同时出现了两种说法');
  }

  // 反过来：没有标记、有功能开着 → 必须说"有功能需要它"
  JSONOUT = Object.assign({}, JSONOUT, {
    PEN_WAKE: 1, MARKERS: ""
  });
  await globalThis.__load();
  await new Promise(r => setTimeout(r, 100));
  if (Number(globalThis.__cfg().NEED_APP) !== 1) {
    errs7.push('无标记且有功能开着时 NEED_APP 应为 1，实际 ' + globalThis.__cfg().NEED_APP);
  }
  if (!app.textContent.includes('有功能需要它')) errs7.push('无标记且有功能开着，界面却没说要 APK');

  if (errs7.length) { console.log('✗ 场景 7 失败:'); errs7.forEach(e => console.log('   - ' + e)); process.exit(1); }
  console.log('✓ 场景 7 通过');

  console.log('\n全部场景通过 ✓');
}, 700);
