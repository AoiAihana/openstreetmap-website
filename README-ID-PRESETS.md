# iD 的 minecraft 元素预设（README-ID-PRESETS.md）

把本项目自定义的 `minecraft:*` 标签整理成 **iD 编辑器里可以点选的「元素预设」**，
按「杂项 / 自然类 / 基建类 / 生产类 / 红石类」五类分组，点 / 线 / 面各自可用。

改完之后，在 iD 里画一个元素 → 打开「要素类型」面板，第一屏就能看到这五个分类磁贴；
下拉框里的选项是中文，也能用中文名 / 英文别名搜索（比如搜「村庄」「village」）。

---

## 0. 一句话原理

iD 的预设不是打包进 JS 的：运行时它会去 **jsDelivr** 取
`@openstreetmap/id-tagging-schema` 的 `dist/presets.min.json` / `fields.min.json` /
`preset_categories.min.json` / `preset_defaults.min.json` /
`dist/translations/<locale>.min.json`。

我们把这份 schema 换成「**iD 基础 schema + 我们的 minecraft 预设**」合并出来的产物，
放在本实例自己的路由上伺服，再用 iD 的 asset map 顶掉原来那几个文件的地址。

```
carto之后的计划.txt ─┐
osm-carto4mc 样式表 ─┴→ config/id_presets_minecraft.yml   ← 唯一手写源（中文注释）
                              │
        jsDelivr 基础 schema ─┤ scripts/build_id_minecraft_presets.rb build
                              ▼
                      config/id_minecraft/*.min.json       ← 构建产物（合并结果）
                              │  IdPresetsController  →  /id/minecraft/data/*.min.json
                              ▼
        app/views/site/id.html.erb  asset_map + data-id-schema-files
                              ▼
        app/assets/javascripts/id.js  把 iD 的 fileMap 改成相对路径
                              ▼
                         浏览器里的 iD
```

---

## 1. 改了哪些文件

| 文件 | 作用 |
|---|---|
| `config/id_presets_minecraft.yml` | **唯一手写源**：字段、五个分类、106 个预设，全中文注释，注明每个键值的出处（计划文档第几行 / 哪个图层） |
| `scripts/build_id_minecraft_presets.rb` | 构建脚本（Ruby，只用标准库）：`fetch` 下基础 schema、`icons` 抽合法图标名、`build` 合并、`verify` 校验 |
| `config/id_minecraft/*.min.json` | **构建产物**（不要手改）：`presets.min.json`、`fields.min.json`、`preset_categories.min.json`、`preset_defaults.min.json`、`translations/*.min.json`、`manifest.json` |
| `lib/id_minecraft_presets.rb` | 把产物映射成「iD fileMap 覆盖表」和「asset map 追加条目」；产物不存在时返回空，页面行为不变 |
| `app/controllers/id_presets_controller.rb` | 伺服产物（白名单校验 + `send_file`，ETag/304 由 Rack 处理） |
| `config/routes.rb` | 加一条 `get "/id/minecraft/*path" => "id_presets#show"` |
| `app/views/site/id.html.erb` | asset map 追加我们的条目 + 输出 `data-id-schema-files`（fileMap 覆盖表） |
| `app/assets/javascripts/id.js` | 在 `init()` 之前把 iD 的 fileMap 里那几个键换成相对路径（**必须做，见第 5 节**） |
| `vendor/id-tagging-schema/` | 基础 schema 的本地缓存 + `icon-names.txt`（合法图标名清单），由 `fetch` / `icons` 生成。**要不要提交进 git 随你**：提交了就不用再联网取基础文件（约 1.6MB），不提交则每次换机器要跑一次 `fetch` |
| `scripts/verify_id_minecraft_presets.sh` | 端到端验证脚本（登录 → 抓 `/id` → 按 iD 的规则解析 URL → 抓产物 → 检查原预设没丢） |

---

## 2. 怎么重新生成

