#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""关系成员守卫（容器内版）：抓住「成员被静默丢弃」并自动补回。

放在 web 容器里跑（仓库里的 tools/guard-relation-members.py 是同一套逻辑的
宿主机版本），由 web/start.sh 以后台循环启动。

为什么需要
----------
OSM API 对 relation 的更新是**整表替换**：请求体里没列出的成员会被删除。而 iD
有多处会**重建**成员表，且都基于它本地已下载的那部分图（graph）：

  * merge_polygon.js —— osmJoinWays 会 filter 掉非 way 成员与未加载成员（补丁 A）
  * split.js isArea  —— 把 way 成员换成 relation 成员（补丁 B）
  * add_member.js    —— 注释自己写明：
        // `joined` might not contain all of the way members,
        // But will contain only the completed (downloaded) members

实测本实例里 G104 道路关系（relation 117）因此一次掉了 20 条 ref=G104 的 way
（约 9.6 km，其中 14 条变成完全孤儿）；海岸线关系也丢过多次。

判据
----
只看关系的**当前版本** V（与 V-1 比较）。某个成员「被静默丢弃」当：

  1. 它在 V-1 里、不在 V 里；
  2. 它**仍然存在**（没有被删除）；
  3. 它的最新版本 changeset **不是** V 所在的那个 changeset（这次编辑根本没碰它）。

条件 3 是区分点：故意把成员移出关系时，那条 way 通常也不会被改动 —— 所以如果你
确实想永久移除某个成员，把关系 id 放进 GUARD_SKIP（逗号分隔），或先改动那条 way。

用法
----
    python3 guard-relation-members.py --once              # 检查一次
    python3 guard-relation-members.py --apply --once      # 检查并补回
    python3 guard-relation-members.py --apply --interval 30   # 常驻循环
"""
import argparse
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = os.environ.get("GUARD_API", "http://localhost:3000/api/0.6")
PGHOST = os.environ.get("GUARD_PGHOST", "db")
PGUSER = os.environ.get("GUARD_PGUSER", "openstreetmap")
PGDB = os.environ.get("GUARD_PGDB", "openstreetmap")
PGPASSWORD = os.environ.get("GUARD_PGPASSWORD", os.environ.get("API_PASSWORD", "openstreetmap"))
TOKEN_FILE = os.environ.get("GUARD_TOKEN_FILE", "/app/tmp/guard.token")


def log(msg):
    print("[guard] %s" % msg, flush=True)


def psql(sql):
    env = dict(os.environ, PGPASSWORD=PGPASSWORD)
    r = subprocess.run(["psql", "-h", PGHOST, "-U", PGUSER, "-d", PGDB,
                        "-At", "-F", "|", "-c", sql],
                       capture_output=True, text=True, env=env)
    if r.returncode != 0:
        raise RuntimeError("psql 失败：%s" % r.stderr.strip()[:300])
    return [l.split("|") for l in r.stdout.splitlines() if l]


SQL = """
WITH v AS (
    SELECT relation_id, version,
           array_agg(member_type || ':' || member_id ORDER BY member_type, member_id) AS mem,
           array_agg(member_type || ':' || member_id || ':' || coalesce(member_role, '')
                     ORDER BY member_type, member_id) AS mem_role
      FROM relation_members GROUP BY relation_id, version
), d AS (
    SELECT relation_id, version, mem, mem_role,
           lag(mem)      OVER (PARTITION BY relation_id ORDER BY version) AS prev,
           lag(mem_role) OVER (PARTITION BY relation_id ORDER BY version) AS prev_role
      FROM v
)
SELECT d.relation_id, d.version, r.changeset_id,
       coalesce(array_to_string(ARRAY(SELECT unnest(d.prev) EXCEPT SELECT unnest(d.mem)), ' '), ''),
       coalesce(array_to_string(d.mem_role, ' '), ''),
       coalesce(array_to_string(d.prev_role, ' '), '')
  FROM d JOIN relations r ON r.relation_id = d.relation_id AND r.version = d.version
 WHERE d.prev IS NOT NULL
   AND coalesce(array_length(d.mem, 1), 0) < coalesce(array_length(d.prev, 1), 0)
   -- 只处理当前版本：更早版本的丢弃已被后续版本取代，补回去是错的
   AND d.version = (SELECT max(version) FROM relations r2 WHERE r2.relation_id = d.relation_id)
   AND EXISTS (SELECT 1 FROM current_relations cr WHERE cr.id = d.relation_id)
 ORDER BY d.relation_id
