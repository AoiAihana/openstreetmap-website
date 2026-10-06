# frozen_string_literal: true

# iD 的 tagging schema（预设 / 字段 / 分类 / 默认列表 + tagging 语言包）本来由 iD
# 在浏览器里**直接去 jsDelivr** 取 @openstreetmap/id-tagging-schema 的 dist/*.min.json。
#
# 这个模块把它们换成我们自己合并了 minecraft:* 预设的产物：
#
#   源文件    config/id_presets_minecraft.yml        （手写，唯一事实来源）
#   构建脚本  scripts/build_id_minecraft_presets.rb  （合并基础 schema + 我们的）
#   产物      config/id_minecraft/                   （iD 能吃的 JSON）
#   伺服      IdPresetsController                    （/id/minecraft/*）
#   接线      app/views/site/id.html.erb             （asset map + data-id-schema-files）
#             app/assets/javascripts/id.js           （把 iD 的 fileMap 改成相对路径）
#
# ⚠️ 为什么改了 asset map 还要动 fileMap：
#   iD 的 context.asset()（modules/core/file_fetcher.js）对 http(s) 开头的值是
#   **直接原样返回**的，压根不查 asset map。而 preset_presets / preset_fields /
#   preset_categories / preset_defaults / locale_tagging_* 在 iD 的 fileMap 里
#   都是绝对 CDN URL，所以只加 asset map 条目不会生效。id.js 里先把这几个键换成
#   相对路径（data/xxx.min.json），asset() 才会走 assetPath + assetMap 这条路 ——
#   也就是底图 imagery 一直在走的那条路。
#
# 产物不存在时（比如刚 clone 还没跑构建脚本）这里全部返回空，页面完全保持原样，
# 编辑器不会坏。
module IdMinecraftPresets
  OUTPUT_DIR = Rails.root.join("config", "id_minecraft")
  MANIFEST_FILE = OUTPUT_DIR.join("manifest.json")

  # iD fileMap 的逻辑键 -> 产物文件（相对 OUTPUT_DIR）。
  # 左边这几个键来自 iD.js 的 modules/core/file_fetcher.js（coreFileFetcher 的 _fileMap）。
  FILES = {
    "preset_presets" => "presets.min.json",
    "preset_fields" => "fields.min.json",
    "preset_categories" => "preset_categories.min.json",
    "preset_defaults" => "preset_defaults.min.json"
  }.freeze

  # iD 在 localizer.loadLocale() 里拼的键是 `locale_<scope>_<locale>`，
  # 我们只接管 tagging 这一层（general 那层是 iD 包里的 locales/，不动）。
  TRANSLATION_KEY_PREFIX = "locale_tagging_"
  TRANSLATION_DIR = "translations"

  # 产物在 URL 上的前缀，和 config/routes.rb 的 /id/minecraft/* 一致。
  URL_PREFIX = "/id/minecraft/"

  # iD 的 assetPath 是 "@openstreetmap/id/dist/"，asset_map 的键就是这个前缀 + 相对路径。
  # 底图的覆盖（imagery.min.json）用的也是这个约定。
  ASSET_MAP_PREFIX = "@openstreetmap/id/dist/"

  # fileMap / asset_map / URL 里的相对路径统一带这层前缀（模仿 iD 原本逻辑文件名
  # 的形状）；磁盘上 config/id_minecraft/ 里的文件没有这一层。
  ID_DATA_PREFIX = "data/"

  class << self
    # 产物是否可用：manifest 在、且它列出的文件都在。
    # 每次请求现读（文件很小），这样重新 build 之后不用重启 web。
    def built?
      m = manifest
      return false unless m

      required_files.all? { |f| File.exist?(OUTPUT_DIR.join(f)) }
    end

    # iD fileMap 的覆盖：{"preset_presets" => "data/presets.min.json", ..., "locale_tagging_zh-CN" => "data/translations/zh-CN.min.json"}
    # 产物不可用时返回空 Hash，页面行为不变。
    def file_map
      return {} unless built?

      map = FILES.transform_values { |v| relative_path(v) }
      locales.each { |loc| map["#{TRANSLATION_KEY_PREFIX}#{loc}"] = relative_path(translation_file(loc)) }
      map
    end

    # asset_map 的追加条目：{"@openstreetmap/id/dist/data/presets.min.json" => "/id/minecraft/presets.min.json", ...}
    def asset_map_entries
      return {} unless built?

      file_map.values.to_h { |rel| [ASSET_MAP_PREFIX + rel, url_for(rel)] }
    end

    # 产物里的语言包列表（构建脚本写进 manifest.json，来源是 YAML 的 meta.translations）
    def locales
      (manifest || {})["locales"] || []
    end

    def counts
      (manifest || {})["counts"] || {}
    end

    def base_version
      (manifest || {})["base_version"]
    end

    # controller 的白名单：只允许取产物目录里这些固定的相对路径
    def servable?(relative)
      return false if relative.to_s.empty?

      allowed = FILES.values.map { |v| relative_path(v) } +
                locales.map { |loc| relative_path(translation_file(loc)) }
      allowed.include?(relative.to_s)
    end

    def path_for(relative)
      # 磁盘上文件就叫 presets.min.json；URL 与 asset_map 里的相对路径多一层
      # data/ 前缀，那是为了跟 iD 原本的逻辑文件名同形（iD 的 assetPath 是
      # "@openstreetmap/id/dist/"，后面拼的就是 "data/presets.min.json"）。
      OUTPUT_DIR.join(relative.to_s.delete_prefix(ID_DATA_PREFIX))
    end

    private

    def url_for(relative)
      "#{URL_PREFIX}#{relative}"
    end

    # iD 是在 assetPath("@openstreetmap/id/dist/") 后面拼这个值的，
    # 所以统一写成 data/... ，和 iD 原本的逻辑文件名保持同样的形状。
    def relative_path(name)
      "#{ID_DATA_PREFIX}#{name}"
    end

    def translation_file(locale)
      "#{TRANSLATION_DIR}/#{locale}.min.json"
    end

    def required_files
      FILES.values + locales.map { |loc| translation_file(loc) }
    end

    def manifest
      mtime = manifest_mtime
      return nil unless mtime
      # 用 mtime 做缓存键：重新 build 之后立刻生效，不用重启 web，也不会每请求读盘。
      return @manifest if defined?(@manifest_mtime) && @manifest_mtime == mtime

      @manifest_mtime = mtime
      @manifest = JSON.parse(File.read(MANIFEST_FILE))
    rescue JSON::ParserError => e
      Rails.logger.warn("IdMinecraftPresets: #{MANIFEST_FILE} 不是合法 JSON（#{e.message}），按未构建处理")
      @manifest_mtime = nil
      @manifest = nil
    end

    def manifest_mtime
      File.mtime(MANIFEST_FILE).to_f
    rescue Errno::ENOENT
      nil
    end
  end
end