```bash
cd /home/aoiaihana/osm/openstreetmap-website

# ① 基础 schema（**需要外网**；web 容器没有外网，这一步必须在宿主机上跑）
#    版本取自 YAML 里 meta.base_version_range（= iD 的 package.json 里
#    "@openstreetmap/id-tagging-schema" 的 semver 范围），脚本会像 iD 运行时那样
#    先解析成具体版本（当前 6.19.2）再下载。
ruby scripts/build_id_minecraft_presets.rb fetch

# ② 抽合法图标名 + 合并 + 校验（幂等：同样的输入跑多少遍产物都逐字节一样）
#    icons 会先找本地 node_modules，找不到就自动 `docker compose exec web` 进容器读
#    sprite，所以宿主机上一条命令就能跑完。
ruby scripts/build_id_minecraft_presets.rb all

# ③ 让 web 生效
cd /home/aoiaihana/osm
docker compose restart web
```

> **改了 `app/assets/javascripts/id.js` 就必须重编译资源。** 这个容器服务的是
> `public/assets` 里的**预编译**产物（`web/start.sh` 的注释里有解释），改 JS 源文件
> 不会自动生效：
>
> ```bash
> docker compose exec -T web bash -lc 'cd /app && bundle exec rails assets:precompile'
> ```
>
> 只改视图 / 路由 / 控制器 / `config/id_minecraft/` 的话不用重编译，刷新页面即可。

**构建脚本的失败行为**（有意设计成「宁可报错也不出半个残缺的 schema」）：

* 缺 `vendor/id-tagging-schema/presets.min.json` 等基础文件 → 报错并提示先跑 `fetch`；
* 缺 `icon-names.txt` → 报错并打印上面那条抽取命令；
* YAML 里 icon 名不在 sprite 里、tags 为空、geometry 非法、引用了不存在的字段、
  id 与基础 schema 撞车 → 逐条列出后退出（非 0）；
* `verify` 还会确认**基础预设一个都没丢**、分类 members 与预设一一对应、
  语言包里我们的分类名 / 字段名都在。

---

## 3. 怎么验证

```bash
cd /home/aoiaihana/osm/openstreetmap-website
scripts/verify_id_minecraft_presets.sh            # 默认 http://localhost:3000 aoiaihana password
```

脚本会依次检查：

1. 登录后 `/id` 返回 200，页面里有 `id-container`；
2. 页面 `data-asset-map` 里有我们那 8 条覆盖（4 个 schema 文件 + 4 个语言包）；
3. 直接 curl 这些 URL：都是 `200` 且是合法 JSON；
4. `presets.min.json` 里有 `minecraft/structure/village` 等，`fields` 里有 `minecraft_*`，
   `preset_categories` 里有 5 个 `category-minecraft-*`；
5. iD 原有预设没丢：产物 vs `vendor/id-tagging-schema/presets.min.json` 逐 id 比对。

上面这个脚本只 curl HTML/JSON，**看不到 `id.js` 里的接线有没有生效** ——
数据全对、编辑器却整个白屏是可能的（见 5.4）。所以还有第二条，在仓库根的 `tools/`：

```bash
cd /home/aoiaihana/osm
tools/check-id-preset-wiring.sh                    # 接线：asset map + fileMap + 真的执行一遍产物 JS
tools/check-id-presets-vs-carto.py                 # 一致性：预设写出的标签 carto 是否真会画
```

手搓版（不跑脚本）：

```bash
# 产物 URL（不用登录）
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3000/id/minecraft/data/presets.min.json
curl -s http://localhost:3000/id/minecraft/data/presets.min.json | grep -c 'minecraft/structure/village'

# 页面里的 asset map（需要登录，/id 未登录会 302 到 /login）
curl -s -c /tmp/c -L http://localhost:3000/login -o /tmp/l.html
TOKEN=$(grep -o 'name="authenticity_token"[^>]*value="[^"]*"' /tmp/l.html | head -1 | sed 's/.*value="//;s/"//')
curl -s -b /tmp/c -c /tmp/c -o /dev/null -X POST http://localhost:3000/login \
  --data-urlencode "username=aoiaihana" --data-urlencode "password=password" \
  --data-urlencode "authenticity_token=$TOKEN"
curl -s -b /tmp/c http://localhost:3000/id | grep -o 'asset_map\|id-schema-files' | sort -u
```

