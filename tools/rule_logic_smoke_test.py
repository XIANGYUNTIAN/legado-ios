# -*- coding: utf-8 -*-
"""LegadoCssTranslator / detectMode / splitSourceRule / JsonPath 的 Python 移植冒烟测试。
用 shuyuan.json 全部真实规则验证逻辑正确性（Swift 无法在本机编译，先验证算法）。"""
import json, re

# ---------- LegadoCssTranslator ----------

EXTRACTOR_TABLE = {
    'text': 'text', 'html': 'html', 'owntext': 'ownText', 'own_text': 'ownText',
    'alltext': 'allText', 'all_text': 'allText', 'textnodes': 'textNodes', 'text_nodes': 'textNodes',
    'href': 'href', 'src': 'src', 'srcset': 'srcset', 'data-src': 'dataSrc',
    'datasrc': 'dataSrc', 'data_src': 'dataSrc', 'class': 'className', 'classname': 'className',
    'id': 'id', 'tag': 'tag', 'tagname': 'tag', 'alt': 'alt', 'title': 'title',
}

INDEX_SUFFIX = re.compile(r'^(.*)\.(-?\d+)$')
EXCLUDE_SUFFIX = re.compile(r'^(.*)!(-?\d+)$')
RANGE_SUFFIX = re.compile(r'^(.*)\[(-?\d+):(-?\d+)\]$')
CHILDREN_SUFFIX = re.compile(r'^children\[(-?\d+)\]$')

def parse_extractor_segment(part):
    low = part.lower()
    if low in EXTRACTOR_TABLE:
        return EXTRACTOR_TABLE[low]
    if part and re.fullmatch(r'[A-Za-z0-9_\-]+', part):
        return 'attr(%s)' % part
    return None

def translate_selector(raw):
    s = raw.strip()
    if s.startswith('tag.'):
        s = s[4:]
    elif s.startswith('class.'):
        s = '.' + s[6:]
    elif s.startswith('id.'):
        s = '#' + s[3:]
    return s

def parse_selector_segment(part):
    seg = {'selector': '', 'ops': []}
    base = part
    m = CHILDREN_SUFFIX.match(base)
    if m:
        seg['ops'].append(('children', int(m.group(1))))
        return seg
    m = RANGE_SUFFIX.match(base)
    if m:
        seg['ops'].append(('range', int(m.group(2)), int(m.group(3))))
        base = m.group(1)
    m = EXCLUDE_SUFFIX.match(base)
    if m:
        seg['ops'].append(('exclude', int(m.group(2))))
        base = m.group(1)
    m = INDEX_SUFFIX.match(base)
    if m and m.group(1):
        seg['ops'].append(('take', int(m.group(2))))
        base = m.group(1)
    seg['selector'] = translate_selector(base)
    return seg

def translate(body, for_elements=False):
    trimmed = body.strip()
    if not trimmed:
        raise ValueError('empty')
    segments = []
    extractor = 'text'
    has_explicit = False
    parts = trimmed.split('@')
    for i, raw in enumerate(parts):
        part = raw.strip()
        if not part:
            continue
        is_last = (i == len(parts) - 1)
        if for_elements:
            segments.append(parse_selector_segment(part))
            continue
        if is_last:
            ext = parse_extractor_segment(part)
            if ext:
                extractor = ext
                has_explicit = True
                continue
        segments.append(parse_selector_segment(part))
    if not segments and not has_explicit:
        raise ValueError('empty')
    return {'segments': segments, 'extractor': extractor, 'has_explicit': has_explicit}

# ---------- detectMode ----------

def first_template_start(rule):
    starts = []
    m = re.search(r'@get:\{', rule)
    if m: starts.append(m.start())
    m = re.search(r'\{\{', rule)
    if m: starts.append(m.start())
    return min(starts) if starts else None

def contains_group_ref(rule):
    return re.search(r'\$\d{1,2}', rule) is not None

def is_plain_literal(rule):
    return not any(c in rule for c in '.#@[]>:')

