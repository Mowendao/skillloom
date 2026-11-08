# -*- coding: utf-8 -*-
"""由 dedupe.py 产出的 rows.json / groups.json 生成五表 xlsx 判定表。

用法:
  python make_xlsx.py --rows work/rows.json --groups work/groups.json \
      --out 2026-11-08_收藏夹_去重判定_v1.xlsx \
      --source-url "https://example.com/collection/xxx" \
      --input-file "输入.csv" --manual work/manual_groups.json

五表:
  重复组汇总 / 重复组明细 / 全量明细 / 拿不准与待核 / 说明
"""
import argparse, io, json, re
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

HEAD_FILL = PatternFill("solid", fgColor="1F4E79")
HEAD_FONT = Font(color="FFFFFF", bold=True, size=10)
BODY = Font(size=10)
F_DUP = PatternFill("solid", fgColor="FCE4D6")
THIN = Side(style="thin", color="BFBFBF")
BD = Border(left=THIN, right=THIN, top=THIN, bottom=THIN)


def sheet(ws, headers, data, widths, tint=None):
    ws.append(headers)
    for c in range(1, len(headers) + 1):
        cell = ws.cell(1, c)
        cell.fill = HEAD_FILL
        cell.font = HEAD_FONT
        cell.alignment = Alignment("center", "center", wrap_text=True)
        cell.border = BD
    for r in data:
        ws.append(r)
        i = ws.max_row
        for c in range(1, len(headers) + 1):
            cell = ws.cell(i, c)
            cell.font = BODY
            cell.alignment = Alignment(vertical="top", wrap_text=True)
            cell.border = BD
            if tint and tint(r):
                cell.fill = F_DUP
    for k, w in enumerate(widths, 1):
        ws.column_dimensions[get_column_letter(k)].width = w
    ws.freeze_panes = "A2"
    ws.auto_filter.ref = "A1:%s%d" % (get_column_letter(len(headers)), ws.max_row)
    ws.row_dimensions[1].height = 32


def vtup(v):
    return tuple(int(x) for x in (v or "").split(".") if x.isdigit())


