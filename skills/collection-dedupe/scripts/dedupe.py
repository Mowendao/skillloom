# -*- coding: utf-8 -*-
"""列表条目聚类去重：从 CSV 解析字段并判定「同款」。

用法:
  python dedupe.py --csv input.csv --out ./work
  python dedupe.py --csv input.csv --out ./work --id-col id --title-col title --text-col card_text

输出:
  work/rows.json    每条条目的原始列 + 解析出的 _code/_brand/_orig/_ver/_size/_k_*
  work/groups.json  重复组列表，含 rule/score/conf/items

判定主键优先级：厂商编号 > 日文原名 > 中文名+社团 > 包含关系 > 模糊相似。
阈值默认 0.90 自动合并，0.80~0.90 仅记录为候选（不合并）。
"""
import argparse, csv, io, json, os, re, sys
from collections import defaultdict
from difflib import SequenceMatcher

KANA = re.compile(r"[\u3041-\u3096\u30a1-\u30fa\u30fc\uff66-\uff9f]")
CJK = re.compile(r"[\u4e00-\u9fff]")
CODE_RE = re.compile(r"(RJ\d{6,8}|RG\d{5,6}|VJ\d{6}|RE\d{6}|d_\d{6})", re.I)
VER_RE = re.compile(r"[vV](\d+(?:\.\d+){1,3})")
SIZE_RE = re.compile(r"(\d+(?:\.\d+)?\s?(?:GB|MB|G|M))", re.I)

# 归一化时剔除的噪声词：只在判定「是不是同一款」时忽略，不影响展示
NOISE = ["全回想存档", "自带回想解锁", "存档", "汉化版", "ai汉化版", "内嵌", "官中", "步兵",
         "完整版", "双端", "中文版", "整合版", "本篇", "ai汉化", "汉化", "安卓直装", "直装",
         "pc", "安卓", "joiplay", "mtool", "az", "更新"]

FIELD_CUT = re.compile(
    r"社团名|社团|サークル|名字|名称|原名|原題|版本|贩卖日|发售日|发售|发布日|"
    r"文件容量|容量|分类|标签|作者|形式|游戏介绍|作品内容|简介|◆|【|。|；|;\||\n")


def norm(s):
    if not s:
        return ""
    s = s.lower()
    for n in NOISE:
        s = s.replace(n, "")
    return re.sub(r"[^\u3041-\u3096\u30a1-\u30fa\u30fc\u4e00-\u9fff\uff66-\uff9fa-z0-9]", "", s)


def strip_tags(t):
    """剥掉标题开头的【标签/标签】块与结尾的【1.2G】、[百度/夸克] 等。"""
    s = (t or "").strip()
    while True:
        m = re.match(r"^\s*[【\[]([^】\]]{1,40})[】\]]", s)
        if not m:
            break
        inner = m.group(1)
        if "/" in inner or "|" in inner or re.fullmatch(r"[\u4e00-\u9fffA-Za-z0-9 ]{2,20}", inner):
            s = s[m.end():]
        else:
            break
    s = re.sub(r"[\[【][^\]】]{0,12}(?:GB|MB|\d+G|\d+M)[^\]】]{0,4}[\]】]\s*$", "", s, flags=re.I)
    s = re.sub(r"[\[【](?:百度|夸克|vk|迅雷|MEGA|网盘)[^\]】]*[\]】]", "", s, flags=re.I)
    return s.strip()


def grab(text, key):
    """取 `key：值`，截到下一个字段标签/句号为止。"""
    m = re.search(re.escape(key) + r"\s*[:：]?\s*", text)
    if not m:
        return ""
    rest = text[m.end():]
    c = FIELD_CUT.search(rest)
    v = (rest[:c.start()] if c else rest).strip(" :：,，、#-—")
    v = re.sub(r"^#+", "", v).strip()
    return v if 1 <= len(v) <= 90 else ""


def jp_part(t):
    """标题里含假名的片段（社团名要先被 strip_tags 剥掉，否则会污染日文名）。"""
    segs = re.split(r"[\s/|｜()（）]+", strip_tags(t))
    return " ".join(x for x in segs if KANA.search(x)).strip()


def zh_part(t):
    segs = re.split(r"[\s/|｜()（）]+", strip_tags(t))
    return " ".join(x for x in segs if CJK.search(x) and not KANA.search(x)).strip()


def parse(rows, args):
    for r in rows:
        t = r.get(args.title_col) or ""
        c = r.get(args.text_col) or ""
        both = t + " " + c
        mc = CODE_RE.search(both)
        r["_code"] = mc.group(1).upper() if mc else ""
        mv = VER_RE.search(t)
        r["_ver"] = mv.group(1) if mv else ""
        ms = SIZE_RE.search(both)
        r["_size"] = ms.group(1).replace(" ", "") if ms else ""

        r["_brand"] = grab(c, "社团名") or grab(c, "社团")
        if not r["_brand"]:
            m = re.search(r"[\[【](\d{6})[\]】]\s*[\[【]([^\]】]{2,40})[\]】]", t)
            if m:
                r["_brand"] = m.group(2).strip(" #")

        r["_orig"] = grab(c, "原名") or grab(c, "原題")
        r["_zhname"] = grab(c, "名字") or grab(c, "名称")
        jp = jp_part(t)
        r["_jp"] = (jp_part(r["_orig"]) or r["_orig"] or jp).strip() or jp
        r["_zh"] = (r["_zhname"] or zh_part(t)).strip()

        r["_k_code"] = r["_code"]
        r["_k_jp"] = norm(r["_jp"])
        r["_k_zh"] = norm(r["_zh"])
        r["_k_brand"] = norm(r["_brand"])
    return rows