---

## 4. 预设清单

| 类别（iD 分类 id） | 预设数 | 覆盖的键 |
|---|---|---|
| 杂项 `category-minecraft-misc` | 11 | `minecraft=yes`、`minecraft:addon`、`minecraft:species`、`minecraft:genus`、`minecraft:block`(+spawner)、`minecraft:landuse`×5 |
| 自然类 `category-minecraft-nature` | 24 | `minecraft:ocean`、`minecraft:nature`、`minecraft:structure`×19(+雪屋地下室)、`minecraft:ore_vein`×2 |
| 基建类 `category-minecraft-infrastructure` | 25 | `minecraft:amenity`×11、`minecraft:portal`×5、`minecraft:portal:type`×3、`minecraft:sport`×6 |
| 生产类 `category-minecraft-production` | 35 | `minecraft:industrial`×10、`minecraft:mob_farm`×12、`minecraft:craft`×11、`minecraft:product`、`minecraft:conveyor` |
| 红石类 `category-minecraft-redstone` | 11 | `minecraft:redstone`×7、`minecraft:signal_wired`、`minecraft:cannon`×3 |

合计 **106 个预设 / 21 个自定义字段 / 5 个分类**。
几何分布：点 99、面 103、线 16（一个预设可以同时支持多种几何；线只有
`minecraft:portal`、`minecraft=yes`、`minecraft:addon`、`minecraft:species`、
`minecraft:genus`、`minecraft:nature`、`minecraft:product`、`minecraft:conveyor`、
`minecraft:signal_wired` 这些计划里没限定几何的键能画）。

字段（iD field，选项都是中文）：

| 字段 id | 键 | 类型 | 选项数 |
|---|---|---|---|
| `minecraft_addon` / `minecraft_block` / `minecraft_landuse` / `minecraft_structure` / `minecraft_ore_vein` | 对应 `minecraft:*` | combo | 1 / 3 / 5 / 19 / 2 |
| `minecraft_amenity` / `minecraft_portal` / `minecraft_portal_type` / `minecraft_sport` | 对应 | combo | 11 / 5 / 3 / 6 |
| `minecraft_industrial` / `minecraft_mob_farm` / `minecraft_craft` / `minecraft_redstone` / `minecraft_cannon` | 对应 | combo | 10 / 12 / 11 / 7 / 3 |
| `minecraft_species` / `minecraft_genus` / `minecraft_product` / `minecraft_conveyor` / `minecraft_signal_wired` | 对应 | text | 自由输入 |
| `minecraft_nature` / `minecraft_igloo_underground` | 对应 | check | 勾选框 |

---

## 5. 三个必须知道的坑

### 5.1 光改 asset map 不生效 —— 还得改 iD 的 fileMap

底图 `imagery.min.json` 能靠 asset map 覆盖，是因为它在 iD 的 fileMap 里是
**相对路径**（`data/imagery.min.json`），iD 的 `context.asset()` 会拼成
`<assetPath><path>` 再查 asset map。

但 presets / fields / 分类 / 默认列表 / tagging 翻译在 iD.js 里是
**绝对 CDN URL**（`https://cdn.jsdelivr.net/npm/@openstreetmap/id-tagging-schema@…`），
而 `context.asset()` 的第一行是：

```js
context.asset = (val) => {
  if (/^http(s)?:\/\//i.test(val)) return val;   // ← 绝对 URL 直接返回，不查 asset map
  const filename = _assetPath + val;
  return _assetMap[filename] || filename;
};
```

（`node_modules/@openstreetmap/id/dist/iD.js` 里 `modules/core/file_fetcher.js`
的 `coreFileFetcher().get()` + `context.asset()`，搜 `preset_presets` 就能找到。）