def keep_index(items):
    """保留：版本最高 > id 最大。"""
    return max(range(len(items)),
               key=lambda i: (vtup(items[i].get("ver")), int(re.sub(r"\D", "", str(items[i]["id"])) or 0)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", required=True)
    ap.add_argument("--groups", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--source-url", default="")
    ap.add_argument("--input-file", default="")
    ap.add_argument("--manual", default="", help="人工补充组的 json 数组，可直接 append 进 groups")
    ap.add_argument("--pending", default="", help="待核说明 json（类别/条目/问题/理由/核实方式 五元组数组）")
    args = ap.parse_args()

    rows = json.load(io.open(args.rows, encoding="utf-8"))
    groups = json.load(io.open(args.groups, encoding="utf-8"))
    if args.manual:
        for g in json.load(io.open(args.manual, encoding="utf-8")):
            g["group"] = len(groups) + 1
            groups.append(g)

    id2group, wb = {}, Workbook()

    # ---------- 1 重复组汇总 ----------
    ws1 = wb.active
    ws1.title = "重复组汇总"
    D1 = []
    for g in groups:
        ki = keep_index(g["items"])
        keep = g["items"][ki]
        for it in g["items"]:
            id2group[str(it["id"])] = g["group"]
        brief = [("★" if j == ki else "　") + str(it["id"]) + "｜" + (it.get("orig") or it["title"])[:34]
                 for j, it in enumerate(g["items"])]
        act = f"保留 {keep['id']}，其余 {len(g['items']) - 1} 条可删"
        if g.get("conf") != "高":
            act = "先核对再删：" + act
        D1.append([f"G{g['group']:02d}", g.get("conf", ""), g.get("rule", ""), g.get("score", ""),
                   len(g["items"]), keep["id"], " ／ ".join(brief), act])
    sheet(ws1, ["组号", "置信度", "判定依据", "相似度", "条目数", "建议保留 id",
                "组内条目（★=建议保留）", "处理建议"],
          D1, [8, 8, 30, 8, 8, 12, 86, 34])

    # ---------- 2 重复组明细 ----------
    ws2 = wb.create_sheet("重复组明细")
    D2 = []
    for g in groups:
        ki = keep_index(g["items"])
        for j, it in enumerate(g["items"]):
            D2.append([f"G{g['group']:02d}", g.get("conf", ""), "保留" if j == ki else "候选删除",
                       it["id"], it["title"], it.get("brand") or "", it.get("orig") or "",
                       it.get("code") or "", it.get("ver") or "", it.get("size") or "", it.get("url") or ""])
    sheet(ws2, ["组号", "置信度", "建议动作", "条目id", "标题", "社团", "原名／日文名",
                "编号", "版本", "容量", "URL"],
          D2, [8, 8, 20, 10, 62, 16, 40, 13, 8, 9, 40])

    # ---------- 3 全量明细 ----------
    ws3 = wb.create_sheet("全量明细")
    D3 = []
    for r in rows:
        gid = id2group.get(str(r.get("id")))
        D3.append([f"G{gid:02d}" if gid else "—", r.get("id"), r.get("title"),
                   r.get("_brand") or "", r.get("_orig") or "", r.get("_code") or "",
                   r.get("_ver") or "", r.get("_size") or "", r.get("url") or ""])
    sheet(ws3, ["组号", "条目id", "标题", "社团", "原名／日文名", "编号", "版本", "容量", "URL"],
          D3, [8, 10, 74, 18, 44, 13, 8, 9, 42],
          tint=lambda row: row[0] != "—")

    # ---------- 4 拿不准与待核 ----------
    ws4 = wb.create_sheet("拿不准与待核")
    D4 = json.load(io.open(args.pending, encoding="utf-8")) if args.pending else []
    sheet(ws4, ["类别", "条目／组", "问题", "为什么拿不准", "建议核实方式"],
          D4, [14, 24, 30, 66, 40])

    # ---------- 5 说明 ----------
    ws5 = wb.create_sheet("说明")
    n = len(rows)
    dup = sum(len(g["items"]) for g in groups)
    nojp = sum(1 for r in rows if not r.get("_k_jp"))
    nocode = sum(1 for r in rows if not r.get("_code"))
    D5 = [
        ["数据来源", args.source_url],
        ["原始文件", args.input_file],
        ["条目总数", f"{n} 条"],
        ["重复组", f"{len(groups)} 组，涉及 {dup} 条"],
        ["去重后数量", f"{n - dup + len(groups)} 款"],
        ["", ""],
        ["判定主键", "① 厂商编号　② 日文原名　③ 中文名 + 社团名"],
        ["缺键情况", f"无日文原名 {nojp} 条；无厂商编号 {nocode} 条"],
        ["模糊匹配", "三元组阻塞 + 序列相似度；≥0.90 判同款，0.80~0.90 与「一方包含另一方」列为候选并人工复核"],
        ["视为同款的差异", "生肉/汉化/AI汉化/官中/步兵等版本差异；PC/安卓/模拟器等平台差异；同一作品的版本号差异"],
        ["不作为依据", "容量、评论数、更新时间、封面图（转载方可变字段）"],
        ["保留建议规则", "版本号最高优先，同版本取 id 较大者。仅为默认建议，可按「是否汉化/官中」自行调整"],
        ["", ""],
        ["已知局限", "① 合集帖内含作品未展开；② 缺日文原名/编号的条目只能靠中文标题匹配；③ 未打开详情页核对实际版本"],
        ["生成时间", ""],
    ]
    sheet(ws5, ["项目", "内容"], D5, [22, 112])

    wb.save(args.out)
    print("saved:", args.out)
    print(f"重复组 {len(groups)} | 涉重 {dup} | 去重后 {n - dup + len(groups)}")


if __name__ == "__main__":
    main()
