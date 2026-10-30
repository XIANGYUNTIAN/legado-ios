import json, re, urllib.request, ssl, urllib.parse, os
from lxml import html as LHTML
from lxml.cssselect import CSSSelector

data = json.load(open('s1.json', encoding='utf-8'))
srcs = data if isinstance(data, list) else [data]

ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
UA='Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'
HEAD={'User-Agent':UA,'Accept-Language':'zh-CN,zh;q=0.9','Accept':'text/html,application/xhtml+xml,application/xml;q=0.9,*/*'}

index_suffix = re.compile(r'^(.*)\.(-?\d+)$')
exclude_suffix = re.compile(r'^(.*)!(-?\d+)$')
range_suffix = re.compile(r'^(.*)\[(-?\d+):(-?\d+)\]$')
children_suffix = re.compile(r'^children\[(-?\d+)\]$')

def translate_segment(base):
    base=base.strip()
    ops=[]
    if base=='':return ('',[],None)
    m=children_suffix.match(base)
    if m: return ('',[('children',int(m.group(1)))],None)
    m=range_suffix.match(base)
    if m: base=m.group(1)
    m=exclude_suffix.match(base)
    if m: base=m.group(1); ops.append(('exclude',int(m.group(2))))
    m=index_suffix.match(base)
    if m and m.group(1)!='':
        base=m.group(1); ops.append(('take',int(m.group(2))))
    base=base.rstrip('.')
    if base.startswith('tag.'): base=base[4:]
    elif base.startswith('class.'): base='.'+base[6:]
    elif base.startswith('id.'): base='#'+base[3:]
    return (base,ops,None)

def translate(rule):
    body=rule.strip()
    if body.lower().startswith('@css:'): body=body[5:]
    elif body.startswith('@@'): body=body[2:]
    body=body.strip()
    segs=[]
    for p in body.split('@'):
        p=p.strip()
        if p=='': continue
        sel,ops,_=translate_segment(p)
        segs.append((sel,ops))
    return segs

def select_booklist(rule, doc):
    segs=translate(rule)
    cur=[doc]
    for sel,ops in segs:
        nxt=[]
        if sel=='':
            nxt=cur
        else:
            try:
                cs=CSSSelector(sel)
                for el in cur:
                    try: nxt+=cs(el)
                    except Exception: pass
            except Exception as e:
                return [], f'BAD_SELECTOR[{sel}]:{e}'
        seen=set(); uniq=[]
        for e in nxt:
            if id(e) not in seen: seen.add(id(e)); uniq.append(e)
        for op,val in ops:
            if op=='take':
                idx = val if val>=0 else len(uniq)+val
                uniq = [uniq[idx]] if 0<=idx<len(uniq) else []
            elif op=='exclude':
                idx = val if val>=0 else len(uniq)+val
                if 0<=idx<len(uniq): uniq.pop(idx)
            elif op=='children':
                kids=[]
                for e in uniq: kids+=list(e)
                uniq=kids
        cur=uniq
        if not cur: return [],'EMPTY_AT_SEG'
    return cur,None

def enc(kw): return urllib.parse.quote(kw, safe='')

def build_url_and_fetch(s, kw):
    su=(s.get('searchUrl') or '').strip()
    base=s.get('bookSourceUrl','').rstrip('/')
    if su.startswith('@js:') or su.startswith('<js>') or '{{java' in su or '{{encodeURI' in su:
        return None,'JS_FORM_SKIP'
    opts={}; url_part=su
    if ',{' in su:
        idx=su.index(',{')
        url_part=su[:idx]
        try: opts=json.loads(su[idx+1:])
        except: opts={}
    kw_e=enc(kw)
    u=url_part.replace('{{key}}',kw_e).replace('searchKey',kw_e).replace('{{searchPage}}','1').replace('searchPage','1')
    if '{{' in u or '}}' in u:
        u=u.replace('{{','%7B%7B').replace('}}','%7D%7D')
    if not re.match(r'^https?://', u):
        u=base+'/'+u.lstrip('/')
    method=str(opts.get('method','GET')).upper()
    charset=(opts.get('charset') or '').lower()
    body=None
    if method=='POST':
        b=opts.get('body','').replace('{{key}}',kw_e).replace('searchKey',kw_e)
        body=b.encode('gb18030' if 'gb' in charset else 'utf-8')
    try:
        req=urllib.request.Request(u, data=body, headers=HEAD, method=method)
        with urllib.request.urlopen(req, timeout=25, context=ctx) as r:
            raw=r.read()
            encn=r.headers.get_content_charset() or ('gb18030' if 'gb' in charset else 'utf-8')
            try: html=raw.decode(encn)
            except: html=raw.decode('utf-8','replace')
            return html,None
    except Exception as e:
        return None,f'FETCH_ERR:{e}'

# target tokens to check presence in raw HTML
targets={
 '📂得奇小说':['bookbox'],
 '📂得奇小说网':['item'],
 '📂恩京书房':['cat-search-item','post'],
 '📂故事族':['flex-wrp','novel-list'],
 '📂烟锁重楼':['mySearch'],
}
picks=list(targets.keys())
seen=set(); chosen=[]
for s in srcs:
    bn=s.get('bookSourceName','').strip()
    if any(p in bn for p in picks) and bn not in seen:
        seen.add(bn); chosen.append(s)

kw='诛仙'
outdir='bisect_out'
os.makedirs(outdir, exist_ok=True)
print('bisect', len(chosen),'sources for kw=诛仙')
for s in chosen:
    bn=s.get('bookSourceName','').strip()
    rs=s.get('ruleSearch') or {}
    bl=(rs.get('bookList') or '').strip()
    html,err=build_url_and_fetch(s,kw)
    if err:
        print(f'[SKIP] {bn}: {err}'); continue
    toks=targets.get(bn,[])
    present={t: (t in html) for t in toks}
    try:
        doc=LHTML.fromstring(html)
        if bl.startswith('@css:') or bl.startswith('@@') or (not bl.startswith('@') and not bl.startswith('$') and not bl.startswith('/')):
            els,be=select_booklist(bl,doc)
        else:
            els,be=[],'NONCSS_FORM'
    except Exception as e:
        els,be=[],f'PARSE:{e}'
    # dump html
    safe=re.sub(r'\W+','_',bn)
    open(f'{outdir}/{safe}.html','w',encoding='utf-8').write(html)
    print(f'{bn:12s} len={len(html):7d} bookList={bl[:30]:30s} matched={len(els)} {("("+str(be)+")") if be else ""}')
    print(f'    target-present: {present}')
