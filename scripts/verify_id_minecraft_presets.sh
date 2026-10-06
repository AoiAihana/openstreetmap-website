#!/bin/bash
#
# 端到端验证：iD 编辑器是否真的用上了我们合并出来的 minecraft 预设。
#
# 用法：
#   scripts/verify_id_minecraft_presets.sh [基地址] [用户名] [密码]
# 默认：http://localhost:3000 aoiaihana password
#
# 为什么要登录：/id 只有登录用户能看（未登录会 302 到 /login），
# 所以必须先拿一个带会话的 cookie 再抓页面。
#
# 检查项：
#   1. /id 页面里 data-asset-map 和 data-id-schema-files 都在；
#   2. **把 iD 自己的解析规则重放一遍**：fileMap 的相对路径 + iD 的 assetPath
#      "@openstreetmap/id/dist/" 拼成 asset map 的键，取出来的 URL 必须是
#      200 + 合法 JSON。这就是浏览器里 iD 真正会走的那条路
#      （modules/core/file_fetcher.js 的 context.asset() + _this.get()）；
#   3. 我们的预设 / 字段 / 分类在产物里；
#   4. iD 原有预设一个没丢（逐 id 和 vendor 里的基础文件比对）；
#   5. 语言包（zh-CN）里有我们的分类名 / 字段名 / 选项名。
#
# 注：这台机器上没有无头浏览器，所以第 2 步是「按 iD 的规则重放」而不是真的开浏览器；
#     规则来自 iD.js 源码，字符串拼接与查表顺序和源码逐字一致。
#
set -u

WEBSITE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$WEBSITE_ROOT" || exit 2

BASE="${1:-http://localhost:3000}"
USER_NAME="${2:-aoiaihana}"
PASSWORD="${3:-password}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
JAR="$TMP/cookies.txt"

fail=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; }

echo "== 1) 登录 $USER_NAME@$BASE 并抓 /id =="
curl -s -c "$JAR" -L "$BASE/login" -o "$TMP/login.html"
TOKEN="$(grep -o 'name="authenticity_token"[^>]*value="[^"]*"' "$TMP/login.html" | head -1 | sed 's/.*value="//;s/"//')"
[ -n "$TOKEN" ] || { echo "取不到 authenticity_token，无法登录"; exit 2; }
curl -s -b "$JAR" -c "$JAR" -o /dev/null -w '  login POST -> %{http_code}\n' -X POST "$BASE/login" \
  --data-urlencode "username=$USER_NAME" \
  --data-urlencode "password=$PASSWORD" \
  --data-urlencode "authenticity_token=$TOKEN" \
  --data-urlencode "referer=/id"
CODE="$(curl -s -b "$JAR" -o "$TMP/id.html" -w '%{http_code}' "$BASE/id")"
if [ "$CODE" = "200" ] && grep -q 'id-container' "$TMP/id.html"; then
  ok "/id 200 且页面里有 id-container（$(wc -c <"$TMP/id.html") 字节）"
else
  bad "/id 返回 $CODE，登录可能失败"
  exit 1
fi

python3 - "$TMP/id.html" "$TMP/asset_map.json" "$TMP/schema_files.json" <<'PY'
import html, re, sys
page = open(sys.argv[1], encoding="utf-8").read()
def pick(name):
    m = re.search(r'data-%s="([^"]*)"' % name, page)
    return html.unescape(m.group(1)) if m else None
am, sf = pick("asset-map"), pick("id-schema-files")
if am is None or sf is None:
    sys.exit("页面里缺少 data-asset-map 或 data-id-schema-files")
open(sys.argv[2], "w", encoding="utf-8").write(am)
open(sys.argv[3], "w", encoding="utf-8").write(sf)
PY
[ $? -eq 0 ] || { bad "页面里缺少 asset map / schema files"; exit 1; }
ok "页面含 data-asset-map 与 data-id-schema-files"

echo "== 2) 重放 iD 的解析规则（fileMap 相对路径 -> assetPath+assetMap -> URL），逐个抓 =="
python3 - "$TMP/asset_map.json" "$TMP/schema_files.json" > "$TMP/resolved.txt" <<'PY'
import json, sys
asset_map = json.load(open(sys.argv[1]))
file_map = json.load(open(sys.argv[2]))
# iD：context.assetPath("@openstreetmap/id/dist/")；
#     context.asset(val) = /^https?:/.test(val) ? val : (assetMap[assetPath + val] || assetPath + val)
ASSET_PATH = "@openstreetmap/id/dist/"
for key, rel in file_map.items():
    print(key, asset_map.get(ASSET_PATH + rel, ASSET_PATH + rel), sep="\t")
PY
if [ ! -s "$TMP/resolved.txt" ]; then bad "data-id-schema-files 是空的（iD 会退回 CDN）"; exit 1; fi
while IFS=$'\t' read -r key url; do
  case "$url" in http*) full="$url";; *) full="$BASE$url";; esac
  out="$TMP/$key.json"
  hc="$(curl -s -o "$out" -w '%{http_code}' "$full")"
  if [ "$hc" = "200" ] && python3 -c "import json;json.load(open('$out'))" 2>/dev/null; then
    ok "$key -> $url（200，合法 JSON，$(wc -c <"$out") 字节）"
  else
    bad "$key -> $url（HTTP $hc 或不是合法 JSON）"
  fi
