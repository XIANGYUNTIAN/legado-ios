import json, re, urllib.request, ssl, urllib.parse, os
from lxml import html as LHTML
from lxml.cssselect import CSSSelector

data = json.load(open('s1.json', encoding='utf-8'))
srcs = data if isinstance(data, list) else [data]
ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
GENERIC_UA='Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'

EXTRACTORS={'text','html','owntext','own_text','alltext','all_text','textnodes','text_nodes',
            'href','src','srcset','data-src','datasrc','data_src','class','classname','id','tag','tagname','alt','title'}
ATTRCHARS=set('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_')
def parse_extractor_segment(part):
    if part in EXTRACTORS: return part
    if part and all(c in ATTRCHARS for c in part): return '@'+part
    return None
index_suffix = re.compile(r'^(.*)\.(-?\d+)$')
exclude_suffix = re.compile(r'^(.*)!(-?\d+)$')
range_suffix = re.compile(r'^(.*)\[(-?\d+):(-?\d+)\]$')
children_suffix = re.compile(r'^children\[(-?\d+)\]$')
def parse_selector_segment(base):
    base=base.strip(); ops=[]
    m=children_suffix.match(base)
    if m: return ('',[('children',int(m.group(1)))])
    m=range_suffix.match(base)
    if m:
        a=int(m.group(2)); b=int(m.group(3)); base=m.group(1); ops.append(('range',a,b))
    m=exclude_suffix.match(base)
    if m:
        n=int(m.group(2)); base=m.group(1); ops.append(('exclude',n))
    m=index_suffix.match(base)
    if m and m.group(1)!='':
        n=int(m.group(2)); base=m.group(1); ops.append(('take',n))
    while base.endswith('.'): base=base[:-1]
    s=base.strip()
    if s.startswith('tag.'): s=s[4:]
    elif s.startswith('class.'): s='.'+s[6:]
    elif s.startswith('id.'): s='#'+s[3:]
    return (s,ops)
def translate(rule, for_elements):
    body=rule.strip()
    if body.lower().startswith('@css:'): body=body[5:]
    elif body.startswith('@@'): body=body[2:]
    body=body.strip()
    parts=body.split('@'); segments=[]; extractor='text'; has_ext=False
    for i,raw in enumerate(parts):
        p=raw.strip()
        if not p: continue
        is_last=(i==len(parts)-1)
        if for_elements:
            segments.append(parse_selector_segment(p)); continue
        if is_last:
            ex=parse_extractor_segment(p)
            if ex is not None:
                extractor=ex[1:] if ex.startswith('@') else ex; has_ext=True; continue
        segments.append(parse_selector_segment(p))
    return segments,extractor,has_ext
def select_chain(translation, root, for_elements):
    segments,extractor,has_ext=translation
    if (not segments) and has_ext: return [('EXTRACT', root)]
    if not segments: return []
    cur=[root]
    for sel,ops in segments:
        nxt=[]
        if sel=='': nxt=cur
        else:
            try:
                cs=CSSSelector(sel)
                for el in cur:
                    try: nxt+=cs(el)
                    except Exception: pass
            except Exception: return []
        seen=set(); uni=[]
        for e in nxt:
            if id(e) not in seen: seen.add(id(e)); uni.append(e)
        for op,val in ops:
            if op=='take':
                idx=val if val>=0 else len(uni)+val; uni=[uni[idx]] if 0<=idx<len(uni) else []
            elif op=='exclude':
                idx=val if val>=0 else len(uni)+val
                if 0<=idx<len(uni): uni.pop(idx)
            elif op=='range':
                a=val[0] if val[0]>=0 else len(uni)+val[0]; b=val[1] if val[1]>=0 else len(uni)+val[1]
                if 0<=a<len(uni) and 0<=b<len(uni): uni=list(uni[a:b+1]) if a<=b else list(reversed(uni[b:a+1]))
                else: uni=[]
            elif op=='children':
                kids=[]
                for e in uni: kids+=list(e)
                uni=kids
        cur=uni
        if not cur: return []
    return cur
def get_text(el): return (el.text_content() or '').strip() if hasattr(el,'text_content') else str(el).strip()
def get_attr(el,name): return el.get(name) or ''
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
    return get_attr(el, ext)

def looks_like_non_css(rule):
    t=rule.strip(); low=t.lower()
    if low.startswith('@css:') or t.startswith('@@'): return False
    if low.startswith(('@xpath:','@json:','@js:')) or t.startswith('<js>'): return True
    if low.startswith(('@get:','@put:')): return True
    if t.startswith(':'): return True
    if t.startswith(('$.','$[')): return True
    if t.startswith('/'): return True
    if '{{' in t: return True
    return False

