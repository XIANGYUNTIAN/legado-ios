import json, re, urllib.request, ssl, urllib.parse, os
from lxml import html as LHTML
from lxml.cssselect import CSSSelector

data = json.load(open('s1.json', encoding='utf-8'))
srcs = data if isinstance(data, list) else [data]

ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
GENERIC_UA='Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'

# ---------- faithful port of LegadoCssTranslator.translate (forElements variants) ----------
def looks_like_non_css(rule):
    t=rule.strip(); low=t.lower()
    if low.startswith('@css:') or t.startswith('@@'): return False
    if low.startswith('@xpath:'): return True
    if low.startswith('@json:'): return True
    if low.startswith('@js:') or t.startswith('<js>'): return True
    if low.startswith('@get:') or low.startswith('@put:'): return True
    if t.startswith(':'): return True
    if t.startswith('$.') or t.startswith('$['): return True
    if t.startswith('/'): return True
    if '{{' in t: return True
    return False

index_suffix = re.compile(r'^(.*)\.(-?\d+)$')
exclude_suffix = re.compile(r'^(.*)!(-?\d+)$')
range_suffix = re.compile(r'^(.*)\[(-?\d+):(-?\d+)\]$')
children_suffix = re.compile(r'^children\[(-?\d+)\]$')

def parse_selector_segment(base):
    base=base.strip()
    ops=[]
    m=children_suffix.match(base)
    if m: return ('',[('children',int(m.group(1)))])
    m=range_suffix.match(base)
    if m:
        a=int(m.group(1)); b=int(m.group(2)); base=m.group(3); ops.append(('range',a,b))
    m=exclude_suffix.match(base)
    if m:
        n=int(m.group(2)); base=m.group(1); ops.append(('exclude',n))
    m=index_suffix.match(base)
    if m and m.group(1)!='':
        n=int(m.group(2)); base=m.group(1); ops.append(('take',n))
    while base.endswith('.'): base=base[:-1]
    sel=translate_selector(base)
    return (sel,ops)

def translate_selector(raw):
    s=raw.strip()
    if s.startswith('tag.'): s=s[4:]
    elif s.startswith('class.'): s='.'+s[6:]
    elif s.startswith('id.'): s='#'+s[3:]
    return s

EXTRACTORS={'text','html','owntext','own_text','alltext','all_text','textnodes','text_nodes',
            'href','src','srcset','data-src','datasrc','data_src','class','classname','id','tag','tagname','alt','title'}
ATTRCHARS=set('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_')
def parse_extractor_segment(part):
    if part in EXTRACTORS: return part
    if part and all(c in ATTRCHARS for c in part): return '@'+part  # attr
    return None

# NOTE: faithful to iOS BUG — splits only on '@', does NOT handle '||' / '&&' as OR/AND.
def translate(rule, for_elements):
    body=rule.strip()
    if body.lower().startswith('@css:'): body=body[5:]
    elif body.startswith('@@'): body=body[2:]
    body=body.strip()
    parts=body.split('@')
    segments=[]; extractor='text'; has_ext=False
    for i,raw in enumerate(parts):
        p=raw.strip()
        if not p: continue
        is_last=(i==len(parts)-1)
        if for_elements:
            segments.append(parse_selector_segment(p)); continue
        if is_last:
            ex=parse_extractor_segment(p)
            if ex is not None:
                # if ex is '@xxx' -> attr selector 'xxx'
                extractor = ex[1:] if ex.startswith('@') else ex
                has_ext=True; continue
        segments.append(parse_selector_segment(p))
    return segments,extractor,has_ext

def select_chain(translation, root, for_elements):
    segments,extractor,has_ext=translation
    if for_elements and not segments:
        return []
    if (not segments) and has_ext:
        # extractor-only (e.g. 'text'): apply to root
        return [('EXTRACT', root)]
    cur=[root]
    for sel,ops in segments:
        nxt=[]
        if sel=='':
            nxt=cur
        else:
            try:
                cs=CSSSelector(sel)
                for el in cur:
                    try: nxt+=cs(el)
                    except Exception: pass
            except Exception:
                return []  # invalid selector (e.g. contains '||') -> iOS returns 0
        seen=set(); uni=[]
        for e in nxt:
            if id(e) not in seen: seen.add(id(e)); uni.append(e)
        for op,val in ops:
            if op=='take':
                idx=val if val>=0 else len(uni)+val
                uni=[uni[idx]] if 0<=idx<len(uni) else []
            elif op=='exclude':
                idx=val if val>=0 else len(uni)+val
                if 0<=idx<len(uni): uni.pop(idx)
            elif op=='range':
                a=val[0] if val>=0 else len(uni)+val[0]
                b=val[1] if val[1]>=0 else len(uni)+val[1]
                if 0<=a<len(uni) and 0<=b<len(uni):
                    uni=list(uni[a:b+1]) if a<=b else list(reversed(uni[b:a+1]))
                else: uni=[]
            elif op=='children':
                kids=[]
                for e in uni: kids+=list(e)
                uni=kids
        cur=uni
        if not cur: return []
    return cur