def cluster(rows, hi=0.90, lo=0.80):
    n = len(rows)
    parent = list(range(n))
    edges = []

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    def add(a, b, rule, score=1.0):
        if a != b and find(a) != find(b):
            union(a, b)
        edges.append((a, b, rule, round(score, 3)))

    buckets = defaultdict(list)
    for i, r in enumerate(rows):
        if len(r["_k_code"]) >= 6:
            buckets[r["_k_code"]].append(i)
    for v in buckets.values():
        for j in v[1:]:
            add(v[0], j, "厂商编号一致")

    for key, rule, ml in (("_k_jp", "日文原名一致", 8), ("_k_zh", "中文名一致+社团一致", 9)):
        b = defaultdict(list)
        for i, r in enumerate(rows):
            k = r[key]
            if len(k) >= ml and (key != "_k_zh" or r["_k_brand"]):
                b[k].append(i)
        for v in b.values():
            for j in v[1:]:
                add(v[0], j, rule)

    def tg(s):
        return {s[i:i + 3] for i in range(len(s) - 2)} if len(s) >= 3 else {s}

    for key, rhi, rlo in (("_k_jp", "日文名高相似", "日文名低相似"),
                          ("_k_zh", "中文名高相似", "中文名低相似")):
        idx = defaultdict(list)
        for i, r in enumerate(rows):
            if len(r[key]) >= 8:
                for g in tg(r[key]):
                    idx[g].append(i)
        pairs = set()
        for ids in idx.values():
            if len(ids) > 60:      # 过于常见的 gram 不作阻塞键
                continue
            for a in range(len(ids)):
                for b in range(a + 1, len(ids)):
                    pairs.add((ids[a], ids[b]))
        for i, j in pairs:
            s1, s2 = rows[i][key], rows[j][key]
            if abs(len(s1) - len(s2)) > max(6, 0.35 * max(len(s1), len(s2))):
                continue
            if len(s1) >= 8 and len(s2) >= 8 and (s1 in s2 or s2 in s1):
                add(i, j, rhi + "(包含)", 0.95)
                continue
            rt = SequenceMatcher(None, s1, s2).ratio()
            if rt >= hi:
                add(i, j, rhi, rt)
            elif rt >= lo:
                add(i, j, rlo, rt)
    return parent, edges


ORDER = {"厂商编号一致": 5, "日文原名一致": 5, "中文名一致+社团一致": 4,
         "日文名高相似(包含)": 4, "中文名高相似(包含)": 4,
         "日文名高相似": 3, "中文名高相似": 3, "日文名低相似": 2, "中文名低相似": 2}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", required=True)
    ap.add_argument("--out", default=".")
    ap.add_argument("--id-col", default="id")
    ap.add_argument("--title-col", default="title")
    ap.add_argument("--text-col", default="card_text")
    ap.add_argument("--url-col", default="url")
    ap.add_argument("--high", type=float, default=0.90)
    ap.add_argument("--low", type=float, default=0.80)
    ap.add_argument("--encoding", default="utf-8-sig")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    with io.open(args.csv, encoding=args.encoding, newline="") as f:
        rows = list(csv.DictReader(f))
    print("读入条目:", len(rows))

    rows = parse(rows, args)
    parent, edges = cluster(rows, args.high, args.low)

    groups = defaultdict(list)
    for i in range(len(rows)):
        groups[parent[i]].append(i)
    multi = {k: v for k, v in groups.items() if len(v) > 1}

    data = []
    for gi, (root, ids) in enumerate(sorted(multi.items(), key=lambda kv: (-len(kv[1]), kv[0])), 1):
        ids = sorted(ids, key=lambda i: rows[i][args.id_col])
        inset = set(ids)
        gedges = [e for e in edges if e[0] in inset and e[1] in inset]
        best = max(gedges, key=lambda e: (ORDER.get(e[2], 0), e[3])) if gedges else (0, 0, "未记录", 0)
        rank = ORDER.get(best[2], 0)
        data.append({
            "group": gi,
            "conf": "高" if rank >= 5 else ("中高" if rank >= 3 else "中"),
            "rule": best[2], "score": best[3],
            "items": [{
                "id": rows[i].get(args.id_col, ""),
                "title": rows[i].get(args.title_col, ""),
                "url": rows[i].get(args.url_col, ""),
                "brand": rows[i].get("_brand", ""),
                "orig": rows[i].get("_orig", ""),
                "code": rows[i].get("_code", ""),
                "ver": rows[i].get("_ver", ""),
                "size": rows[i].get("_size", ""),
            } for i in ids],
        })

    io.open(os.path.join(args.out, "rows.json"), "w", encoding="utf-8") \
        .write(json.dumps(rows, ensure_ascii=False, indent=0))
    io.open(os.path.join(args.out, "groups.json"), "w", encoding="utf-8") \
        .write(json.dumps(data, ensure_ascii=False, indent=1))

    n = len(rows)
    dup = sum(len(d["items"]) for d in data)
    print(f"条目 {n} | 重复组 {len(data)} | 涉重 {dup} | 去重后 {n - dup + len(data)}")

    # 立刻把组打印出来供人工逐组复核（这一步不能跳）
    for d in data:
        print(f"\n=== G{d['group']:02d} [{d['conf']}] {d['rule']} ({d['score']}) {len(d['items'])}条")
        for it in d["items"]:
            print(f"  {it['id']} | {(it['orig'] or '-')[:46]} | {(it['brand'] or '-')[:14]}")
            print(f"       {it['title'][:92]}")
    print("\n提示：逐组人工核对后再生成 xlsx；重点看系列不同部分、合集包含关系、版本倒挂、Demo 混入。")


if __name__ == "__main__":
    main()
