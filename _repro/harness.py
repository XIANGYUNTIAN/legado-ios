#!/usr/bin/env python3
# 忠实镜像 legado-ios 搜索主线（URL 构造 + 抓取 + 提取），对真实 yck 书源批量跑，量化命中。
# 仅复刻 Swift 逻辑，不依赖被审查拦截的引擎源文件。
import json, re, urllib.request, ssl, urllib.parse, sys, os
from bs4 import BeautifulSoup

HERE = os.path.dirname(os.path.abspath(__file__))
yck = json.load(open(os.path.join(HERE, 'yck.json'), encoding='utf-8'))
KW = '诛仙'
ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
UA='Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'

# ---------- 忠实复刻 splitSourceRule 贪婪正则 ----------
SPLIT = re.compile(r'<js>([\w\W]*?)</js>|@js:([\w\W]*)')
def split_source_rule(rule):
    segs=[]; last=0
    for m in SPLIT.finditer(rule):
        if m.start()>last:
            t=rule[last:m.start()]
            if t.strip(): segs.append(('plain',t))
        segs.append(('js', m.group(1) if m.group(1) is not None else m.group(2)))
        last=m.end()
    if last<len(rule):
        t=rule[last:]
        if t.strip(): segs.append(('plain',t))
    if not segs: segs.append(('plain',rule))
    return segs

def evaluate_search_url(rule, kw):
    # 非 @js/<js> 直接透传
    if '@js:' not in rule.lower() and '<js>' not in rule:
        return rule
    # 贪婪 @js: 段：把整段（含选项后缀）交给 JS。这里仅做语法检查：若含 { 选项后缀则标记
    return rule  # 实际 JS 求值在 App 内；此处仅构造 url 串（把 @js: 段当字面，用于检测“未求值”症状）

def replace_key_page(url, kw, page=1):
    o=url.replace('{{searchKey}}','{{key}}').replace('{{searchPage}}','{{page}}')
    o=o.replace('{{key}}',urllib.parse.quote(kw,safe='')).replace('searchKey',urllib.parse.quote(kw,safe=''))
    o=o.replace('{{page}}',str(page)).replace('searchPage',str(page))
    return o

def parse_search_request(raw):
    t=raw.strip()
    idx=t.find(',{')
    if idx<0: return t,'GET',None,{},None
    url=t[:idx]; opts=t[idx+1:]
    try: obj=json.loads(opts)
    except: 
        try: obj=json.loads(opts.replace("'",'"'))
        except: obj=None
    if not obj: return url,'GET',None,{},None
    return url, obj.get('method','GET'), obj.get('body'), obj.get('headers',{}), obj.get('charset')

# ---------- CSS 翻译（移植自 LegadoCssTranslator） ----------
def translate_selector(raw):
    s=raw.strip()
    if s.startswith('tag.'): s=s[4:]
    elif s.startswith('class.'): s='.'+s[6:]
    elif s.startswith('id.'): s='#'+s[3:]
    return s
EXTRACT={'text':'text','html':'html','owntext':'ownText','alltext':'allText','textnodes':'textNodes',
'href':'href','src':'src','srcset':'srcset','data-src':'dataSrc','class':'className','id':'id','tag':'tag','alt':'alt','title':'title'}
indexSuffix=re.compile(r'^(.*)\.(-?\d+)$'); excludeSuffix=re.compile(r'^(.*)!(-?\d+)$')
rangeSuffix=re.compile(r'^(.*)\[(-?\d+):(-?\d+)\]$'); childrenSuffix=re.compile(r'^children\[(-?\d+)\]$')
def parse_selector_segment(part):
    base=part.strip()
    if m:=childrenSuffix.match(base): return ('',[('children',int(m.group(1)))])
    ops=[]
    if m:=rangeSuffix.match(base): ops.append(('range',int(m.group(2)),int(m.group(3)))); base=m.group(1)
    if m:=excludeSuffix.match(base): ops.append(('exclude',int(m.group(2)))); base=m.group(1)
    if m:=indexSuffix.match(base):
        head=m.group(1)
        if head: ops.append(('take',int(m.group(2)))); base=head
    while base.endswith('.'): base=base[:-1]
    return (translate_selector(base),ops)
def translate(body,for_elements):
    body=body.strip()
    if body.lower().startswith('@css:'): body=body[5:]
    elif body.startswith('@@'): body=body[2:]
    parts=body.split('@'); segs=[]; extractor='text'; has_ex=False
    for i,raw in enumerate(parts):
        p=raw.strip()
        if not p: continue
        is_last=(i==len(parts)-1)
        if for_elements: segs.append(parse_selector_segment(p)); continue
        if is_last:
            low=p.lower()
            if low in EXTRACT: extractor=EXTRACT[low]; has_ex=True; continue
            if p and re.fullmatch(r'[A-Za-z0-9_\-]+',p): extractor='attr(%s)'%p; has_ex=True; continue
        segs.append(parse_selector_segment(p))
    return segs,extractor,has_ex