done < "$TMP/resolved.txt"

echo "== 3) 我们的预设 / 字段 / 分类在不在产物里 =="
if python3 - "$TMP/preset_presets.json" "$TMP/preset_fields.json" "$TMP/preset_categories.json" <<'PY'
import json, sys
presets = json.load(open(sys.argv[1]))
fields = json.load(open(sys.argv[2]))
cats = json.load(open(sys.argv[3]))
mine = [k for k in presets if k.startswith("minecraft/")]
print("  minecraft 预设 %d 个；%s 命中 %d 次" % (
    len(mine), "minecraft/structure/village",
    json.dumps(presets).count("minecraft/structure/village")))
need = ["minecraft/structure/village", "minecraft/amenity/enchanting",
        "minecraft/industrial/furnace", "minecraft/redstone/music",
        "minecraft/ocean/yes", "minecraft/portal/type/nether"]
miss = [p for p in need if p not in presets]
for p in need:
    print(("  ✓ " if p in presets else "  ✗ 缺 ") + p)
mf = sorted(k for k in fields if k.startswith("minecraft_"))
print("  minecraft 字段 %d 个：%s" % (len(mf), ", ".join(mf)))
mc = sorted(k for k in cats if k.startswith("category-minecraft-"))
print("  minecraft 分类 %d 个：%s" % (len(mc), ", ".join(mc)))
sys.exit(1 if (miss or not mf or len(mc) != 5) else 0)
PY
then ok "预设 id / 字段 / 分类都在"; else bad "产物里缺我们的预设"; fi

echo "== 4) iD 原有预设有没有丢 =="
if python3 - "$TMP/preset_presets.json" "$TMP/preset_fields.json" "$TMP/preset_categories.json" <<'PY'
import json, sys
presets = json.load(open(sys.argv[1]))
fields = json.load(open(sys.argv[2]))
cats = json.load(open(sys.argv[3]))
base_p = json.load(open("vendor/id-tagging-schema/presets.min.json"))
base_f = json.load(open("vendor/id-tagging-schema/fields.min.json"))
base_c = json.load(open("vendor/id-tagging-schema/preset_categories.min.json"))
missing = [k for k in base_p if k not in presets]
print("  基础预设 %d 个，丢失 %d 个 %s" % (len(base_p), len(missing), missing[:5]))
for pid in ["amenity/cafe", "highway/residential", "natural/water", "building"]:
    print(("  ✓ 仍在 " if pid in presets else "  ✗ 丢了 ") + pid)
mf = [k for k in base_f if k not in fields]
mc = [k for k in base_c if k not in cats]
print("  基础字段丢失 %d 个，基础分类丢失 %d 个" % (len(mf), len(mc)))
sys.exit(1 if (missing or mf or mc) else 0)
PY
then ok "原有预设 / 字段 / 分类全部保留"; else bad "原有预设丢了"; fi

echo "== 5) 语言包（zh-CN）里有我们的分类名 / 字段名 / 选项名 =="
if python3 - "$TMP/locale_tagging_zh-CN.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))["zh-CN"]["presets"]
cat, fld = data["categories"], data["fields"]
need = ["category-minecraft-misc", "category-minecraft-nature", "category-minecraft-infrastructure",
        "category-minecraft-production", "category-minecraft-redstone"]
bad = 0
for cid in need:
    name = cat.get(cid, {}).get("name")
    print(("  ✓ " if name else "  ✗ 缺 ") + cid + " -> " + str(name))
    bad += 0 if name else 1
lbl = fld.get("minecraft_structure", {})
print(("  ✓ " if lbl.get("label") else "  ✗ 缺 ") + "字段 minecraft_structure.label -> " + str(lbl.get("label")))
opt = (lbl.get("options") or {}).get("village")
print(("  ✓ " if opt else "  ✗ 缺 ") + "选项 minecraft_structure.options.village -> " + str(opt))
sys.exit(1 if (bad or not lbl.get("label") or not opt) else 0)
PY
then ok "中文分类名 / 字段名 / 选项名都在"; else bad "语言包缺我们的文案"; fi

echo
if [ "$fail" = 0 ]; then echo "全部通过"; else echo "有检查未通过"; fi
exit "$fail"