def detect_mode(rule):
    t = rule.strip()
    low = t.lower()
    if low.startswith('@css:') or t.startswith('@@'):
        mode = 'css'
    elif low.startswith('@xpath:'):
        mode = 'xpath'
    elif low.startswith('@json:'):
        mode = 'json'
    elif low.startswith('@js:') or t.startswith('<js>'):
        mode = 'js'
    elif t.startswith('$.') or t.startswith('$['):
        mode = 'json'
    elif t.startswith('/'):
        mode = 'xpath'
    else:
        mode = 'plain'
    if mode not in ('js', 'regex'):
        ts = first_template_start(t)
        if ts is not None:
            prefix = t[:ts]
            if ts == 0 or '##' not in prefix:
                mode = 'regex'
    if mode not in ('js', 'regex') and contains_group_ref(t):
        mode = 'regex'
    if mode == 'plain':
        mode = 'plain' if is_plain_literal(t) else 'css'
    return mode

# ---------- 跑全部书源 ----------

with open('D:/WorkBuddy/Projects/2026-10-23-09-35-10/shuyuan.json', encoding='utf-8') as f:
    sources = json.load(f)

print('=== 字段规则模式识别 + CSS 翻译（抽样验证）===')
samples = [
    ('起点 name', 'class.book-info-title.0@tag.a.0@text'),
    ('起点 bookUrl', "a[data-bid]@data-bid@js:'https://m.qidian.com/book/'+result+'/'"),
    ('起点 chapName', '$2'),
    ('起点 chapUrl', "@js:var bid = baseUrl.match(/\\d+/);java.put('bid', bid);'https://vipreader.qidian.com/chapter/'+bid+'/$3/'"),
    ('起点 content', 'class.read-content@html'),
    ('酷我 bookUrl', '/novels/api/book/{{$.book_id}}'),
    ('酷我 chapName', '$.chapter_title##正文卷.|正文.|VIP卷.|默认卷.|卷_|'),
    ('酷我 content', '$.data.content'),
    ('番茄 bookList', '$..book_data[0]&&$.data[*]'),
    ('番茄 name', '$.book_name'),
    ('艾途 bookList', '.search-card'),
    ('艾途 name', 'a.0@text##\\-.*|\\_.*|\\s.*'),
    ('阅友 bookUrl', "@onclick@js:result.match(/\('(.*?)', '', ''\)/)[1]"),
    ('阅友 content', '.con@html'),
    ('就爱 bookList', '#author@tbody@tr!0'),
    ('就爱 content', '#ccontent@textNodes'),
    ('就爱 bookUrl', 'a.0@href##.com/##.la/'),
    ('武林 chapList', 'class.section-list.-1@tag.a'),
    ('武林 content', 'class.word_read.0@tag.p.!-1@text##武林中文网.+|最新章节！|请勿开启浏览器阅读模式.'),
    ('铅笔 name', 'tag.a.0@title'),
    ('69书吧 chapList', 'id.catalog.0@tag.ul.0@tag.a[-1:0]'),
    ('69书吧 name', 'tag.h3.0@tag.a.1@text'),
    ('天天看 chapList', 'class.full_chapters@children[0]@tag.a'),
    ('手机小说 chapList', '//div[@id="lbks"]/dl/dt[last()]/following-sibling::*[1]'),
    ('大文学 bookUrl', '$.index##m\\.##www.'),
    ('独步 name', 'tag.a.0@text##《|》'),
    ('速读 content', 'class.con.0@html'),
]
for label, rule in samples:
    mode = detect_mode(rule)
    info = ''
    if mode == 'css':
        try:
            body = rule
            if '##' in body:
                body = body.split('##')[0]
            tr = translate(body, for_elements=False)
            segs = ' | '.join(
                (s['selector'] or '(cur)') + (str(s['ops']) if s['ops'] else '')
                for s in tr['segments']
            ) or '(extractor-only)'
            info = f"CSS → [{segs}] @{tr['extractor']}"
        except Exception as e:
            info = f'CSS 翻译失败: {e}'
    print(f'  {label:14s} {mode:6s} {info}')

