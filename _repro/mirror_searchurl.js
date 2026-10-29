// 忠实镜像 legado-ios 的 searchUrl 三阶段流水线：
//  splitSourceRule(@js:([\w\W]*) 贪婪) -> evalSearchUrlJS -> replaceKeyPage -> parseSearchRequest
// 目标：对真实 @js:/<js> 书源，验证 evaluateSearchUrl 实际产出的 URL 是否合法。
const fs = require('fs');
const { execSync } = require('child_process');
const yck = JSON.parse(fs.readFileSync(__dirname + '/yck.json', 'utf-8'));
const KEY = '诛仙';

function encodeSearchKey(kw) {
  return encodeURIComponent(kw); // 简化：与 Swift searchKeyAllowed 近似（含 / 不编码，+ 编码）
}

// ---- splitSourceRule: 与 Swift 完全相同的正则 ----
const SPLIT = /<js>([\w\W]*?)<\/js>|@js:([\w\W]*)/;
function splitSourceRule(rule) {
  const segs = [];
  let m;
  let last = 0;
  SPLIT.lastIndex = 0;
  while ((m = SPLIT.exec(rule)) !== null) {
    if (m.index > last) {
      const t = rule.slice(last, m.index);
      if (t.trim()) segs.push({ mode: 'plain', text: t });
    }
    if (m[1] !== undefined) segs.push({ mode: 'js', text: m[1] });
    else segs.push({ mode: 'js', text: m[2] });
    last = m.index + m[0].length;
    if (m[0].length === 0) SPLIT.lastIndex++;
  }
  if (last < rule.length) {
    const t = rule.slice(last);
    if (t.trim()) segs.push({ mode: 'plain', text: t });
  }
  if (segs.length === 0) segs.push({ mode: 'plain', text: rule });
  return segs;
}

// ---- JS 桥绑定（java.ajax 用同步 curl 真实请求） ----
function makeBridge(baseUrl, source) {
  const ajax = (url, headers) => {
    try {
      let u = url;
      if (!/^https?:\/\//.test(u)) u = baseUrl.replace(/\/$/, '') + '/' + u.replace(/^\//, '');
      const hd = headers && headers.toJSON ? headers.toJSON() : (headers || {});
      let hstr = '';
      for (const [k, v] of Object.entries(hd)) hstr += ` -H "${k}: ${String(v).replace(/"/g, '\\"')}"`;
      const out = execSync(`curl -s -L -A "Mozilla/5.0" --max-time 20 ${hstr} "${u}"`, { encoding: 'utf-8', timeout: 25000 });
      return out;
    } catch (e) { return ''; }
  };
  const cookie = { removeCookie: () => '', get: () => '', put: () => {} };
  const java = {
    ajax,
    get: (k) => (source._vars && source._vars[k]) || '',
    put: (k, v) => { source._vars = source._vars || {}; source._vars[k] = v; },
    encodeURI: (s) => encodeURIComponent(s),
    log: () => {},
    webView: () => '',
    longToast: () => {},
    toast: () => {},
    getCookie: () => '',
    setCookie: () => {},
    removeCookie: () => '',
  };
  return { ajax, cookie, java };
}

function evalSearchUrlJS(js, ctx) {
  const fn = new Function('key', 'page', 'searchKey', 'source', 'baseUrl', 'java', 'cookie', 'result',
    'getsurl', 'gethd', 'Packages', `"use strict";\n${js}\n;return (typeof result!=="undefined"&&result!==null)?String(result):undefined;`);
  const r = fn(ctx.key, ctx.page, ctx.searchKey, ctx.source, ctx.baseUrl, ctx.java, ctx.cookie, ctx.initialResult,
    ctx.getsurl, ctx.gethd, ctx.Packages);
  return r;
}

function evaluateSearchUrl(rule, keyword, page, baseUrl, source) {
  let stripped = rule.replace(/<js>/g, '').replace(/<\/js>/g, '');
  if (stripped.toLowerCase().startsWith('@js:')) stripped = stripped.slice(4);
  let output = '';
  for (const seg of splitSourceRule(rule)) {
    if (seg.mode === 'js') {
      const { ajax, cookie, java } = makeBridge(baseUrl, source);
      const ctx = {
        key: keyword, page, searchKey: keyword, baseUrl,
        source: { bookSourceUrl: source.bookSourceUrl, header: source.header, getVariable: () => source.getVariable || '' },
        initialResult: stripped,
        getsurl: () => source.bookSourceUrl,
        gethd: () => { try { return JSON.parse(source.header || '{}'); } catch { return {}; } },
        Packages: { java: { net: { URLDecoder: { decode: (s) => { try { return decodeURIComponent(s); } catch { return s; } } } } } },
        java, cookie,
      };
      const v = evalSearchUrlJS(seg.text, ctx);
      output += (v === undefined ? '' : String(v));
    } else {
      output += seg.text;
    }
  }
  return output;
}

function replaceKeyPage(url, keyword, page) {
  let o = url.replace(/\{\{searchKey\}\}/g, '{{key}}').replace(/\{\{searchPage\}\}/g, '{{page}}');
  o = o.replace(/\{\{key\}\}/g, encodeSearchKey(keyword));
  o = o.replace(/searchKey/g, encodeSearchKey(keyword));
  o = o.replace(/\{\{page\}\}/g, String(page));
  o = o.replace(/searchPage/g, String(page));
  return o;
}

function parseSearchRequest(raw) {
  const t = raw.trim();
  const idx = t.indexOf(',{');
  if (idx < 0) return { url: t, method: 'GET', body: null, headers: {}, charset: null };
  const urlPart = t.slice(0, idx);
  let opts = t.slice(idx + 1);
  let obj;
  try { obj = JSON.parse(opts); } catch { try { obj = JSON.parse(opts.replace(/'/g, '"')); } catch { obj = null; } }
  if (!obj) return { url: urlPart, method: 'GET', body: null, headers: {}, charset: null };
  const method = obj.method || 'GET';
  const body = obj.body || null;
  const charset = obj.charset || null;
  const headers = obj.headers || {};
  return { url: urlPart, method, body, headers, charset };
}

// ---- 跑真实 @js: 源 ----
let n = 0;
for (const s of yck) {
  const rs = s.ruleSearch || {};
  let su = rs.searchUrl || s.searchUrl || '';
  if (!su.trim().startsWith('@js:') && !su.includes('<js>')) continue;
  n++;
  if (n > 20) break;
  const base = s.bookSourceUrl || '';
  let err = '';
  let finalUrl = '', req = null;
  try {
    const jsEval = evaluateSearchUrl(su, KEY, 1, base, s);
    const urlStr = replaceKeyPage(jsEval, KEY, 1);
    req = parseSearchRequest(urlStr);
    finalUrl = req.url;
  } catch (e) { err = String(e).slice(0, 80); }
  console.log(`\n[${s.bookSourceName}]`);
  console.log(`  raw   : ${su.slice(0, 130).replace(/\n/g, '\\n')}`);
  if (err) console.log(`  ERR   : ${err}`);
  else {
    console.log(`  url   : ${finalUrl.slice(0, 160)}`);
    console.log(`  method: ${req.method}  body=${req.body ? req.body.slice(0,40) : '—'}  hdr=${Object.keys(req.headers).length}`);
    const bad = finalUrl.includes('@js:') || finalUrl.includes('<js>') || finalUrl.includes('undefined') || finalUrl.includes('NaN');
    console.log(`  ${bad ? '❌ 非法URL' : '✅ 合法URL'}`);
  }
}
console.log(`\n=== 共处理 ${n} 个 @js:/<js> 源 ===`);