# ---- FAITHFUL field extraction: emulate applyRule(##) + executeChain(||/&&/%%)
def balanced_split(text, sep):
    parts=[]; depth=0; cur=''
    for ch in text:
        if ch in '([': depth+=1
        elif ch in ')]': depth-=1
        if ch==sep and depth==0: parts.append(cur); cur=''
        else: cur+=ch
    parts.append(cur)
    return [p for p in parts]

def eval_field_alt(alt, element):
    """Evaluate one || alternative on the element (CSS path only; faithful to applyRule+applyCss+evaluateFieldRule)."""
    alt=alt.strip()
    if not alt: return []
    # faithful to applyRule: strip ## (regex replace suffix) -> baseRule
    alt = alt.split('##',1)[0].strip()
    if not alt: return []
    if looks_like_non_css(alt): return []  # JSON/XPath/JS not reproduced here (rare for name)
    # strip @css:/@@ prefix
    body=alt
    if body.lower().startswith('@css:'): body=body[5:]
    elif body.startswith('@@'): body=body[2:]
    # translate + evaluate
    tr=translate(body, False)
    els=select_chain(tr, element, False)
    out=[]
    for e in els:
        if isinstance(e,tuple): val=apply_extractor(tr[1], e[1])
        else: val=apply_extractor(tr[1], e) if tr[1] else get_text(e)
        if val.strip(): out.append(val.strip())
    return out

def field_extract(rule, element):
    # executeChain: split && then ||
    parts_and = balanced_split(rule, '&')
    result=[]
    for pand in parts_and:
        alt_result=None
        for alt in balanced_split(pand, '|'):
            vals=eval_field_alt(alt, element)
            if vals:
                alt_result=vals; break
        if alt_result: result+=alt_result
    # emulate getString join by \n (first list wins per ||; && concatenates)
    return '\n'.join(result)

# ---- URL building ----
def encode_key(kw): return urllib.parse.quote(kw, safe='')
def build_request(raw, kw):
    su=raw.strip()
    su2=re.sub(r'<,page/\{\{page\}\}/>', '', su)
    enc=encode_key(kw)
    work=su2.replace('{{key}}',enc).replace('searchKey',enc).replace('{{searchPage}}','1').replace('searchPage','1')
    if ',{' in work:
        idx=work.index(',{'); url_part=work[:idx]
        try: opts=json.loads(work[idx+1:])
        except: opts={}
    else: url_part=work; opts={}
    return url_part, opts
def fetch(url_part, opts, src_headers, referer, base):
    if not re.match(r'^https?://', url_part): url_part=base.rstrip('/')+'/'+url_part.lstrip('/')
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
            raw=r.read(); encn=r.headers.get_content_charset() or 'utf-8'
            return raw.decode(encn,'replace'), None
    except Exception as e: return None, str(e)[:120]
def parse_source_headers(hstr):
    if not hstr: return {}
    try: return json.loads(hstr)
    except: return {}

KW='诛仙'
picks=['创世中文网','故事族','恩京书房','得奇小说','得奇小说网','烟锁重楼','新笔趣阁','笔趣阁','爱笔趣阁#']
seen=set(); chosen=[]
for s in srcs:
    bn=s.get('bookSourceName','').strip()
    if any(p in bn for p in picks) and bn not in seen:
        seen.add(bn); chosen.append(s)

print(f'=== FAITHFUL full-pipeline replay kw={KW} (applyRule ## + executeChain ||/&&) ===')
for s in chosen:
    bn=s.get('bookSourceName','').strip()
    rs=s.get('ruleSearch') or {}
    bl=(rs.get('bookList') or '').strip()
    name_r=(rs.get('name') or '').strip()
    url_part,opts=build_request(s.get('searchUrl',''), KW)
    h=parse_source_headers(s.get('header')); ref=s.get('bookSourceUrl','')
    html,err=fetch(url_part,opts,h,ref,ref)
    if err:
        print(f'[ERR] {bn:10s}: {err}'); continue
    try: doc=LHTML.fromstring(html)
    except Exception as e:
        print(f'[PARSE] {bn}: {e}'); continue
    # list
    if not looks_like_non_css(bl):
        items=select_chain(translate(bl,True), doc, True)
    else:
        items=[]
    kept=0; names=[]
    for it in items:
        if isinstance(it,tuple): continue
        nm=field_extract(name_r, it)
        if nm.strip():
            kept+=1; names.append(nm.strip()[:18])
    extra=''
    if bn=='⚡📂笔趣阁' and items and not isinstance(items[0],tuple):
        e0=items[0]
        extra='  DBG firstListEl outerHTML[:160]='+str(getattr(e0,'text','') if hasattr(e0,'text') else '')[:1]
        try:
            extra='  DBG h4='+str([get_text(x)[:20] for x in select_chain(translate('h4@text',False), e0, False)][:3])
        except Exception as ex: extra=' DBG '+str(ex)
    print(f'{bn:12s} list={len(items):3d} nameOK={kept:3d}  e.g. {names[:3]}{extra}')
