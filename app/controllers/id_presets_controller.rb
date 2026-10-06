# frozen_string_literal: true

# 伺服 iD 的 tagging schema 产物（合并了 minecraft:* 预设的那些 JSON）。
#
# 背景：iD 启动时会去 jsDelivr 取 @openstreetmap/id-tagging-schema 的
# presets.min.json / fields.min.json / preset_categories.min.json /
# preset_defaults.min.json 和 dist/translations/<locale>.min.json。前端通过
# asset map + fileMap 改写（见 app/views/site/id.html.erb 与
# app/assets/javascripts/id.js）把这几个文件指到这里，于是编辑器里能直接点选
# minecraft:* 的元素预设。
#
# 产物由 scripts/build_id_minecraft_presets.rb 从
# config/id_presets_minecraft.yml + 基础 schema 合并生成到 config/id_minecraft/。
# 与 config/id_imagery.yml 那份不同的是：这份是**构建期**生成的文件（400KB+，
# 请求时再合并太浪费），这里只做白名单校验 + send_file。
#
# 为什么用 controller 而不是丢进 public/：本实例开发/生产共用同一份 public/assets，
# 且生产是否启用 Rack::Static 取决于环境；走路由在两种环境下行为一致。
class IdPresetsController < ApplicationController
  # schema 是公开数据（iD 本来就从公共 CDN 取），也不需要登录。
  # ApplicationController 里开了全局的 check_authorization，所以显式跳过。
  skip_authorization_check

  def show
    relative = params[:path].to_s

    # 白名单：路径不可能穿越（不在 IdMinecraftPresets.servable? 里的一律 404）
    unless IdMinecraftPresets.servable?(relative)
      raise ActionController::RoutingError, "Unknown iD tagging schema file: #{relative}"
    end

    path = IdMinecraftPresets.path_for(relative)
    unless File.exist?(path)
      render :plain => "iD tagging schema 还没生成，请跑 scripts/build_id_minecraft_presets.rb build",
             :status => :not_found,
             :content_type => "text/plain"
      return
    end

    # 产物只在重新构建时变。max-age=0 + must-revalidate：浏览器每次带
    # If-None-Match/If-Modified-Since 回来（Rails 的 Rack::ETag /
    # Rack::ConditionalGet 会给 304），既不重下 400KB，也不会拿到旧内容。
    response.headers["Cache-Control"] = "public, max-age=0, must-revalidate"
    send_file path, :type => "application/json", :disposition => "inline"
  end
end
