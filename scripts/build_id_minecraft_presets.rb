#!/usr/bin/env ruby
# frozen_string_literal: true
#
# 把 config/id_presets_minecraft.yml（我们自己写的 minecraft:* 元素预设）合并进
# iD 用的 id-tagging-schema，生成 iD 能直接吃的产物。
#
# 为什么需要「合并」而不是「替换」：iD 的 presets.min.json 里是**全部**要素预设
# （1700+ 个），我们只加 100 来个 minecraft 的。直接拿我们的文件顶掉它，整个编辑器
# 就只剩 minecraft 了。所以本脚本先加载基础 schema，再把我们的追加进去。
#
# 产物写到 config/id_minecraft/，由 IdPresetsController 在 /id/minecraft/* 上伺服，
# 最后通过 app/views/site/id.html.erb 的 asset map 顶掉 iD 默认去 jsDelivr 取的那几个
# 文件。详见 README-ID-PRESETS.md。
#
# 子命令：
#   fetch    从 jsDelivr 下载基础 schema（**需要外网**：宿主机有网、web 容器没有，
#            所以这一步在宿主机上跑）
#   icons    从 iD 的 dist/img/*-sprite.svg 抽出合法图标名（校验 icon 用）
#   build    合并 -> config/id_minecraft/
#   verify   校验产物（JSON 合法、无重复 id、tags 非空、icon/几何合法、基础预设没丢）
#   all      = icons + build + verify（不含 fetch）
#
# 例：
#   scripts/build_id_minecraft_presets.rb fetch
#   scripts/build_id_minecraft_presets.rb all
#
require "json"
require "yaml"
require "set"
require "time"
require "fileutils"
require "digest"
require "net/http"
require "uri"
require "optparse"

WEBSITE_ROOT = File.expand_path("..", __dir__)
SOURCE_YAML  = File.join(WEBSITE_ROOT, "config", "id_presets_minecraft.yml")
VENDOR_DIR   = File.join(WEBSITE_ROOT, "vendor", "id-tagging-schema")
OUTPUT_DIR   = File.join(WEBSITE_ROOT, "config", "id_minecraft")

BASE_FILES  = %w[presets fields preset_categories preset_defaults].freeze
ICON_FILE   = File.join(VENDOR_DIR, "icon-names.txt")
BASE_META   = File.join(VENDOR_DIR, "base.json")
CDN_TMPL    = "https://cdn.jsdelivr.net/npm/@openstreetmap/id-tagging-schema@%s/"

# iD 里 fileMap 的逻辑键 -> 产物文件名。这几个键在 iD.js 的
# modules/core/file_fetcher.js（coreFileFetcher）里定义，值本来是
# https://cdn.jsdelivr.net/npm/@openstreetmap/id-tagging-schema@{presets_version}/dist/xxx.min.json
FILE_MAP = {
  "preset_presets"    => "presets.min.json",
  "preset_fields"     => "fields.min.json",
  "preset_categories" => "preset_categories.min.json",
  "preset_defaults"   => "preset_defaults.min.json"
}.freeze

GEOMETRIES = %w[point vertex line area relation].freeze

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
def die(msg)
  warn "错误：#{msg}"
  exit 1
end

def info(msg) = puts("  #{msg}")

def read_json(path)
  JSON.parse(File.read(path))
rescue Errno::ENOENT
  die("#{path} 不存在。先跑 `scripts/build_id_minecraft_presets.rb fetch`（需要外网）。")
rescue JSON::ParserError => e
  die("#{path} 不是合法 JSON：#{e.message}")
end

def write_json(path, data)
  FileUtils.mkdir_p(File.dirname(path))
  # JSON.generate 不排序会随 Hash 插入顺序变化，导致产物 diff 抖动；
  # 但 iD 不关心顺序，这里保持插入顺序（基础在前、我们的在后），只保证稳定。
  File.write(path, JSON.generate(data))
end

def source
  @source ||= YAML.unsafe_load_file(SOURCE_YAML)