def get_text(el):
    return (el.text_content() or '').strip() if hasattr(el,'text_content') else str(el).strip()
def get_attr(el,name):
    return el.get(name) or ''
def apply_extractor(ext, el):
    if ext=='text': return get_text(el)
    if ext=='html': return el.text if isinstance(el,str) else ''
    if ext=='href': return get_attr(el,'href')
    if ext=='src': return get_attr(el,'src')
    if ext=='alt': return get_attr(el,'alt')
    if ext=='title': return get_attr(el,'title')
    if ext=='class' or ext=='classname': return el.get('class') or ''
    if ext=='id': return el.get('id') or ''
    if ext in ('tag','tagname'): return el.tag if hasattr(el,'tag') else ''
    # attr name
    return get_attr(el, ext)

# ---------- URL building (faithful to app: NO <,page/> handling, {{key}}/searchKey replace) ----------
def encode_key(kw):
    return urllib.parse.quote(kw, safe='')

def build_request(raw, kw):
    su=raw.strip()
    base_search=None
    # emulate replaceKeyPage: replace {{key}} and bare searchKey, {{page}} etc.
    enc=encode_key(kw)
    # handle <,page/{{page}}/> static url syntax: strip the wrapper, keep page placeholder
    su2=re.sub(r'<,page/(\{\{page\}\}|\d+)/>', '', su)
    su2=re.sub(r'<,page/\{\{page\}\}/>', '', su2)
    work=su2.replace('{{key}}',enc).replace('searchKey',enc).replace('{{searchPage}}','1').replace('searchPage','1')
    if ',{' in work:
        idx=work.index(',{')
        url_part=work[:idx]
        try: opts=json.loads(work[idx+1:])
        except: opts={}
    else:
        url_part=work; opts={}
    return url_part, opts

def fetch(url_part, opts, src_headers, referer, base):
    if not re.match(r'^https?://', url_part):
        url_part=(base.rstrip('/')+'/'+url_part.lstrip('/'))
    method=str(opts.get('method','GET')).upper()
    headers=dict(src_headers)
    if referer: headers['Referer']=referer
    if 'User-Agent' not in headers: headers['User-Agent']=GENERIC_UA
    body=None
    if method=='POST':
        b=opts.get('body','').replace('{{key}}',encode_key(KW)).replace('searchKey',encode_key(KW))
        body=b.encode('utf-8')
    req=urllib.request.Request(url_part, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=25, context=ctx) as r:
            raw=r.read()
            encn=r.headers.get_content_charset() or 'utf-8'
            return raw.decode(encn,'replace'), None
    except Exception as e:
        return None, str(e)

def parse_source_headers(hstr):
    if not hstr: return {}
    try: return json.loads(hstr)
    except: return {}

KW='诛仙'
picks=['创世中文网','故事族','恩京书房','得奇小说','得奇小说网','烟锁重楼','笔趣阁','飞卢','起点','番茄']
seen=set(); chosen=[]
for s in srcs:
    bn=s.get('bookSourceName','').strip()
    if any(p in bn for p in picks) and bn not in seen:
        seen.add(bn); chosen.append(s)

print(f'=== full-pipeline replay for kw={KW} (WITH source headers) ===')
for s in chosen:
    bn=s.get('bookSourceName','').strip()
    rs=s.get('ruleSearch') or {}
    bl=(rs.get('bookList') or '').strip()
    name_r=(rs.get('name') or '').strip()
    url_part,opts=build_request(s.get('searchUrl',''), KW)
    h=parse_source_headers(s.get('header'))
    ref=s.get('bookSourceUrl','')
    html,err=fetch(url_part,opts,h,ref,ref)
    if err:
        print(f'[ERR] {bn:10s}: {err[:80]}'); continue
    try: doc=LHTML.fromstring(html)
    except Exception as e:
        print(f'[PARSE] {bn}: {e}'); continue
    # list
    if bl.startswith('@css:') or bl.startswith('@@') or (not looks_like_non_css(bl)):
        translation=translate(bl, True)
        items=select_chain(translation, doc, True)
    else:
        items=[]
    # per-element name extraction
    kept=0; names=[]
    for it in items:
        if isinstance(it,tuple):  # extractor-only list
            continue
        # name field
        if name_r.startswith('@css:') or name_r.startswith('@@') or (not looks_like_non_css(name_r)):
            tr=translate(name_r, False)
            els=select_chain(tr, it, False)
            if els and isinstance(els[0],tuple):
                nm=apply_extractor(tr[1], els[0][1])
            elif els:
                nm=apply_extractor(tr[1], els[0]) if tr[1] else get_text(els[0])
            else:
                nm=''
        else:
            nm=''
        if nm.strip():
            kept+=1; names.append(nm.strip()[:20])
    print(f'{bn:12s} list={len(items):3d} nameOK={kept:3d}  e.g. {names[:3]}')
