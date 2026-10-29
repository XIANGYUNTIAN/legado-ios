#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""定点复现：对已知可返回结果的若干 CSS 书源实跑管线，对比修复前/后命中数。"""
import json, re, sys, urllib.parse, urllib.request
from bs4 import BeautifulSoup

UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"

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
        m = childrenSuffix.match(base); return ('', [('children', int(m.group(1)))])
    ops = []
    m = rangeSuffix.match(base)
    if m: ops.append(('range', int(m.group(2)), int(m.group(3)))); base = m.group(1)
    m = excludeSuffix.match(base)
    if m: ops.append(('exclude', int(m.group(2)))); base = m.group(1)
    m = indexSuffix.match(base)
    if m:
        head = m.group(1)
        if head: ops.append(('take', int(m.group(2)))); base = head
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
        for e in cur: nxt += select_in(sel, e) if sel else cur
        seen = set(); uniq = []
        for e in nxt:
            if id(e) not in seen: seen.add(id(e)); uniq.append(e)
        cur = apply_ops(uniq, ops)
        if not cur: return []
    return cur

def css_elements(rule, doc):
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
        result = partResult
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
    segs, ext, has_ex = translate(rule, for_elements=False)
    if not segs and has_ex: return value_of(root, ext)
    items = elements((segs, ext, has_ex), root)
    return ' '.join(value_of(e, ext) for e in items)

def replace_key_page(url, keyword):
    out = url.replace('{{searchKey}}', '{{key}}').replace('{{searchPage}}', '{{page}}')
    out = out.replace('{{key}}', urllib.parse.quote(keyword, safe='/'))
    out = out.replace('searchKey', urllib.parse.quote(keyword, safe='/'))
    out = out.replace('{{page}}', '1').replace('searchPage', '1')
    return out

def safe_url(url):
    # 对含非 ASCII 的 URL 做百分号编码（保留 scheme://host）
    m = re.match(r'^(https?://[^/]+)(.*)$', url, re.I)
    if not m: return url
    return m.group(1) + urllib.parse.quote(m.group(2), safe='/:?=&%+-_.,')

def normalize(s):
    if not s: return ''
    return re.sub(r'\s+', ' ', s.replace('《','').replace('》','')).strip().lower()

def should_keep_old(name, k):
    k = normalize(k)
    if not k: return True
    return normalize(name).find(k) >= 0

def detect_encoding(data):
    head = data[:2000].decode('latin-1', errors='ignore')
    m = re.search(r'<meta[^>]+charset=["\']?\s*([\w\-]+)', head, re.I)
    if m:
        c = m.group(1).lower()
        if 'gb' in c: return 'gbk'
        if 'utf' in c: return 'utf-8'
    return None

def decode_body(data, declared):
    if declared:
        enc = 'gbk' if 'gb' in declared.lower() else 'utf-8'
        try: return data.decode(enc)
        except Exception: pass
    enc = detect_encoding(data)
    if enc:
        try: return data.decode(enc)
        except Exception: pass
    for enc in ('utf-8','gbk','latin-1'):
        try: return data.decode(enc)
        except Exception: pass
    return data.decode('latin-1', errors='ignore')

def fetch(url, referer, timeout=12):
    req = urllib.request.Request(safe_url(url), headers={'User-Agent': UA, 'Referer': referer})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read(), resp.geturl(), None
    except Exception as e:
        return None, url, str(e)[:80]

def main():
    src = json.load(open('_repro/yck.json', encoding='utf-8'))
    keyword = sys.argv[1] if len(sys.argv) > 1 else '诛仙'
    wanted = sys.argv[2].split(',') if len(sys.argv) > 2 else []
    found = []
    for s in src:
        rs = s.get('ruleSearch') or {}
        su = (rs.get('searchUrl','') or s.get('searchUrl','') or '')
        bl = rs.get('bookList','') or ''
        base = s.get('bookSourceUrl','')
        nm = s.get('bookSourceName','')
        if not su or not bl or not base: continue
        if wanted and not any(w in nm for w in wanted): continue
        if su.strip().startswith('@js:') or '<js>' in su: continue
        found.append((nm, base, su, bl, rs.get('name',''), rs.get('bookUrl',''), rs.get('author','')))
    print(f"命中目标源 {len(found)} 个，关键词={keyword}\n")
    tot_old=tot_new=tot_elem=0
    for (nm, base, su, bl, rname, rbook, rauthor) in found:
        built = replace_key_page(su, keyword)
        from urllib.parse import urljoin
        url = built if re.match(r'^https?://', built) else urljoin(base, built)
        data, final, err = fetch(url, base)
        if data is None:
            print(f"[ERR ] {nm:16s} {err}"); continue
        html = decode_body(data, None)
        doc = BeautifulSoup(html, 'html.parser')
        items = css_elements(bl, doc)
        old_kept=0; new_kept=0; names=[]
        for it in items:
            bn = extract_field(rname, it) if rname else extract_field('text', it)
            bu = extract_field(rbook, it) if rbook else ''
            names.append(bn)
            if should_keep_old(bn, keyword): old_kept += 1
            if (bn or '').strip() or (bu or '').strip(): new_kept += 1
        tot_elem += len(items); tot_old += old_kept; tot_new += new_kept
        preview = " / ".join([n for n in names[:4] if n])
        print(f"[{nm:16s}] n_elem={len(items):3d} 修复前kept={old_kept:3d} 修复后kept={new_kept:3d} 书名样本=[{preview}]")
    print(f"\n===== 合计: 解析元素={tot_elem}  修复前(关键词过滤后)={tot_old}  修复后(仅丢空条目)={tot_new} =====")

if __name__ == '__main__':
    main()