rescue Errno::ENOENT
  die("#{SOURCE_YAML} 不存在")
end

def base_meta
  read_json(BASE_META)
rescue SystemExit
  { "version" => "unknown", "range" => source["meta"]["base_version_range"] }
end

def valid_icons
  @valid_icons ||= begin
    die("#{ICON_FILE} 不存在。先跑 `scripts/build_id_minecraft_presets.rb icons`。") unless File.exist?(ICON_FILE)
    File.readlines(ICON_FILE, chomp: true).reject(&:empty?).to_set
  end
end

# ---------------------------------------------------------------------------
# 校验我们的源文件（写错了要在这里就炸，别等 iD 静默不显示）
# ---------------------------------------------------------------------------
def validate_source!
  errors = []
  presets = source["presets"] || {}
  fields  = source["fields"] || {}
  cats    = source["categories"] || []
  cat_ids = cats.map { |c| c["id"] }.to_set

  field_prefix = source["meta"]["field_prefix"]
  fields.each do |fid, f|
    errors << "字段 #{fid} 不以 #{field_prefix} 开头" unless fid.start_with?(field_prefix)
    errors << "字段 #{fid} 缺 key" if f["key"].to_s.empty?
    errors << "字段 #{fid} 缺 label" if f["label"].to_s.empty?
    errors << "字段 #{fid} 的 type 不支持：#{f['type']}" unless %w[combo text check].include?(f["type"])
    if f["type"] == "combo" && (f["options"].nil? || f["options"].empty?)
      errors << "字段 #{fid} 是 combo 但没有 options"
    end
  end

  cats.each do |c|
    errors << "分类 #{c['id']} 不以 category- 开头" unless c["id"].to_s.start_with?("category-")
    errors << "分类 #{c['id']} 缺 name" if c["name"].to_s.empty?
    errors << "分类 #{c['id']} 的 icon 不是合法 sprite id：#{c['icon']}" unless valid_icons.include?(c["icon"])
    (c["more_fields"] || []).each do |mf|
      errors << "分类 #{c['id']} 的 more_fields 引用了不存在的字段 #{mf}" unless fields.key?(mf)
    end
  end

  presets.each do |pid, p|
    errors << "预设 #{pid} 不以 minecraft/ 开头" unless pid.start_with?("minecraft/")
    errors << "预设 #{pid} 缺 name" if p["name"].to_s.empty?
    errors << "预设 #{pid} 的 tags 为空" if (p["tags"] || {}).empty?
    errors << "预设 #{pid} 的 icon 不是合法 sprite id：#{p['icon']}" unless valid_icons.include?(p["icon"])
    errors << "预设 #{pid} 的 category 不存在：#{p['category']}" unless cat_ids.include?(p["category"])
    geo = p["geometry"] || []
    errors << "预设 #{pid} 的 geometry 为空" if geo.empty?
    geo.each { |g| errors << "预设 #{pid} 的 geometry 非法：#{g}" unless GEOMETRIES.include?(g) }
    errors << "预设 #{pid} 的 geometry 含 vertex/relation（本项目用不到）" if (geo & %w[vertex relation]).any?
    (p["tags"] || {}).each_key do |k|
      errors << "预设 #{pid} 的 tags 键 #{k} 不是 minecraft* 键" unless k == "minecraft" || k.start_with?("minecraft:")
    end
    (p["fields"] || []).each do |fid|
      next if fid == "name"
      errors << "预设 #{pid} 的 fields 引用了不存在的字段 #{fid}" unless fields.key?(fid)
    end
    (p["more_fields"] || []).each do |fid|
      errors << "预设 #{pid} 的 more_fields 引用了不存在的字段 #{fid}" unless fields.key?(fid)
    end
  end

  return if errors.empty?

  warn "源文件校验失败（#{errors.size} 处）："
  errors.each { |e| warn "  ✗ #{e}" }
  exit 1
end

