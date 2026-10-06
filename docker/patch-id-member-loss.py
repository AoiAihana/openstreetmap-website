#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给 vendored 的 iD 打补丁：不再静默丢弃 / 替换关系里的 way 成员。

两处缺陷（都在 iD 2.40.0）
--------------------------
**A. 合并多边形会丢掉「非 way 成员」和「未加载成员」**

modules/actions/merge_polygon.js 的 actionMergePolygon 会**重建**成员表：

    var polygons = entities.multipolygon.reduce(function (polygons, m) {
        return polygons.concat(osmJoinWays(m.members, graph));
    }, [])...
    ...
    return graph.replace(relation.update({ members: members, ... }));

而 osmJoinWays（modules/osm/multipolygon.js）开头就写明：

    // Incomplete members (those for which `graph.hasEntity(element.id)` returns
    // false) and non-way members are ignored.
    toJoin = toJoin.filter(function (m) {
        return m.type === 'way' && graph.hasEntity(m.id);
    });

→ 非 way 成员（node / 子 relation）与没加载进 graph 的成员被丢掉，然后整表
替换写回去 —— 对 OSM API 而言等于永久删除。

**B. 切割「自身是面的 way」时，会把 way 成员换成 relation 成员**

modules/actions/split.js 里 `isArea`（way 自身闭合且带面标签）走单独分支：

    const multipolygon = new osmRelation({ members: [wayA, wayB] });   // 新建关系
    for (const relation of graph.parentRelations(wayA)) {
        graph = graph.replace(relation.replaceMember(wayA, multipolygon));  // way → relation
    }

于是原来那个关系里的 **way 成员**被换成了一个 **relation 成员**。而
osmJoinWays 只认 `type === 'way'`，这个 relation 成员在下一次合并/重建时就被
丢弃 —— 表现为「切割线之后线丢关系，重新加回去还是会丢」。

补丁
----
A. 回写成员表之前，把被 osmJoinWays 忽略的原成员补回去（**只增不减**）。
B. `isArea` 分支对父关系改用 splitWayMember()：wayA 保留、wayB 作为 **way**
   成员按顺序插入 —— 与 iD 处理路线（route）时的做法一致，成员永远是 way。

两处都只做「保留/只增」，不会引入新的数据损失。

用法
----
    python3 docker/patch-id-member-loss.py node_modules/@openstreetmap/id/dist/iD.js --dry-run
    python3 docker/patch-id-member-loss.py node_modules/@openstreetmap/id/dist/iD.js
"""
import argparse
import re
import sys

MARK_A = "/* osm-carto4mc: keep members dropped by osmJoinWays */"
MARK_B = "/* osm-carto4mc: keep split halves as way members */"

PATCH_A_ANCHOR = re.compile(
    r"(?P<indent>[ \t]*)return graph\.replace\(relation\.update\(\{\s*\n"
    r"[ \t]*members,\s*\n"
    r"[ \t]*tags: utilObjectOmit\(relation\.tags, \[\"area\"\]\)\s*\n"
    r"[ \t]*\}\)\);\s*\n"
)

PATCH_A = """{indent}// 被 osmJoinWays 过滤掉的原成员必须补回来，否则整表替换会永久删掉它们：
{indent}// 它只保留 `type === 'way'` 且已加载进 graph 的成员，非 way 成员与未加载成员
{indent}// 都会被丢弃。这里只做「补回」，不做删除，所以不会引入新的数据损失。
{indent}(function () {{
{indent}  const seen = new Set();
{indent}  members.forEach(function (m) {{ seen.add(m.type + ':' + m.id); }});
{indent}  entities.multipolygon.forEach(function (mp) {{
{indent}    (mp.members || []).forEach(function (om) {{
{indent}      const key = om.type + ':' + om.id;
{indent}      if (!seen.has(key)) {{
{indent}        seen.add(key);
{indent}        members.push({{ type: om.type, id: om.id, role: om.role }});
{indent}      }}
{indent}    }});
{indent}  }});
{indent}}})();
{indent}{mark}
{indent}return graph.replace(relation.update({{
{indent}  members,
{indent}  tags: utilObjectOmit(relation.tags, ["area"])
{indent}}}));
"""

# split.js：把「wayA 换成新建的 multipolygon」改成「wayB 也作为 way 成员插进父关系」
PATCH_B_ANCHOR = re.compile(
    r"(?P<indent>[ \t]*)graph = graph\.replace\(relation\.replaceMember\(wayA, multipolygon\)\);\s*\n"
)

PATCH_B = """{indent}{mark}
{indent}// 父关系里的 wayA 必须仍是 **way** 成员：改成把 wayB 也作为 way 插入，
{indent}// 而不是把 wayA 换成一个新建的 relation 成员 —— 后者会被 osmJoinWays
{indent}// 过滤掉，于是切割之后成员就"丢"了，重新加回去也会再丢一次。
{indent}graph = splitWayMember(graph, relation.id, wayA, wayB);
"""


def apply_patch(src, name, anchor, mark, template, dry):
    if mark in src:
        print(f"  {name}: 已打过")
        return src, False
    hits = list(anchor.finditer(src))
    if len(hits) != 1:
        sys.exit(f"  {name}: 锚点匹配到 {len(hits)} 处（应为 1 处）—— iD 版本可能变了，"
                 f"请人工核对后再打补丁")
    m = hits[0]
    line = src[:m.start()].count("\n") + 1
    print(f"  {name}: 锚点在第 {line} 行")
    if dry:
        print("    --- 将被替换 ---")
        for l in m.group(0).rstrip().split("\n"):
            print("    " + l)
        print("    --- 替换为 ---")
        for l in template.format(indent=m.group("indent"), mark=mark).rstrip().split("\n"):
            print("    " + l)
    return src[:m.start()] + template.format(indent=m.group("indent"), mark=mark) + src[m.end():], True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bundle")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    with open(a.bundle, encoding="utf-8") as f:
        src = f.read()

    print(f"{a.bundle}")
    src, ch_a = apply_patch(src, "A 合并多边形保留被忽略的成员",
                            PATCH_A_ANCHOR, MARK_A, PATCH_A, a.dry_run)
    src, ch_b = apply_patch(src, "B 切割时把两半都留成 way 成员",
                            PATCH_B_ANCHOR, MARK_B, PATCH_B, a.dry_run)

    if a.dry_run:
        print("\n（干运行，未写入）")
        return 0
    if not (ch_a or ch_b):
        print("两处补丁都已存在，无需处理")
        print("PATCHED=0")
        return 0

    with open(a.bundle, "w", encoding="utf-8") as f:
        f.write(src)
    print(f"已写入 {a.bundle}")
    print("注意：这是 Sprockets 编译进 id.js 的资源，还需要重建前端资源、重启 web，"
          "并且**在浏览器里硬刷新 iD 页面**才生效。")
    print("PATCHED=1")
    return 0


if __name__ == "__main__":
    sys.exit(main())