"""

EXISTS_SQL = {
    "node": "SELECT id, (SELECT max(changeset_id) FROM nodes n2 WHERE n2.node_id = n.id) "
            "FROM current_nodes n WHERE id IN (%s)",
    "way": "SELECT id, (SELECT max(changeset_id) FROM ways w2 WHERE w2.way_id = w.id) "
           "FROM current_ways w WHERE id IN (%s)",
    "relation": "SELECT id, (SELECT max(changeset_id) FROM relations r2 WHERE r2.relation_id = r.id) "
                "FROM current_relations r WHERE id IN (%s)",
}


def token():
    with open(TOKEN_FILE, encoding="utf-8") as f:
        return f.read().strip()


def api(method, path, tok, data=None, ctype="application/xml", timeout=120):
    req = urllib.request.Request(API + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + tok)
    if data is not None:
        req.add_header("Content-Type", ctype)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:                       # noqa: BLE001 - 网络问题不该让循环挂掉
        return 0, str(e)


def find_suspicious():
    """返回 [(rid, ver, cs, key, role, last_cs), ...]"""
    rows = psql(SQL)
    if not rows:
        return []

    alive = {}
    for r in rows:
        for tok_ in r[3].split():
            t, mid = tok_.split(":")
            alive.setdefault((t.lower(), int(mid)), None)

    by_type = {}
    for (t, mid) in alive:
        by_type.setdefault(t, []).append(mid)
    for t, ids in by_type.items():
        ids = sorted(set(ids))
        for chunk in [ids[i:i + 500] for i in range(0, len(ids), 500)]:
            for mid, last_cs in psql(EXISTS_SQL[t] % ",".join(str(x) for x in chunk)):
                alive[(t, int(mid))] = int(last_cs)

    out = []
    for rid, ver, cs, dropped, cur_roles, prev_roles in rows:
        rid, ver, cs = int(rid), int(ver), int(cs)
        prev = {}
        for item in prev_roles.split():
            t, mid, role = item.split(":", 2)
            prev[(t.lower(), int(mid))] = role
        cur = set()
        for item in cur_roles.split():
            t, mid = item.split(":", 2)[:2]
            cur.add((t.lower(), int(mid)))
        for tok_ in dropped.split():
            t, mid = tok_.split(":")
            key = (t.lower(), int(mid))
            if key in cur:
                continue
            last_cs = alive.get(key)
            if last_cs is None or last_cs == cs:
                continue
            out.append((rid, ver, cs, key, prev.get(key, ""), last_cs))
    return out


def repair(rid, items, tok):
    st, rx = api("GET", "/relation/%d" % rid, tok)
    if st != 200:
        log("r%d 读取失败 HTTP %s：%s" % (rid, st, rx[:120]))
        return False
    ver = int(re.search(r'<relation\b[^>]*\bversion="(\d+)"', rx).group(1))
    tags = re.findall(r'<tag\s+k="([^"]*)"\s+v="([^"]*)"', rx)
    cur = re.findall(r'<member\s+type="(\w+)"\s+ref="(\d+)"\s+role="([^"]*)"', rx)
    have = {(t.lower(), int(r)) for t, r, _ in cur}
    add = [s for s in items if s[3] not in have]
    if not add:
        return True

    st, cs = api("PUT", "/changeset/create", tok,
                 ('<osm><changeset>'
                  '<tag k="comment" v="osm-carto4mc: 守卫自动补回被静默丢弃的关系成员（r%d，%d 个）"/>'
                  '<tag k="created_by" v="osm-carto4mc-guard"/></changeset></osm>'
                  % (rid, len(add))).encode())
    if st != 200:
        log("r%d 建 changeset 失败 HTTP %s" % (rid, st))
        return False
    cs = cs.strip()
    mem = "".join('  <member type="%s" ref="%s" role="%s"/>\n' % (t, r, role or "")
                  for t, r, role in cur)
    mem += "".join('  <member type="%s" ref="%d" role="%s"/>\n' % (s[3][0], s[3][1], s[4] or "")
                   for s in add)
    body = ('<osm><relation id="%d" version="%d" changeset="%s">\n%s%s</relation></osm>'
            % (rid, ver, cs, mem,
               "".join('  <tag k="%s" v="%s"/>\n' % (k, v) for k, v in tags)))
    st, resp = api("PUT", "/relation/%d" % rid, tok, body.encode())
    api("PUT", "/changeset/%s/close" % cs, tok)
    if st == 200 and "<remark" not in resp:
        log("r%d 补回 %d 个成员（changeset %s）：%s" % (
            rid, len(add), cs, ", ".join("%s %d" % (s[3][0], s[3][1]) for s in add)))
        return True
    log("r%d 补回失败 HTTP %s：%s" % (rid, st, resp[:200]))
    return False


def one_pass(apply_fix, skip):
    try:
        sus = find_suspicious()
    except Exception as e:                       # noqa: BLE001
        log("检查失败：%s" % e)
        return
    sus = [s for s in sus if s[0] not in skip]
    if not sus:
        return
    for s in sus:
        log("发现静默丢弃：r%d v%d（changeset %d）成员 %s %d 仍存在（最后改动 cs%d），角色 %s"
            % (s[0], s[1], s[2], s[3][0], s[3][1], s[5], s[4] or "(空)"))
    if not apply_fix:
        return
    try:
        tok = token()
    except OSError:
        log("读不到令牌 %s，跳过补回" % TOKEN_FILE)
        return
    by_rel = {}
    for s in sus:
        by_rel.setdefault(s[0], []).append(s)
    for rid, items in sorted(by_rel.items()):
        repair(rid, items, tok)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="自动补回（默认只报告）")
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--interval", type=int, default=30)
    ap.add_argument("--skip", default=os.environ.get("GUARD_SKIP", ""),
                    help="逗号分隔的关系 id，永不自动补回")
    a = ap.parse_args()

    skip = {int(x) for x in a.skip.split(",") if x.strip().isdigit()}
    log("启动：apply=%s interval=%ss skip=%s" % (a.apply, a.interval, sorted(skip) or "无"))
    while True:
        # 常驻模式下先睡一轮：web/start.sh 是紧接在启动守卫之后 exec rails s 的，
        # 立刻检查会打不到还没起来的 API。
        if not a.once:
            time.sleep(max(5, a.interval))
        one_pass(a.apply, skip)
        if a.once:
            return 0


if __name__ == "__main__":
    sys.exit(main())