# ---------------------------------------------------------------------------
# fetch：下载基础 schema
# ---------------------------------------------------------------------------
def cdn_get(url)
  uri = URI(url)
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 120) do |http|
    http.get(uri.request_uri)
  end
  die("下载失败 #{url} -> HTTP #{res.code}") unless res.is_a?(Net::HTTPSuccess)
  res.body
end

def cmd_fetch(_opts)
  range = source["meta"]["base_version_range"]
  die("meta.base_version_range 没写") if range.to_s.empty?
  puts "== fetch：基础 schema（范围 #{range}）=="
  # jsDelivr 支持 semver 范围，iD 运行时也是这么解析的：先取 package.json 拿到
  # 具体版本，再按具体版本取 dist/*。我们照抄，保证「基础」和 iD 现在实际拿的一致。
  pkg = JSON.parse(cdn_get("#{format(CDN_TMPL, URI.encode_www_form_component(range))}package.json"))
  version = pkg["version"]
  info "解析到版本 #{version}"
  FileUtils.mkdir_p(VENDOR_DIR)
  BASE_FILES.each do |name|
    body = cdn_get("#{format(CDN_TMPL, version)}dist/#{name}.min.json")
    File.write(File.join(VENDOR_DIR, "#{name}.min.json"), body)
    info "#{name}.min.json  #{body.bytesize} 字节"
  end
  locales = source["meta"]["translations"] || []
  FileUtils.mkdir_p(File.join(VENDOR_DIR, "translations"))
  locales.each do |loc|
    body = cdn_get("#{format(CDN_TMPL, version)}dist/translations/#{loc}.min.json")
    File.write(File.join(VENDOR_DIR, "translations", "#{loc}.min.json"), body)
    info "translations/#{loc}.min.json  #{body.bytesize} 字节"
  end
  index = cdn_get("#{format(CDN_TMPL, version)}dist/translations/index.min.json")
  File.write(File.join(VENDOR_DIR, "translations", "index.min.json"), index)
  write_json(BASE_META, { "version" => version, "range" => range, "requested_at" => Time.now.utc.iso8601 })
  puts "完成：基础 schema 落在 vendor/id-tagging-schema/"
end

# ---------------------------------------------------------------------------
# icons：抽合法图标名
# ---------------------------------------------------------------------------
# 从 web 容器里读 sprite（宿主机没装 node_modules/@openstreetmap 时用这条）。
# 返回图标名数组，失败返回 nil。
def icons_from_docker
  # 本项目真正在用的 compose 文件在 website 仓库的**上一级**（里面有 web/db/edge…
  # 服务）；website 自己那个 docker-compose.yml 是上游的单服务文件，没有 web 服务。
  candidates = [File.join(File.dirname(WEBSITE_ROOT), "docker-compose.yml"),
                File.join(WEBSITE_ROOT, "docker-compose.yml")].select { |f| File.exist?(f) }
  return nil if candidates.empty?

  cmd = 'grep -oh "id=\"[^\"]*\"" /app/node_modules/@openstreetmap/id/dist/img/*-sprite.svg' \
        ' | sed "s/id=\"//;s/\"//" | sort -u'
  candidates.each do |compose|
    out = IO.popen(["docker", "compose", "-f", compose, "exec", "-T", "web", "bash", "-lc", cmd],
                   :err => File::NULL, &:read)
    next unless $?.success?

    names = out.split("\n").map(&:strip).reject(&:empty?)
    return names unless names.empty?
  end
  nil
end

