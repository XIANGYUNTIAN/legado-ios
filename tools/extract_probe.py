#!/usr/bin/env python3
# 忠实复刻 legado-ios 的 CSS 翻译 + 逐元素抽取链路（仅用于定位 0~2 本 bug），用 lxml 模拟 SwiftSoup。
import re, json, ssl, urllib.request
from lxml import html as LH

UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

EXTRACTOR_TABLE = {
    'text':'text','html':'html','owntext':'ownText','own_text':'ownText',
    'alltext':'allText','all_text':'allText','textnodes':'textNodes','text_nodes':'textNodes',
    'href':'href','src':'src','srcset':'srcset','data-src':'dataSrc','datasrc':'dataSrc','data_src':'dataSrc',
    'class':'className','classname':'className','id':'id','tag':'tag','tagname':'tag',
    'alt':'alt','title':'title',
}

def looks_like_non_css(rule):
    t = rule.strip(); lower = t.lower()
    for p in ('@css:','@@'):
        if lower.startswith(p): return False
    for p in ('@xpath:','@json:','@js:','<js>','@get:','@put:'):
        if lower.startswith(p): return True
    for p in (':','$.','$[','/','//'):
        if t.startswith(p): return True
    if '{{' in t: return True
    return False

def strip_css_prefix(s):
    s=s.strip()
    if s.lower().startswith('@css:'): s=s[5:].strip()
    elif s.startswith('@@'): s=s[2:].strip()
    return s

def translate_selector(s):
    s=s.strip()
    if s.startswith('tag.'): return s[4:]
    if s.startswith('class.'): return '.'+s[6:]
    if s.startswith('id.'): return '#'+s[3:]
    return s

def parse_extractor_segment(part):
    if part.lower() in EXTRACTOR_TABLE: return EXTRACTOR_TABLE[part.lower()]
    if re.fullmatch(r'[A-Za-z0-9_-]+', part): return ('attr', part)
    return None

def parse_selector_segment(part):
    base = part; ops=[]
    m=re.match(r'^children\[(-?\d+)\]$', base)
    if m: return {'selector':'','ops':[('children',int(m.group(1)))]}
    m=re.match(r'^(.*)\[(-?\d+):(-?\d+)\]$', base)
    if m: ops.append(('range',int(m.group(2)),int(m.group(3)))); base=m.group(1)
    m=re.match(r'^(.*)!(-?\d+)$', base)
    if m: ops.append(('exclude',int(m.group(2)))); base=m.group(1)
    m=re.match(r'^(.*)\.(-?\d+)$', base)
    if m:
        head=m.group(1); n=int(m.group(2))
        if head: ops.append(('take',n)); base=head
    while base.endswith('.'): base=base[:-1]
    return {'selector':translate_selector(base),'ops':ops}

def translate(body, for_elements=False):
    body=body.strip()
    if not body: raise Exception('empty rule')
    segs=[]; extractor='text'; has_ext=False
    parts=body.split('@')
    for idx,raw in enumerate(parts):
        part=raw.strip()
        if not part: continue
        is_last = idx==len(parts)-1
        if for_elements:
            segs.append(parse_selector_segment(part)); continue
        if is_last:
            ext=parse_extractor_segment(part)
            if ext is not None:
                extractor=ext; has_ext=True; continue
        segs.append(parse_selector_segment(part))
    if not segs and not has_ext: raise Exception('empty')
    return {'segments':segs,'extractor':extractor,'has_explicit_extractor':has_ext}

def select_all(root, selector):
    if not selector: return [root]
    try: return root.cssselect(selector)
    except Exception: return []

def apply_op(op, els):
    k=op[0]
    if k=='take':
        n=op[1]; i=n if n>=0 else len(els)+n
        return [els[i]] if 0<=i<len(els) else []
    if k=='exclude':
        n=op[1]; i=n if n>=0 else len(els)+n
        if 0<=i<len(els): return els[:i]+els[i+1:]
        return els
    if k=='range':
        a,b=op[1],op[2]
        a=a if a>=0 else len(els)+a; b=b if b>=0 else len(els)+b
        if not(0<=a<len(els) and 0<=b<len(els)): return []
        return els[a:b+1] if a<=b else list(reversed(els[b:a+1]))
    if k=='children':
        n=op[1]; res=[]
        for e in els:
            ch=list(e); i=n if n>=0 else len(ch)+n
            if 0<=i<len(ch): res.append(ch[i])
        return res
    return els

def translate_elements(tr, root):
    cur=[root]
    for seg in tr['segments']:
        nxt=[]
        for el in cur: nxt.extend(select_all(el, seg['selector']))
        seen=set(); uniq=[]
        for e in nxt:
            if id(e) not in seen: seen.add(id(e)); uniq.append(e)
        cur=uniq
        for op in seg['ops']: cur=apply_op(op, cur)
        if not cur: return []
    return cur

def extractor_value(el, ext):
    if ext=='text': return el.text_content().strip()
    if ext=='html': return LH.tostring(el, encoding='unicode')
    if ext=='allText': return el.text_content().strip()
    if ext=='href': return el.get('href') or ''
    if ext=='src': return el.get('src') or ''
    if ext=='srcset': return el.get('srcset') or ''
    if ext=='dataSrc': return el.get('data-src') or ''
    if ext=='alt': return el.get('alt') or ''
    if ext=='title': return el.get('title') or ''
    if ext=='id': return el.get('id') or ''
    if ext=='tag': return el.tag
    if ext=='className': return el.get('class') or ''
    if isinstance(ext, tuple) and ext[0]=='attr': return el.get(ext[1]) or ''
    return el.text_content().strip()

