#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
忠实复刻 legado-ios 搜索管线（已读源码版本），对真实 CSS 书源实跑，
定位「热门小说搜索 0~2 本」的书籍丢失环节。

复刻范围（来自已读 SearchCoordinator / RuleEngine / HtmlRuleEngine / LegadoCssTranslator）:
  - replaceKeyPage: {{key}} -> 百分号编码关键词；相对 URL 解析到 base
  - URL 构造与 parseSearchRequest(,{ options })
  - 抓取：UA + Referer=base，跟随重定向，超时
  - 解码：两种模式对照
        A) 自动编码校正（meta charset / gbk 启发 / utf-8 fallback）
        B) 仅 UTF-8（模拟 Swift fetchText 默认，不声明 charset 时）
  - CSS bookList 提取（移植自 LegadoCssTranslator + HtmlRuleEngine.evaluateElementsChain）
  - shouldKeep 模糊过滤：书名/作者/简介 包含 归一化关键词
"""
import json, re, sys, urllib.parse, urllib.request
from bs4 import BeautifulSoup

UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"

# ---------------- 移植：CSS 选择器翻译（来自 LegadoCssTranslator） ----------------
def translate_selector(raw):
    s = raw.strip()
    if s.startswith('tag.'): s = s[4:]
    elif s.startswith('class.'): s = '.' + s[6:]
    elif s.startswith('id.'): s = '#' + s[3:]
    return s

indexSuffix = re.compile(r'^(.*)\.(-?\d+)$')
excludeSuffix = re.compile(r'^(.*)!(-?\d+)$')
rangeSuffix = re.compile(r'^(.*)\[(-?\d+):(-?\d+)\]$')
childrenSuffix = re.compile(r'^children\[(-?\d+)\]$')

def parse_selector_segment(part):
    base = part.strip()
    if childrenSuffix.match(base):
        m = childrenSuffix.match(base)
        return ('', [('children', int(m.group(1)))])
    ops = []
    m = rangeSuffix.match(base)
    if m:
        ops.append(('range', int(m.group(2)), int(m.group(3)))); base = m.group(1)
    m = excludeSuffix.match(base)
    if m:
        ops.append(('exclude', int(m.group(2)))); base = m.group(1)
    m = indexSuffix.match(base)
    if m:
        head = m.group(1)
        if head:
            ops.append(('take', int(m.group(2)))); base = head
    while base.endswith('.'): base = base[:-1]
    return (translate_selector(base), ops)

EXTRACT = {'text':'text','html':'html','owntext':'ownText','alltext':'allText','textnodes':'textNodes',
           'href':'href','src':'src','srcset':'srcset','data-src':'dataSrc','class':'className','id':'id',
           'tag':'tag','alt':'alt','title':'title'}
def parse_extractor(p):
    low = p.lower()
    if low in EXTRACT: return EXTRACT[low]
    if p and re.fullmatch(r'[A-Za-z0-9_\-]+', p): return 'attr(%s)' % p
    return None

def translate(body, for_elements=False):
    trimmed = body.strip(); segs = []; extractor = 'text'; has_ex = False
    parts = trimmed.split('@')
    for i, raw in enumerate(parts):
        part = raw.strip()
        if not part: continue
        is_last = (i == len(parts) - 1)
        if for_elements:
            s, o = parse_selector_segment(part); segs.append((s, o)); continue
        if is_last:
            e = parse_extractor(part)
            if e: extractor = e; has_ex = True; continue
        s, o = parse_selector_segment(part); segs.append((s, o))
    return segs, extractor, has_ex

def select_in(selector, root):
    try: return root.select(selector)
    except Exception: return []

def apply_ops(els, ops):
    for op in ops:
        if op[0] == 'take':
            n = op[1]; idx = n if n >= 0 else len(els) + n
            els = els[idx:idx+1] if 0 <= idx < len(els) else []
        elif op[0] == 'exclude':
            n = op[1]; idx = n if n >= 0 else len(els) + n
            if 0 <= idx < len(els): els = els[:idx] + els[idx+1:]
        elif op[0] == 'range':
            a, b = op[1], op[2]; sa = a if a >= 0 else len(els)+a; sb = b if b >= 0 else len(els)+b
            if 0 <= sa < len(els) and 0 <= sb < len(els):
                els = els[sa:sb+1] if sa <= sb else els[sb:sa+1][::-1]
            else: els = []
        elif op[0] == 'children':
            n = op[1]; out = []
            for e in els:
                ch = list(e.children); idx = n if n >= 0 else len(ch)+n
                if 0 <= idx < len(ch) and getattr(ch[idx], 'name', None): out.append(ch[idx])
            els = out
    return els

def elements(trans, root):
    segs, _, _ = trans; cur = [root]
    for sel, ops in segs:
        nxt = []
        for e in cur:
            nxt += select_in(sel, e) if sel else cur
        seen = set(); uniq = []
        for e in nxt:
            if id(e) not in seen: seen.add(id(e)); uniq.append(e)
        cur = apply_ops(uniq, ops)
        if not cur: return []
    return cur

def css_elements(rule, doc):
    # 对齐 evaluateElementsChain：先按 && 切，再按 || 取首个非空，再按 %% 并集
    body = rule.strip()
    if body.lower().startswith('@css:'): body = body[5:].strip()
    elif body.startswith('@@'): body = body[2:].strip()
    result = []
    for andPart in re.split(r'&&', body):
        andTrim = andPart.strip()
        if not andTrim: continue
        partResult = []
        for orAlt in re.split(r'\|\|', andTrim):
            orTrim = orAlt.strip()
            if not orTrim: continue
            mergeParts = re.split(r'%%', orTrim)
            if len(mergeParts) > 1:
                merged = []
                for mp in mergeParts:
                    mTrim = mp.strip()
                    if not mTrim: continue
                    merged += elements(translate(mTrim, for_elements=True), doc)
                if merged: partResult = merged; break
            else:
                found = elements(translate(orTrim, for_elements=True), doc)
                if found: partResult = found; break
        result = partResult  # 覆盖式
        if result: break
    return result

def value_of(el, ext):
    if ext == 'text': return el.get_text(strip=True)
    if ext == 'href': return el.get('href', '')
    if ext == 'title': return el.get('title', '')
    if ext == 'src': return el.get('src', '')
    if ext.startswith('attr('): return el.get(ext[5:-1], '')
    return el.get_text(strip=True)

def extract_field(rule, root):
    trans = translate(rule, for_elements=False)
    segs, ext, has_ex = trans
    if not segs and has_ex:
        return value_of(root, ext)
    items = elements(trans, root)
    return ' '.join(value_of(e, ext) for e in items)

# ---------------- URL 构造（来自 replaceKeyPage + parseSearchRequest） ----------------
def encode_search_key(keyword):
    return urllib.parse.quote(keyword, safe='/')

def replace_key_page(url, keyword):
    out = url.replace('{{searchKey}}', '{{key}}').replace('{{searchPage}}', '{{page}}')
    out = out.replace('{{key}}', encode_search_key(keyword))
    out = out.replace('searchKey', encode_search_key(keyword))
    out = out.replace('{{page}}', '1').replace('searchPage', '1')
    return out

def parse_search_request(raw):
    raw = raw.strip()
    idx = raw.find(',{')
    if idx < 0:
        return raw, 'GET', None, None
    url = raw[:idx]; opts = raw[idx+1:]
    method, body, charset, headers = 'GET', None, None, {}
    try:
        obj = json.loads(opts)
    except Exception:
        try: obj = json.loads(opts.replace("'", '"'))
        except Exception: obj = {}
    method = obj.get('method', 'GET')
    body = obj.get('body')
    charset = obj.get('charset')
    headers = {k: str(v) for k, v in obj.items() if k not in ('method', 'body')}
    return url, method, body, charset

def normalize(s):
    if not s: return ''
    return re.sub(r'\s+', ' ', s.replace('《', '').replace('》', '')).strip().lower()

def should_keep(name, author, intro, k):
    k = normalize(k)
    if not k: return True
    return normalize(name).find(k) >= 0 or normalize(author).find(k) >= 0 or normalize(intro).find(k) >= 0

# ---------------- 抓取 + 解码 ----------------
def detect_encoding_from_html(html_bytes):
    head = html_bytes[:2000].decode('latin-1', errors='ignore')
    m = re.search(r'<meta[^>]+charset=["\']?\s*([\w\-]+)', head, re.I)
    if m:
        c = m.group(1).lower()
        if 'gb' in c or 'gbk' in c or 'gb2312' in c or 'gb18030' in c: return 'gbk'
        if 'utf' in c: return 'utf-8'
    if 'xml' in head.lower() and 'encoding=' in head.lower():
        return 'utf-8'
    return None

def decode_body(data, declared_charset, auto=True):
    if declared_charset:
        c = declared_charset.lower()
        enc = 'gbk' if ('gb' in c) else 'utf-8'
        try: return data.decode(enc)
        except Exception: pass
    if auto:
        enc = detect_encoding_from_html(data)
        if enc:
            try: return data.decode(enc)
            except Exception: pass
        try: return data.decode('utf-8')
        except Exception: pass
        try: return data.decode('gbk')
        except Exception: pass
    try: return data.decode('utf-8')
    except Exception:
        try: return data.decode('gbk')
        except Exception: return data.decode('latin-1')

def fetch(url, referer, timeout=12):
    req = urllib.request.Request(url, headers={'User-Agent': UA, 'Referer': referer})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = resp.read()
            final = resp.geturl()
            ctype = resp.headers.get('Content-Type', '')
            return data, final, ctype, None
    except Exception as e:
        return None, url, '', str(e)

# ---------------- 主流程 ----------------
def main():
    src = json.load(open('_repro/yck.json', encoding='utf-8'))
    keyword = sys.argv[1] if len(sys.argv) > 1 else '诛仙'
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else 25
    only_utf8 = sys.argv[3] == 'utf8' if len(sys.argv) > 3 else False

    cands = []
    for s in src:
        rs = s.get('ruleSearch') or {}
        su = (rs.get('searchUrl', '') or s.get('searchUrl', '') or '')
        bl = rs.get('bookList', '') or ''
        base = s.get('bookSourceUrl', '')
        if not su or not bl or not base: continue
        su2 = su.strip()
        if su2.startswith('@js:') or '<js>' in su2: continue   # 跳过 JS 源（不在此 harness 范围）
        if '{{key}}' not in su and 'searchkey' not in su.lower() and 'searchKey' not in su: continue
        cands.append((s.get('bookSourceName', ''), base, su, bl,
                      rs.get('name', ''), rs.get('bookUrl', ''), rs.get('author', ''), rs.get('coverUrl', '')))

    print(f"候选 CSS 源: {len(cands)}，测试前 {limit} 个，关键词={keyword}，解码={'仅UTF8' if only_utf8 else '自动'}")
    total_ok = 0; total_zero = 0; total_err = 0
    for (name, base, su, bl, rname, rbook, rauthor, rcover) in cands[:limit]:
        built = replace_key_page(su, keyword)
        url, method, body, charset = parse_search_request(built)
        # 相对解析
        from urllib.parse import urljoin
        if not re.match(r'^https?://', url):
            url = urljoin(base, url)
        data, final, ctype, err = fetch(url, base)
        if data is None:
            total_err += 1
            print(f"[ERR ] {name:14s} fetch失败: {err[:60]}")
            continue
        html = decode_body(data, charset, auto=not only_utf8)
        doc = BeautifulSoup(html, 'html.parser')
        items = css_elements(bl, doc)
        kept = 0
        kept_new = 0
        sample = []
        allnames = []
        for it in items[:8]:
            nm = extract_field(rname, it) if rname else extract_field('text', it)
            bu = extract_field(rbook, it) if rbook else ''
            allnames.append(nm)
            if should_keep(nm, '', '', keyword):
                kept += 1
                if len(sample) < 3: sample.append(nm)
            # 修复后：不按关键词书名过滤，仅丢弃书名与详情链接皆空者
            if (nm or '').strip() or (bu or '').strip():
                kept_new += 1
        if kept > 0: total_ok += 1
        else: total_zero += 1
        tag = "OK  " if kept > 0 else "ZERO"
        names_preview = " / ".join(allnames[:5])
        print(f"[{tag}] {name:14s} n_elem={len(items):3d} 修复前kept={kept:3d} 修复后kept={kept_new:3d} names=[{names_preview}]")

    print(f"\n===== 汇总(CSS源): 修复前有命中={total_ok}  0命中={total_zero}  抓取失败={total_err} / 共{limit} =====")
    print(f"===== 修复后(去除关键词书名过滤): 见上各源 修复后kept 列；合计见下 =====")

if __name__ == '__main__':
    main()