def cmd_icons(opts)
  puts "== icons：抽 iD sprite 里的 symbol id =="
  dir = opts[:sprite_dir]
  candidates = [
    dir,
    "/app/node_modules/@openstreetmap/id/dist/img",                       # web 容器里
    File.join(WEBSITE_ROOT, "node_modules/@openstreetmap/id/dist/img"),   # 宿主机上装了 node_modules 时
    File.expand_path("../../openstreetmap-website/node_modules/@openstreetmap/id/dist/img", WEBSITE_ROOT)
  ].compact
  found = candidates.find { |d| Dir.exist?(d) && !Dir.glob(File.join(d, "*-sprite.svg")).empty? }
  if found
    names = Dir.glob(File.join(found, "*-sprite.svg")).flat_map do |f|
      File.read(f).scan(/id="([^"]+)"/).flatten
    end.uniq.sort
    origin = found
  else
    info "宿主机上没有 sprite 目录，改从 web 容器里取（docker compose exec）"
    names = icons_from_docker
    origin = "docker compose exec web:/app/node_modules/@openstreetmap/id/dist/img/*-sprite.svg"
  end
  unless names
    die(<<~MSG)
      找不到 iD 的 sprite。试过这些本地目录：
      #{candidates.map { |c| "  - #{c}" }.join("\n")}
      也试过 `docker compose exec web ...`（失败或没有输出）。
      请确认 web 容器在跑，或用 --sprite-dir 指定目录：
        ruby scripts/build_id_minecraft_presets.rb icons --sprite-dir <iD 的 dist/img 目录>
    MSG
  end
  FileUtils.mkdir_p(VENDOR_DIR)
  File.write(ICON_FILE, names.join("\n") + "\n")
  info "从 #{origin} 抽到 #{names.size} 个图标名 -> vendor/id-tagging-schema/icon-names.txt"
end

# ---------------------------------------------------------------------------
# build：合并
# ---------------------------------------------------------------------------
def build_field(f)
  out = { "key" => f["key"], "type" => f["type"] }
  out["options"] = f["options"].keys if f["options"]
  out
end

def build_preset(id, p, cat_more_fields, field_by_key)
  more = p.key?("more_fields") ? p["more_fields"] : cat_more_fields
  # fields = 元素编辑器里默认显示的那几个字段。
  # 没显式写时给「name + 这个预设自己那个键对应的字段」——这样用户能在下拉里
  # 换成同键的别的值（例如从村庄换成雪屋）。类别级的 more_fields 只放进
  # more_fields（iD 的「更多字段」区），不占默认字段位。
  fields = p["fields"] || (["name"] + p["tags"].keys.filter_map { |k| field_by_key[k] })
  out = {
    "name" => p["name"],
    "terms" => p["terms"] || [],
    "icon" => p["icon"],
    "geometry" => p["geometry"],
    "tags" => p["tags"]
  }
  out["fields"] = fields
  out["more_fields"] = more unless more.empty?
  out
end