def apply_hash_replace(value, rule):
    # legado ##replaceRegex##replacement
    if '##' not in rule: return value
    parts=rule.split('##')
    base=parts[0]; regex=parts[1] if len(parts)>1 else ''
    repl=parts[2] if len(parts)>2 else ''
    try: return re.sub(regex, repl, base and value or value)
    except Exception: return value

def evaluate_field_rule(rule, root):
    rule=rule.strip()
    body=strip_css_prefix(rule)
    tr=translate(body, for_elements=False)
    if not tr['segments']:
        return extractor_value(root, tr['extractor'])
    els=translate_elements(tr, root)
    out=[]
    for e in els:
        v=extractor_value(e, tr['extractor'])
        if v: out.append(v)
    val='\n'.join(out)
    return apply_hash_replace(val, rule) if '##' in rule else val

def extract(html, rules):
    tree=LH.fromstring(html)
    list_rule=rules.get('bookList','')
    if looks_like_non_css(list_rule): return None  # JSON/JS 源跳过
    try:
        items=translate_elements(translate(list_rule, for_elements=True), tree)
    except Exception as e:
        return ('ERR', str(e))
    names=[]
    for it in items:
        n=evaluate_field_rule(rules.get('name',''), it)
        if n: names.append(n)
    return names

def fetch(url, method='GET', body=None, charset=None):
    ctx=ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
    data=None
    if body:
        data=body.encode(charset or 'utf-8')
    req=urllib.request.Request(url, data=data, method=method, headers={'User-Agent':UA,'Referer':url})
    try:
        r=urllib.request.urlopen(req, timeout=20, context=ctx)
        raw=r.read()
        enc=r.headers.get_content_charset() or charset or 'utf-8'
        try: return raw.decode(enc)
        except Exception: return raw.decode('utf-8','ignore')
    except Exception as e:
        return f"__FETCH_ERR__{e}"

def build_url(template, kw):
    enc=urllib.parse.quote(kw, safe='')
    return template.replace('{{key}}', enc).replace('searchKey', enc).replace('{{page}}','1').replace('searchPage','1')

# 仅测简单 GET / POST 源（非 @js 型），覆盖最常见 CSS 形态
SOURCES = json.load(open('shuyuan.json'))
tests = [
    ('阅友小说', 'http://m.suixkan.com/s/1.html?keyword={{key}}&page={{page}}', 'class.item'),
    ('得奇小说网', 'https://www.deqixs.com/tag/?key={{key}}', 'class.item'),
    ('快书网', 'https://www.kuaishu5.com/search/?searchkey={{key}}', 'class.item'),
    ('天天看小说', 'https://cn.ttkan.co/novel/search?q={{key}}', 'class.novel_cell'),
    ('铅笔小说', 'https://www.23qb.com/search.html?searchkey={{key}}', 'class.module-search-item'),
    ('武林中文网', 'https://www.50zw.so/search.html', 'class.txt-list.0@tag.li'),
    ('69书吧', 'https://69shuba.cx/modules/article/search.php', 'class.newbox.0@tag.ul.0@tag.li'),
    ('速读谷', 'https://www.sudugu.co/modules/article/search.php', 'class.bookbox'),
    ('手机小说', 'https://www.shoujix.com/modules/article/search.php', 'class.novel-item'),
    ('就爱文学', 'http://www.92xs.info/modules/article/search.php', 'class.module-search-item'),
    ('艾途小说', 'https://m.aitbooks.com/search/', 'class.module-search-item'),
    ('八一中文', 'https://www.81zw2.com/search.php', 'class.bookbox'),
]

import urllib.parse
KW='诛仙'
print(f"=== 搜索「{KW}」：实测各源抽取（精确书名判定）===\n")
for name, tmpl, _ in tests:
    rules=None
    for s in SOURCES:
        if s.get('bookSourceName')==name:
            rules=s.get('ruleSearch',{}); break
    if not rules: 
        print(f"[{name}] 无规则"); continue
    url=build_url(tmpl, KW)
    # 处理 POST 型（body 在 searchUrl 选项里，这里简单处理常见的 modules/article/search.php?body=...）
    method='GET'; body=None; charset=None
    if 'search.php' in url and ('searchkey=' not in url):
        # 这类多为 POST，body=searchkey=诛仙
        method='POST'; body=f'searchkey={urllib.parse.quote(KW)}'; url=url.split('?')[0]
    if name in ('武林中文网',):
        method='POST'; body=f's={urllib.parse.quote(KW)}'; url='https://www.50zw.so/search.html'
    if name in ('艾途小说',):
        method='POST'; body=f'keyword={urllib.parse.quote(KW)}'; url='https://m.aitbooks.com/search/'
    if name in ('八一中文',):
        method='POST'; body=f'keyword={urllib.parse.quote(KW)}'; url='https://www.81zw2.com/search.php'
    html=fetch(url, method=method, body=body, charset=charset)
    if html.startswith('__FETCH_ERR__'):
        print(f"[{name}] 网络失败: {html[13:80]}"); continue
    res=extract(html, rules)
    if res is None:
        print(f"[{name}] (JSON/JS 源，本测试跳过)"); continue
    if isinstance(res, tuple):
        print(f"[{name}] 抽取异常: {res[1]}"); continue
    exact=[n for n in res if n.strip()==KW]
    print(f"[{name}] 命中书名 {len(res)} 本 | 精确『{KW}』{len(exact)} 本 | 样例: {res[:5]}")