所以 `app/assets/javascripts/id.js` 里先用 `iD.fileFetcher().fileMap()` 把那几个键
换成相对路径，asset map 才开始起作用。**这两步缺一不可。**

### 5.2 分类名 / 字段名 / 选项名只认翻译，没有 JSON 兜底

iD 里 preset 的 `name` / `terms` 有兜底：`preset.name()` 是
`t("name", {default: 原文})`，所以我们在 `presets.min.json` 里写中文名就能直接显示。

但分类和字段不是：

```js
// modules/presets/category.js
_this.name = () => _t(`_tagging.presets.categories.${categoryID}.name`, { default: categoryID });
// modules/presets/field.js
_this.title = () => resolveReference("label").t("label", { default: fieldID });
```

没有翻译时分类磁贴会显示成 `category-minecraft-nature`、字段标题显示成
`minecraft_amenity`、下拉选项显示原始值。所以构建脚本会把我们的文案**合并进**
基础语言包（`vendor/id-tagging-schema/translations/<locale>.min.json` →
`config/id_minecraft/translations/<locale>.min.json`）。是**合并不是替换**：
直接替换会把整门语言的 iD 翻译清空。

需要注入哪几门语言由 YAML 的 `meta.translations` 决定（当前 zh-CN / zh-TW / zh / en）。
其他语言没被覆盖，仍然走 CDN，行为不变；那些语言下预设名依旧是中文（JSON 兜底），
只是字段标题退回原始 id。

### 5.3 图标名只能用 sprite 里真有的 id

iD 把 `preset.icon` 直接当 SVG symbol id 用（`<use href="#"+icon>`），合法名字只有
`sprite id`。**文档和老版本 iD 里那些裸名字（`circle` `water` `tree` `building`
`factory` …）在本版本根本不存在**，写了就是一个空图标。

合法清单 = `vendor/id-tagging-schema/icon-names.txt`（3297 个，从
`dist/img/*-sprite.svg` 抽的）。`build` 会逐个校验，写错直接报错退出。

> 顺带一提：基础 schema 6.19.2 自己就有 **22 个预设**引用了本版本 iD sprite 里没有的
> 图标（例如 `building_part`、`roentgen-sinking_ship`）—— 这是
> `@openstreetmap/id` 2.40 与 `id-tagging-schema` 6.19.2 的版本错位造成的**既有现象**，
> 不是这次改动引入的，`verify` 只会提示一下。

### 5.4 `iD.fileFetcher` 是对象，不是函数（写错了整个编辑器白屏）

这一条是实际踩过的，而且**所有 HTTP 层检查都发现不了**，所以单独列出来。

```js
// ❌ 错：会抛 TypeError: iD.fileFetcher is not a function
const iDFileMap = iD.fileFetcher().fileMap();

// ✅ 对
const iDFileMap = iD.fileFetcher.fileMap();
```

为什么容易写错：同一个 `iD` 命名空间里，`iD.coreContext()` / `iD.utilDetect()` 确实
**要**加括号（它们导出的是函数），但 `fileFetcher` 导出的是 `coreFileFetcher()` 的
**单例对象**（iD.js 里 `export { _mainFileFetcher as fileFetcher }`），
属性访问拿到的就是对象本身。

后果特别隐蔽：这段代码在 `DOMContentLoaded` 回调里、`iD.coreContext()` **之前**，
一抛异常后面的初始化全都不会执行 —— 打开 `/id` 是**一片空白**，控制台只有一条报错。
而 `presets.min.json` 照样 200、asset map 照样正确、`verify_id_minecraft_presets.sh`
照样全绿。

防线是 `tools/check-id-preset-wiring.sh`：它除了静态检查预编译产物里的写法，
还会用 node 把产物**真正执行一遍**（桩一个最小 DOM，跑 `DOMContentLoaded` 回调），
断言 iD 的 `fileMap` 确实被改成了 `data/presets.min.json`、且 `asset()` 解析到
`/id/minecraft/data/presets.min.json`。桩 DOM 下 `init()` 往往还会在更深的地方
抛异常，那是正常的，脚本只断言覆盖代码之前的部分。

