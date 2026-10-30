#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""修正版规则解析：先按 && / || / %% 切分，@extractor 仅作用在【每个备选片段末尾】，
不再全局切 @ 破坏 || 结构。验证"成功但0命中"是否由此解析缺陷导致。"""
import json, re, urllib.parse, urllib.request
from bs4 import BeautifulSoup

UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"

def tr_sel(raw):
    s = raw.strip()
    if s.startswith('tag.'): s = s[4:]
    elif s.startswith('class.'): s = '.' + s[6:]
    elif s.startswith('id.'): s = '#' + s[3:]
    return s

indexSuffix = re.compile(r'^(.*)\.(-?\d+)$')
excludeSuffix = re.compile(r'^(.*)!(-?\d+)$')
rangeSuffix = re.compile(r'^(.*)\[(-?\d+):(-?\d+)\]$')
childrenSuffix = re.compile(r'^children\[(-?\d+)\]$')

def parse_seg(part):
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
        h = m.group(1)
        if h: ops.append(('take', int(m.group(2)))); base = h
    while base.endswith('.'): base = base[:-1]
    return (tr_sel(base), ops)

EXTRACT = {'text':'text','html':'html','owntext':'ownText','alltext':'allText','textnodes':'textNodes',
           'href':'href','src':'src','srcset':'srcset','data-src':'dataSrc','class':'className','id':'id',
           'tag':'tag','alt':'alt','title':'title'}
def parse_extractor(p):
    low = p.lower()
    if low in EXTRACT: return EXTRACT[low]
    if p and re.fullmatch(r'[A-Za-z0-9_\-]+', p): return 'attr(%s)' % p
    return None

# 把单个备选片段拆成 (selector_chain_segs, extractor)
# 片段形如 "h2 a" 或 "h2 a@text" 或 "div.foo.0@href"
def parse_leaf(leaf):
    leaf = leaf.strip()
    # 取最后一个 @ 作为 extractor 分隔
    if '@' in leaf:
        sel_part, ext_part = leaf.rsplit('@', 1)
        ext = parse_extractor(ext_part.strip())
    else:
        sel_part, ext = leaf, None
    segs = []
    for tok in sel_part.split():
        if not tok: continue
        segs.append(parse_seg(tok))
    return (segs, ext)

def select_in(sel, root):
    try: return root.select(sel)
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

def eval_segs(segs, root):
    cur = [root]
    for sel, ops in segs:
        nxt = []
        for e in cur: nxt += select_in(sel, e) if sel else cur
        seen = set(); uniq = []
        for e in nxt:
            if id(e) not in seen: seen.add(id(e)); uniq.append(e)
        cur = apply_ops(uniq, ops)
        if not cur: return []
    return cur

def value_of(el, ext):
    if ext is None: ext = 'text'
    if ext == 'text': return el.get_text(strip=True)
    if ext == 'href': return el.get('href', '')
    if ext == 'title': return el.get('title', '')
    if ext == 'src': return el.get('src', '')
    if ext.startswith('attr('): return el.get(ext[5:-1], '')
    return el.get_text(strip=True)

# 完整规则求值（支持 && / || / %% 与每片段 @extractor）
def eval_rule(rule, doc):
    body = rule.strip()
    if body.lower().startswith('@css:'): body = body[5:].strip()
    elif body.startswith('@@'): body = body[2:].strip()
    result = []
    for and_part in re.split(r'&&', body):
        and_part = and_part.strip()
        if not and_part: continue
        grp = []
        for or_part in re.split(r'\|\|', and_part):
            or_part = or_part.strip()
            if not or_part: continue
            merges = re.split(r'%%', or_part)
            if len(merges) > 1:
                merged = []
                for mp in merges:
                    mp = mp.strip()
                    if not mp: continue
                    segs, ext = parse_leaf(mp)
                    els = eval_segs(segs, doc)
                    merged += [(e, ext) for e in els]
                if merged:
                    grp = merged; break
            else:
                segs, ext = parse_leaf(or_part)
                els = eval_segs(segs, doc)
                if els:
                    grp = [(e, ext) for e in els]; break
        if not grp:
            return []
        # 对结果再取其一（AND 仅简单取首个 group 的元素作为 root 继续）—— 这里容器用 AND 时取交集近似
        result = grp
        # 简化：多 AND 段时，将当前结果作为下一 AND 段的 root 集合
        # 但字段抽取一般无 &&，这里保持 result=grp
        break
    # 返回 (element, extractor) 列表
    return result

def extract_field(rule, root):
    leaves = eval_rule(rule, root)
    if not leaves:
        return ''
    out = []
    for el, ext in leaves:
        out.append(value_of(el, ext))
    return ' '.join(out)

def fetch(url, referer, timeout=12):
    req = urllib.request.Request(url, headers={'User-Agent': UA, 'Referer': referer})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read(), resp.geturl(), resp.headers.get('Content-Type', ''), None
    except Exception as e:
        return None, url, '', str(e)[:90]

def detect_encoding(data):
    head = data[:2000].decode('latin-1', errors='ignore')
    m = re.search(r'<meta[^>]+charset=["\']?\s*([\w\-]+)', head, re.I)
    if m:
        c = m.group(1).lower()
        if 'gb' in c: return 'gbk'
        if 'utf' in c: return 'utf-8'
    return None

def decode_body(data):
    enc = detect_encoding(data)
    if enc:
        try: return data.decode(enc)
        except Exception: pass
    for enc in ('utf-8','gbk','latin-1'):
        try: return data.decode(enc)
        except Exception: pass
    return data.decode('latin-1', errors='ignore')

def main():
    src = json.load(open('_repro/yck.json', encoding='utf-8'))
    keyword = '诛仙'
    # 只验证之前 n_elem>0 但 kept=0 的 52书库，以及几个 n_elem=0 的
    targets = ['52书库', '58小说网', '番茄小说', '17k小说', '搜小说', '黄金屋', '故事族']
    for s in src:
        nm = s.get('bookSourceName', '')
        if not any(t in nm for t in targets): continue
        rs = s.get('ruleSearch') or {}
        su = (rs.get('searchUrl') or s.get('searchUrl') or '')
        bl = rs.get('bookList') or ''
        base = s.get('bookSourceUrl') or ''
        if not su or not bl or not base: continue
        if str(su).strip().startswith('@js:') or '<js>' in str(su): continue
        from urllib.parse import urljoin, quote
        built = su.replace('{{key}}', quote(keyword, safe='/')).replace('{{page}}','1')
        # 剥离 ,{...} 选项
        idx = built.find(',{')
        opts = ''
        if idx >= 0:
            opts = built[idx+1:]; built = built[:idx]
        url = built if re.match(r'^https?://', built) else urljoin(base, built)
        data, final, ctype, e = fetch(url, base)
        if data is None:
            print(f"[ERR ] {nm:12s} {e}"); continue
        html = decode_body(data)
        doc = BeautifulSoup(html, 'html.parser')
        items = eval_rule(bl, doc)
        kept = 0; names = []
        for it, _ in items[:10]:
            bn = extract_field(rs.get('name',''), it) if rs.get('name') else ''
            bu = extract_field(rs.get('bookUrl',''), it) if rs.get('bookUrl') else ''
            names.append(bn)
            if (bn or '').strip() or (bu or '').strip(): kept += 1
        prev = " / ".join([n for n in names[:4] if n])
        print(f"[{'OK ' if kept>0 else 'ZERO'}] {nm:12s} n_elem={len(items):3d} kept={kept:3d} [{prev}]")

if __name__ == '__main__':
    main()