def cmd_build(_opts)
  puts "== build：合并基础 schema + minecraft 预设 =="
  validate_source!
  base = BASE_FILES.to_h { |n| [n, read_json(File.join(VENDOR_DIR, "#{n}.min.json"))] }
  info "基础：#{base['presets'].size} 预设 / #{base['fields'].size} 字段 / #{base['preset_categories'].size} 分类"

  # --- fields -------------------------------------------------------------
  fields = base["fields"].dup
  (source["fields"] || {}).each do |fid, f|
    die("字段 id 撞车：#{fid} 已存在于基础 schema") if fields.key?(fid)
    fields[fid] = build_field(f)
  end
  # tag 键 -> 我们的字段 id，用来给预设推默认 fields
  field_by_key = (source["fields"] || {}).to_h { |fid, f| [f["key"], fid] }

  # --- presets ------------------------------------------------------------
  presets = base["presets"].dup
  cat_more = (source["categories"] || []).to_h { |c| [c["id"], c["more_fields"] || []] }
  (source["presets"] || {}).each do |pid, p|
    die("预设 id 撞车：#{pid} 已存在于基础 schema") if presets.key?(pid)
    presets[pid] = build_preset(pid, p, cat_more[p["category"]] || [], field_by_key)
  end

  # --- categories ---------------------------------------------------------
  # iD 的分组靠「分类的 members 列出 preset id」，preset 自己没有 category 字段，
  # 所以这里从每个 preset 的 category 反推 members（单一事实来源 = 我们的 YAML）。
  categories = base["preset_categories"].dup
  (source["categories"] || []).each do |c|
    die("分类 id 撞车：#{c['id']} 已存在于基础 schema") if categories.key?(c["id"])
    members = presets.select { |pid, p| pid.start_with?("minecraft/") && (source["presets"][pid]["category"] == c["id"]) }.keys
    die("分类 #{c['id']} 没有任何成员") if members.empty?
    categories[c["id"]] = { "name" => c["name"], "icon" => c["icon"], "members" => members }
  end

  # --- defaults（预设面板第一屏要能看见我们的分类）-------------------------
  defaults = base["preset_defaults"].dup
  ours = (source["categories"] || []).map { |c| c["id"] }
  ours_by_geo = ours.to_h do |cid|
    geos = presets.select { |pid, p| pid.start_with?("minecraft/") && source["presets"][pid]["category"] == cid }
                  .values.flat_map { |p| p["geometry"] }.uniq
    [cid, geos]
  end
  configured = (source.dig("defaults", "geometries") || [])
  before = source.dig("defaults", "position").to_s != "after"
  %w[point line area].each do |geo|
    list = defaults[geo] || []
    add = ours.select { |cid| (configured.empty? ? ours_by_geo[cid] : configured).include?(geo) }
    next if add.empty?
    defaults[geo] = before ? add + list : list + add
  end

  # --- translations -------------------------------------------------------
  # iD 里 preset 的 name/terms 有 JSON 兜底，但**分类名 / 字段名 / 字段选项名**
  # 只查 _tagging.presets.* 翻译，没有兜底。所以要把我们的文案合进基础语言包
  # （合并不是替换 —— 替换会把整门语言的 iD 翻译清空）。
  locales = source["meta"]["translations"] || []
  translations = {}
  locales.each do |loc|
    path = File.join(VENDOR_DIR, "translations", "#{loc}.min.json")
    unless File.exist?(path)
      die("缺基础语言包 #{path}。跑了 fetch 吗？（translations 列表见 YAML 的 meta.translations）")
    end
    data = read_json(path)
    die("#{path} 顶层键不是 #{loc}") unless data.key?(loc)
    p3 = data[loc]["presets"] ||= {}
    pcat = p3["categories"] ||= {}
    pfld = p3["fields"] ||= {}
    (source["categories"] || []).each { |c| pcat[c["id"]] = { "name" => c["name"] } }
    (source["fields"] || {}).each do |fid, f|
      entry = { "label" => f["label"] }
      if f["options"]
        entry["options"] = f["options"].transform_values(&:to_s)
      end
      pfld[fid] = entry
    end
    translations[loc] = data
  end

  # --- 落盘 ---------------------------------------------------------------
  # 每次整目录重建，保证幂等：同样的输入跑多少遍产物都逐字节一样（不含时间戳）。
  FileUtils.rm_rf(OUTPUT_DIR)
  FileUtils.mkdir_p(File.join(OUTPUT_DIR, "translations"))
  {
    "presets.min.json" => presets,
    "fields.min.json" => fields,
    "preset_categories.min.json" => categories,
    "preset_defaults.min.json" => defaults
  }.each { |name, data| write_json(File.join(OUTPUT_DIR, name), data) }
  translations.each { |loc, data| write_json(File.join(OUTPUT_DIR, "translations", "#{loc}.min.json"), data) }

  mine = presets.keys.count { |k| k.start_with?("minecraft/") }
  manifests = {
    "generated_by" => "scripts/build_id_minecraft_presets.rb",
    "source" => "config/id_presets_minecraft.yml",
    "base_version" => base_meta["version"],
    "base_version_range" => source["meta"]["base_version_range"],
    "locales" => locales,
    "counts" => {
      "presets" => { "minecraft" => mine, "total" => presets.size },
      "fields" => { "minecraft" => fields.keys.count { |k| k.start_with?(source["meta"]["field_prefix"]) }, "total" => fields.size },
      "categories" => { "minecraft" => categories.keys.count { |k| k.start_with?("category-minecraft-") }, "total" => categories.size }
    },
    "source_sha256" => Digest::SHA256.file(SOURCE_YAML).hexdigest
  }
  write_json(File.join(OUTPUT_DIR, "manifest.json"), manifests)

  info "预设 #{presets.size}（minecraft #{mine}）"
  info "字段 #{fields.size}，分类 #{categories.size}"
  info "语言包 #{translations.keys.join(', ')}"
  info "产物 -> config/id_minecraft/"
  puts "完成。别忘了让 web 容器重新读页面：docker compose restart web（开发环境改视图/路由会自动重载，改了 app/assets 下的 JS 才需要重编译资源）"