---

## 6. 设计取舍

* **几何怎么定的**：计划文档明确写了「可点可面 / 只可用点 / 可用于点线面」的照写；
  没写的按样式表实际支持的图层（`minecraft-areas` 是面、`minecraft-*-points` 是点且
  SQL 用 `ST_PointOnSurface` 把闭合面并了进来、`minecraft-portal-lines` 是线）。
  `minecraft:block` 计划里写明「只可使用点元素」，所以只给 `point`。
* **辅助键 `area=*` / `building=*` 没有塞进 tags**：
  1. 一个 preset 只有一份 tags，却要同时服务点和面。给点元素塞 `area=yes` 没意义，
     塞 `building=yes` 会让 iD 把节点当建筑物。
  2. `area=yes` iD 会**自动补**：preset 的 geometry 含 area、tags 又不隐含面时，
     `preset.setTags()` 会自动加 `area=yes`（`modules/presets/preset.js`）。
     所以「面元素需要加 `area=*`」这条已经被编辑器满足了。
  3. carto4mc 的点图层 UNION 了面中心点，标成面照样出图。
  需要 `building=*` 的结构（mansion、bastion_remnant…），在地图里用 iD 自带的建筑物
  字段补一下即可。**如果你希望这些结构做成「面专用、带 `building=yes`」的独立预设，
  说一声，在 YAML 里加一个 `minecraft/structure/<值>/building` 之类的即可。**
* **`minecraft:portal:type` / `minecraft:cannon` / `minecraft:mob_farm` 把父键一起写死**：
  计划文档写了「必须包含 `minecraft:portal`」「必须添加 `minecraft:redstone=cannon`」，
  而且 carto4mc 的规则（`[minecraft_portal != null][minecraft_portal_type = 'nether']`）
  也要求父键在场，否则不出图。所以这些预设的 `tags` 是两三个键一起写。
* **不渲染的键也做预设**：`minecraft=yes`、`minecraft:addon`、`minecraft:species`、
  `minecraft:genus`、`minecraft:ore_vein`、`minecraft:sport`、`minecraft:product`、
  `minecraft:conveyor`、`minecraft:signal_wired` 计划里写了「不参与 carto4mc 的渲染」，
  但它们仍然可编辑，所以照样做预设，只是在 `terms` 里不暗示会出图。
* **分类会插到预设面板第一屏最前面**（`preset_defaults` 的 `position: before`）。
  这个实例是 Minecraft 专用，优先露出更合理；想改回追加到末尾就把 YAML 里
  `defaults.position` 改成 `after` 重新 build。
* **预设的 `fields` 默认是「`name` + 这个预设自己那个键对应的字段」**，类别的
  `more_fields` 只放进 `more_fields`（iD 的「更多字段」区）。这样打开一个村庄元素时，
  第一眼能看到「Minecraft 生成结构」下拉框（可以顺手换成雪屋），而不会被
  「模组来源 / 物种」这些次要字段占满。想改就优先在 YAML 里给单个预设写 `fields`。
* **`minecraft/industrial/mob_farm`（总类刷怪塔）故意只写 `industrial=mob_farm`**，
  没带 `minecraft:mob_farm`：carto4mc 通用刷怪塔图案的规则是
  `[minecraft_industrial = 'mob_farm'][minecraft_mob_farm = null]`，一旦带上
  `minecraft:mob_farm=yes`（`"*"` 值在 iD 里的落地方式）那条规则就匹配不上了。
* **`minecraft:structure` 没有做「母预设」**：iD 的 preset 必须带具体 tags，
  `minecraft:structure=*` 这种通配只能作为分类存在（就是 `category-minecraft-nature`），
  层级只体现在 id 上（`minecraft/structure/village` 用 `/` 分层）。
* **产物提交进仓库**：`config/id_minecraft/` 是生成物，但故意留在仓库里 ——
  这样 clone 下来不跑构建脚本也能用，而且能对着 diff 看预设改了什么。
  改预设请改 YAML 再 build，**不要手改产物**（下次 build 会被覆盖）。

