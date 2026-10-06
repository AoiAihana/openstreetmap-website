# frozen_string_literal: true

# 把 config/id_imagery.yml 渲染成 iD 能吃的 imagery JSON。
#
# 背景：iD 启动时会去 fetch 自己 dist/data/imagery.min.json，那是 editor-layer-index
# 的全量清单（1300+ 个源，绝大多数跟本实例无关，还有不少需要 API key）。前端通过
# asset map 把那个逻辑文件名重定向到这里（见 app/views/site/id.html.erb），
# 于是编辑器里只出现本实例真正想提供的底图。
#
# 与 config/layers.yml 的区别：那份是给 Leaflet 主地图用的，而且在编译期内联进
# javascript bundle；本文件是**请求时**读取的，改完刷新页面即可生效，
# 不需要 rails assets:precompile。
class IdImageryController < ApplicationController
  # 底图清单本身不含任何私有信息，也不需要登录才能看，否则未登录用户打开编辑器时
  # 会拿到 403 而退回到 iD 的内置清单。ApplicationController 里开了全局的
  # check_authorization，所以这里必须显式跳过，而不是用 authorize_resource。
  skip_authorization_check

  def show
    layers = YAML.load_file(Rails.root.join("config", "id_imagery.yml"))
    render :json => layers, :content_type => "application/json"
  end
end