end

def base_name_to_data(name, presets, fields, categories, defaults)
  case name
  when "presets.min.json" then presets
  when "fields.min.json" then fields
  when "preset_categories.min.json" then categories
  when "preset_defaults.min.json" then defaults
  else die("未知产物名 #{name}")
  end
end

# ---------------------------------------------------------------------------
# verify：校验产物
# ---------------------------------------------------------------------------
def cmd_verify(_opts)
  puts "== verify：校验 config/id_minecraft/ 的产物 =="
  errors = []
  file_map = FILE_MAP.to_h { |k, v| [k, File.join(OUTPUT_DIR, v)] }
  missing = file_map.values.reject { |p| File.exist?(p) }
  unless missing.empty?
    die("产物缺失：#{missing.join(', ')}。先跑 build。")
  end

  presets = read_json(file_map["preset_presets"])
  fields = read_json(file_map["preset_fields"])
  categories = read_json(file_map["preset_categories"])
  defaults = read_json(file_map["preset_defaults"])
  base_presets = read_json(File.join(VENDOR_DIR, "presets.min.json"))
  base_fields = read_json(File.join(VENDOR_DIR, "fields.min.json"))
  base_categories = read_json(File.join(VENDOR_DIR, "preset_categories.min.json"))
  icons = valid_icons

  # 1) 基础预设/字段/分类一个不能少
  lost = base_presets.keys.reject { |k| presets.key?(k) }
  errors << "基础预设丢了 #{lost.size} 个：#{lost.first(5).inspect}" unless lost.empty?
  lost = base_fields.keys.reject { |k| fields.key?(k) }
  errors << "基础字段丢了 #{lost.size} 个" unless lost.empty?
  lost = base_categories.keys.reject { |k| categories.key?(k) }
  errors << "基础分类丢了 #{lost.size} 个" unless lost.empty?
  info "基础预设 #{base_presets.size} 个全部保留，产物共 #{presets.size} 个"

  # 2) 我们的预设
  mine = presets.select { |k, _| k.start_with?("minecraft/") }
  errors << "产物里没有 minecraft 预设" if mine.empty?
  src_presets = source["presets"] || {}
  (src_presets.keys - mine.keys).each { |k| errors << "源里的预设 #{k} 没进产物" }

  # 3) 每个预设的基本约束
  mine.each do |pid, p|
    errors << "#{pid}: 缺 name" if p["name"].to_s.empty?
    errors << "#{pid}: tags 为空" if (p["tags"] || {}).empty?
    errors << "#{pid}: geometry 为空" if (p["geometry"] || []).empty?
    errors << "#{pid}: icon #{p['icon']} 不在 sprite 里" unless icons.include?(p["icon"])
    (p["fields"] || []).each do |fid|
      errors << "#{pid}: 字段 #{fid} 不存在" unless fid == "name" || fields.key?(fid)
    end
    (p["more_fields"] || []).each do |fid|
      errors << "#{pid}: more_fields #{fid} 不存在" unless fields.key?(fid)
    end
  end

  # 4) 分类 members 与我们的预设一一对应
  (mine.keys.group_by { |pid| src_presets[pid]["category"] }).each do |cid, ids|
    members = (categories[cid] || {})["members"] || []
    errors << "分类 #{cid} 不在产物里" if members.empty?
    (ids - members).each { |id| errors << "分类 #{cid} 少了成员 #{id}" }
  end

  # 5) 默认列表引用的 id 都要能解析到
  defaults.each do |geo, ids|
    ids.each do |id|
      errors << "preset_defaults.#{geo} 引用了不存在的 id #{id}" unless presets.key?(id) || categories.key?(id)
    end
  end

  # 5.5) 重放 iD 预设面板的渲染条件（modules/ui/preset_list.js 的 drawList）：
  #      分类只有在「当前几何下有 >1 个可添加成员」时才会画成磁贴，
  #      而且它得出现在 preset_defaults 里才进得了第一屏。
  { "point" => "point", "line" => "line", "area" => "area" }.each do |geo, _|
    showed = (defaults[geo] || []).select do |cid|
      next false unless cid.start_with?("category-minecraft-")

      members = (categories[cid] || {})["members"] || []
      members.count { |m| (presets[m]["geometry"] || []).include?(geo) } > 1
    end
    if showed.size < 2
      errors << "预设面板的 #{geo} 第一屏只会出现 #{showed.size} 个 minecraft 分类（想看到 5 个的话检查 defaults 与各成员的 geometry）"
    end
    info "预设面板 #{geo} 第一屏：minecraft 分类 #{showed.size} 个（面板上限 35 项，我们的分类排在最前）"
  end

  # 6) 语言包：我们的分类/字段文案在不在
  locales = (source["meta"]["translations"] || [])
  locales.each do |loc|
    path = File.join(OUTPUT_DIR, "translations", "#{loc}.min.json")
    errors << "缺语言包 #{path}" unless File.exist?(path)
    next unless File.exist?(path)
    data = read_json(path)[loc]
    base_loc = read_json(File.join(VENDOR_DIR, "translations", "#{loc}.min.json"))[loc]
    errors << "#{loc}: 基础翻译被清空了" if (data["presets"] || {}).size < (base_loc["presets"] || {}).size
    (source["categories"] || []).each do |c|
      n = data.dig("presets", "categories", c["id"], "name")
      errors << "#{loc}: 分类 #{c['id']} 的 name 缺失" if n.to_s.empty?
    end
    (source["fields"] || {}).each_key do |fid|
      n = data.dig("presets", "fields", fid, "label")
      errors << "#{loc}: 字段 #{fid} 的 label 缺失" if n.to_s.empty?
    end
  end

  # 7) 顺带报一下基础 schema 自己就有多少个预设引用了 iD 本版本不存在的图标
  #    （这是 @openstreetmap/id 与 id-tagging-schema 版本错位造成的既有现象，
  #      不是我们引入的；只提示，不报错）
  drift = base_presets.select { |_, v| v["icon"] && !icons.include?(v["icon"]) }.keys
  unless drift.empty?
    info "提示：基础 schema #{base_meta['version']} 里有 #{drift.size} 个预设引用了本版本 iD sprite 里没有的图标（既有现象，例如 #{drift.first}）"
  end

  if errors.empty?
    puts "校验通过：minecraft 预设 #{mine.size}，字段 #{fields.keys.count { |k| k.start_with?('minecraft_') }}，分类 #{categories.keys.count { |k| k.start_with?('category-minecraft-') }}"
  else
    warn "校验失败（#{errors.size} 处）："
    errors.first(40).each { |e| warn "  ✗ #{e}" }
    exit 1
  end
end

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
opts = { sprite_dir: nil }
parser = OptionParser.new do |o|
  o.banner = "用法：scripts/build_id_minecraft_presets.rb <fetch|icons|build|verify|all> [选项]"
  o.on("--sprite-dir DIR", "icons：iD 的 dist/img 目录") { |v| opts[:sprite_dir] = v }
end
cmd = ARGV.shift
parser.parse!(ARGV)
case cmd
when "fetch"  then cmd_fetch(opts)
when "icons"  then cmd_icons(opts)
when "build"  then cmd_build(opts)
when "verify" then cmd_verify(opts)
when "all"
  cmd_icons(opts)
  cmd_build(opts)
  cmd_verify(opts)
else
  puts parser
  exit(cmd ? 1 : 0)
end