---

## 7. 升级 `@openstreetmap/id` 之后要注意什么

1. **基础 schema 版本要跟着重取。** iD 运行时是按
   `package.json` 里 `"@openstreetmap/id-tagging-schema"` 的 semver 范围去 CDN 解析具体
   版本的（当前 `^6.13.4` → `6.19.2`）。升级 iD 后如果这个范围变了：
   * 改 `config/id_presets_minecraft.yml` 的 `meta.base_version_range`；
   * `ruby scripts/build_id_minecraft_presets.rb fetch` 重取基础 schema
     （`vendor/id-tagging-schema/base.json` 里记着当前用的具体版本）；
   * `ruby scripts/build_id_minecraft_presets.rb all` 重新合并 + 校验。
   不重取也不会坏，但产物里的**基础预设会停留在旧版本**：iD 升级带来的新预设不会出现。
2. **图标名要重新抽。** sprite 会随 iD 版本增删：
   `ruby scripts/build_id_minecraft_presets.rb icons --sprite-dir <dir>`（或在容器里跑），
   然后 build ——图标被删掉的话 build 会直接报错，按提示换成还在的名字即可。
3. **iD 内部的 fileMap 键名要复核。** 我们的接线依赖
   `preset_presets` / `preset_fields` / `preset_categories` / `preset_defaults` /
   `locale_tagging_<locale>` 这几个键名，它们定义在 iD.js 的
   `modules/core/file_fetcher.js`。升级后如果改了名，`data-id-schema-files` 里的键
   就对不上了（症状：iD 又从 CDN 取 schema，minecraft 预设看不到）。复核命令：
   ```bash
   docker compose exec -T web grep -n 'preset_presets\|locale_tagging\|preset_fields' \
     /app/node_modules/@openstreetmap/id/dist/iD.js | head
   ```
4. **`asset()` 的 http 短路行为**（第 5.1 节）如果哪天改了（比如 iD 开始让 asset map
   覆盖绝对 URL），那 `id.js` 里的 fileMap 覆盖就可以删掉，只留 asset map 即可。
5. 升级后重跑 `scripts/verify_id_minecraft_presets.sh`，确认 8 条覆盖与新产物都还在。

---

## 8. 常用排查

| 现象 | 原因 / 处理 |
|---|---|
| **`/id` 打开一片空白，控制台一条 `TypeError: iD.fileFetcher is not a function`** | `app/assets/javascripts/id.js` 里把 `iD.fileFetcher` 当函数调了（见 5.4）。改回 `iD.fileFetcher.fileMap()` 后必须 `assets:precompile` + 重启 web |
| iD 里看不到那五个分类 | 看浏览器 Network 里有没有请求 `/id/minecraft/data/presets.min.json`。没有 → `id.js` 里的 fileMap 覆盖没生效（多半是改了 JS 没 `assets:precompile`）；有但 404 → 产物没 build |
| 分类磁贴显示成 `category-minecraft-nature` | 语言包没生效：确认 `data-locale` 对应的语言在 `meta.translations` 里，且该语言包已合并（`config/id_minecraft/translations/`） |
| 字段标题显示成 `minecraft_amenity` | 同上 |
| 图标是个空白 | 用的 icon 名不在 sprite 里。`ruby scripts/build_id_minecraft_presets.rb verify` 会报出来 |
| 改了 YAML 但页面没变 | 忘了 `build`；或者改的是 `id.js` 忘了 `assets:precompile`；或者浏览器缓存（产物是 `max-age=0, must-revalidate`，正常刷新即可） |
| 整个编辑器只剩 minecraft 预设了 | 产物的基础部分没合并进去。`verify` 会报「基础预设丢了 N 个」；重新 `all` |
| `/id/minecraft/...` 500 | 看 `docker compose logs web`；多半是 `config/id_minecraft/manifest.json` 坏了（删掉重 build 即可，页面会自动退回 iD 自带行为） |
