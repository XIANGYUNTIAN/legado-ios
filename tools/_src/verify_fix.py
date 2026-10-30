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

# Mirror Swift evaluateElementsChain (double-combinator, balanced, quote/depth aware)
def balanced_split(text, sep):
    parts=[]; depth=0; cur=''; i=0; n=len(text)
    while i < n:
        c=text[i]
        if c in '([{': depth+=1; cur+=c
        elif c in ')]}': depth-=1; cur+=c
        elif c in '"\'':
            q=c; cur+=c; i+=1
            while i<n:
                cur+=text[i]
                if text[i]==q: break
                i+=1
        elif depth==0 and text[i:i+len(sep)]==sep:
            parts.append(cur); cur=''; i+=len(sep); continue
        else:
            cur+=c
        i+=1
    parts.append(cur)
    return parts

def elements_chain(rule, root):
    """NEW combinator-aware container extraction (mirrors Swift evaluateElementsChain)."""
    rule=rule.strip()
    if not rule: return []
    result=[]; last_err=None
    for and_part in balanced_split(rule,'&&'):
        and_t=and_part.strip()
        if not and_t: continue
        part_result=[]; part_err=None
        for or_alt in balanced_split(and_t,'||'):
            or_t=or_alt.strip()
            if not or_t: continue
            merge=balanced_split(or_t,'%%')
            if len(merge)>1:
                merged=[]; merr=None
                for mp in merge:
                    m_t=mp.strip()
                    if not m_t: continue
                    try:
                        tr=translate(m_t,True); els=select_chain(tr,root,True); merged+=els
                    except Exception as e: merr=e
                if merged: part_result=merged; part_err=None; break
                elif merr: part_err=merr
                continue
            try:
                tr=translate(or_t,True); els=select_chain(tr,root,True)
                if els: part_result=els; part_err=None; break
            except Exception as e: part_err=e
        if not part_result:
            if part_err: last_err=part_err
            result=[]
        else:
            result=part_result; last_err=None
    return result

def encode_key(kw): return urllib.parse.quote(kw, safe='')
def build_request(raw, kw):
    su=raw.strip()
    su2=re.sub(r'<,page/\{\{page\}\}/>', '', su)
    su2=re.sub(r'<,page/\{\{page\}\}>', '', su2)
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
# Collect CSS-type ||/&& bookList sources with simple (non-JS) searchUrl
candidates=[]
for s in srcs:
    rs=s.get('ruleSearch') or {}
    bl=(rs.get('bookList') or '').strip()
    su=(s.get('searchUrl') or '').strip()
    if not bl: continue
    if looks_like_non_css(bl): continue          # skip @js/@json/xpath regex bookList
    if '||' not in bl and '&&' not in bl: continue
    if '@js:' in su or '<js>' in su: continue    # JS searchUrl
    if '\n' in su or '\t' in su: continue         # multi-line searchUrl (JS template)
    # skip JS-template injection like {{java...}}/{{url=...}}/{{source...}}/{{cookie...}}
    if re.search(r'\{\{\s*(java|url|source|cookie|encodeURI|js|get|put|result)', su): continue
    if re.search(r'\{\{\s*[a-zA-Z_]+\s*[=;]', su): continue  # {{x=...}} or {{x;...}}
    candidates.append(s)

print(f'CSS-type ||/&& bookList sources (clean non-JS searchUrl): {len(candidates)}')
print(f'Running full set for kw={KW}\n')

ok_old=0; ok_new=0; rows=[]
for s in candidates:
    bn=s.get('bookSourceName','').strip()
    rs=s.get('ruleSearch') or {}
    bl=(rs.get('bookList') or '').strip()
    url_part,opts=build_request(s.get('searchUrl',''), KW)
    h=parse_source_headers(s.get('header')); ref=s.get('bookSourceUrl','')
    html,err=fetch(url_part,opts,h,ref,ref)
    if err:
        rows.append(f'[ERR] {bn:16s}: {err}'); continue
    try: doc=LHTML.fromstring(html)
    except Exception as e:
        rows.append(f'[PARSE] {bn:16s}: {e}'); continue
    # OLD: whole rule as one selector (current App behavior)
    old_els = select_chain(translate(bl,True), doc, True) if not looks_like_non_css(bl) else []
    # NEW: combinator-aware
    new_els = elements_chain(bl, doc)
    if len(old_els)==0 and len(new_els)>0: ok_new+=1
    if len(old_els)>0: ok_old+=1
    tag='  <-- FIXED' if (len(old_els)==0 and len(new_els)>0) else ''
    rows.append(f'{bn:18s} OLD={len(old_els):3d}  NEW={len(new_els):3d}{tag}   rule={bl[:46]}')

print('\n'.join(rows))
print(f'\nSUMMARY: sources where OLD=0 but NEW>0 (the fix recovers hits): {ok_new}; OLD already>0: {ok_old}')