def select_chain(trans,root):
    segs,_,_=trans; cur=[root]
    for sel,ops in segs:
        nxt=[]
        if sel=='': nxt=cur
        else:
            try:
                for e in cur: nxt+=e.select(sel)
            except: return []
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
                for e in uni: kids+=list(e.children)
                uni=kids
        cur=uni
        if not cur: return []
    return cur
def value_of(el,ext):
    if ext=='text': return el.get_text(strip=True)
    if ext=='href': return el.get('href','')
    if ext=='title': return el.get('title','')
    if ext=='src': return el.get('src','')
    if ext.startswith('attr('): return el.get(ext[5:-1],'')
    return el.get_text(strip=True)
def extract_field(rule,root):
    segs,ext,has_ex=translate(rule,False)
    if not segs and has_ex: return value_of(root,ext)
    items=select_chain((segs,ext,has_ex),root)
    return ' '.join(value_of(e,ext) for e in items)

def looks_non_css(r):
    t=r.strip(); low=t.lower()
    if low.startswith('@css:') or t.startswith('@@'): return False
    if low.startswith(('@xpath:','@json:','@js:')) or t.startswith('<js>'): return True
    if low.startswith(('@get:','@put:')): return True
    if t.startswith(':'): return True
    if t.startswith(('$.','$[')): return True
    if t.startswith('/'): return True
    if '{{' in t: return True
    return False

def fetch(url_part,method,body,headers,referer,charset):
    if not re.match(r'^https?://',url_part):
        base=referer.rstrip('/'); url_part=base+'/'+url_part.lstrip('/')
    hd=dict(headers) if headers else {}
    if referer: hd['Referer']=referer
    if 'User-Agent' not in hd: hd['User-Agent']=UA
    req=urllib.request.Request(url_part,headers=hd,method=(method or 'GET').upper())
    if (method or 'GET').upper()=='POST' and body:
        req.data=body.encode('utf-8')
    try:
        with urllib.request.urlopen(req,timeout=20,context=ctx) as r:
            raw=r.read()
            encn=charset or (r.headers.get_content_charset() or 'utf-8')
            return raw.decode(encn,'replace'),None
    except Exception as e:
        return None,str(e)[:90]

# ---------- 批量跑 ----------
plain=0; js=0; jsonmode=0; other=0
hit_srcs=0; zero_srcs=0; err_srcs=0
samples=[]
LIMIT=int(sys.argv[1]) if len(sys.argv)>1 else 80
count=0
for s in yck:
    rs=s.get('ruleSearch') or {}
    su=(rs.get('searchUrl','') or s.get('searchUrl','')) or ''
    bl=(rs.get('bookList','') or '').strip()
    name_r=(rs.get('name','') or '').strip()
    if not su or not bl: continue
    count+=1
    if count>LIMIT: break
    is_js = su.strip().lower().startswith('@js:') or '<js>' in su
    is_json = bl.startswith('$.') or bl.startswith('$[')
    if is_js: js+=1
    elif is_json: jsonmode+=1
    else: plain+=1
    # URL 构造（忠实：@js 源若未求值则 url 含 @js: 字样——这里直接用原始 su 走 replaceKeyPage，模拟“未求值”）
    url_str = replace_key_page(su, KW, 1)
    url_part,method,body,headers,charset = parse_search_request(url_str)
    if is_js and ('@js:' in url_part.lower() or '<js>' in url_part):
        # 未求值症状
        err_srcs+=1; samples.append((s.get('bookSourceName'),'URL含@js:未求值',0)); continue
    html,err=fetch(url_part,method,body,headers,s.get('bookSourceUrl',''),charset)
    if err:
        err_srcs+=1; samples.append((s.get('bookSourceName'),'ERR:'+err,0)); continue
    try: doc=BeautifulSoup(html,'html.parser')
    except: err_srcs+=1; samples.append((s.get('bookSourceName'),'PARSE',0)); continue
    if not looks_non_css(bl):
        items=select_chain(translate(bl,True),doc)
    else:
        items=[]
    kept=sum(1 for it in items if not isinstance(it,tuple) and extract_field(name_r,it).strip())
    if kept>0: hit_srcs+=1
    else: zero_srcs+=1
    if len(samples)<25: samples.append((s.get('bookSourceName'),'ok' if kept else '0hit',kept))

print(f"处理 {count} 源: plain(CSS)={plain} json={jsonmode} js={js}")
print(f"命中源={hit_srcs}  0命中源={zero_srcs}  错误源={err_srcs}")
print("--- 样例(前25) ---")
for n,st,k in samples: print(f"  [{n}] {st} {('命中'+str(k)) if isinstance(k,int) and k else ''}")