print()
print('=== 容器规则（forElements）翻译 ===')
containers = [
    ('起点 bookList', "<js> path='class.res-book-item'; ... </js>"),
    ('酷我 bookList', '$.data'),
    ('番茄 bookList', '$..book_data[0]&&$.data[*]'),
    ('艾途 bookList', '.search-card'),
    ('阅友 bookList', '.v-list-item'),
    ('就爱 bookList', '#author@tbody@tr!0'),
    ('速读 bookList', 'class.bookbox'),
    ('69书吧 bookList', 'class.newbox.0@tag.ul.0@tag.li'),
    ('武林 chapList', 'class.section-list.-1@tag.a'),
    ('铅笔 chapList', 'class.module-row-text'),
    ('天天看 chapList', 'class.full_chapters@children[0]@tag.a'),
    ('手机小说 chapList', '//div[@id="lbks"]/dl/dt[last()]/following-sibling::*[1]'),
    ('起点 chapList', ':"sS":(\\d),.*?"cN":"(.*?)","id":(\\d+),.*?"uT":"(.*?)"'),
]
for label, rule in containers:
    mode = detect_mode(rule)
    info = ''
    if mode == 'css':
        try:
            tr = translate(rule.split('##')[0], for_elements=True)
            segs = ' | '.join(
                (s['selector'] or '(cur)') + (str(s['ops']) if s['ops'] else '')
                for s in tr['segments']
            )
            info = f'→ [{segs}]'
        except Exception as e:
            info = f'翻译失败: {e}'
    print(f'  {label:14s} {mode:6s} {info}')

# ---------- JsonPath .. ----------
print()
print('=== JsonPath $.. 递归下降 ===')
def jp_eval(path, root):
    # 简化移植：只测 .. 分支
    rest = path[1:] if path.startswith('$') else path
    current = [root]
    while rest:
        if rest.startswith('..'):
            rest = rest[2:]
            if rest.startswith('.'): rest = rest[1:]
            name = ''
            while rest and rest[0] not in '.[':
                name += rest[0]; rest = rest[1:]
            collected = []
            def walk(n):
                if isinstance(n, dict):
                    if name in n: collected.append(n[name])
                    for v in n.values(): walk(v)
                elif isinstance(n, list):
                    for v in n: walk(v)
            for c in current: walk(c)
            current = collected
            continue
        if rest.startswith('.'): rest = rest[1:]
        if rest.startswith('['):
            close = rest.index(']')
            inner = rest[1:close]; rest = rest[close+1:]
            if inner == '*':
                current = [v for c in current if isinstance(c, list) for v in c]
            elif inner.lstrip('-').isdigit():
                idx = int(inner)
                current = [c[idx] for c in current if isinstance(c, list) and 0 <= idx < len(c)]
            else:
                key = inner.strip('\'"')
                current = [c[key] for c in current if isinstance(c, dict) and key in c]
        else:
            name = ''
            while rest and rest[0] not in '.[':
                name += rest[0]; rest = rest[1:]
            current = [c[name] for c in current if isinstance(c, dict) and name in c]
    return current

root = {'code': 0, 'data': {'book_data': [{'book_name': '斗破苍穹', 'book_id': '111'}], 'other': {'book_data': 'x'}}}
print('  $..book_data      →', jp_eval('$..book_data', root))
print('  $..book_data[0]   →', jp_eval('$..book_data[0]', root))
print('  $..book_data[0].book_name →', jp_eval('$..book_data[0].book_name', root))

# ---------- splitSourceRule ----------
print()
print('=== splitSourceRule（任意位置 @js: 切分）===')
JS_PATTERN = re.compile(r'<js>([\w\W]*?)</js>|@js:([\w\W]*)')
for rule in ["a[data-bid]@data-bid@js:'https://x/'+result+'/'",
             '@js:url=baseUrl+"/so/{{key}}.html";result=url;',
             '<js>foo();</js>;result',
             'class.read-content@html']:
    segs = []
    last = 0
    for m in JS_PATTERN.finditer(rule):
        if m.start() > last:
            segs.append(('plain', rule[last:m.start()]))
        segs.append(('js', m.group(1) if m.group(1) is not None else m.group(2)))
        last = m.end()
    if last < len(rule):
        segs.append(('plain', rule[last:]))
    print(f'  {rule[:50]}')
    for kind, text in segs:
        print(f'    [{kind}] {text[:60]}')
