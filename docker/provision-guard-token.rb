# 为「关系成员守卫」准备一个长期有效的 API 令牌。
#
# 守卫需要令牌才能调 OAuth 保护的 API；令牌写到 tmp/guard.token（web 容器里就是
# /app/tmp/guard.token），由 web/start.sh 在启动时调用本脚本，然后后台启动守卫。
#
# 幂等：文件里的令牌仍然可用就直接复用，不会每次启动都新建。
# 用法：bundle exec rails runner docker/provision-guard-token.rb

path = Rails.root.join("tmp", "guard.token")
existing = File.exist?(path) ? File.read(path).strip : nil

usable = false
if existing && !existing.empty?
  token = Doorkeeper::AccessToken.find_by(token: existing)
  usable = !token.nil?
  usable &&= !token.revoked? if token.respond_to?(:revoked?)
  usable &&= token.expires_at.nil? || token.expires_at > Time.now + 86_400 if token.respond_to?(:expires_at)
end

if usable
  puts "GUARD_TOKEN=ok"
else
  app = if defined?(Oauth2Application)
          Oauth2Application.find_by(uid: Settings.id_application) || Oauth2Application.first
        else
          Doorkeeper::Application.find_by(uid: Settings.id_application) || Doorkeeper::Application.first
        end
  user = User.find_by(display_name: "mapper") || User.first

  if app.nil? || user.nil?
    warn "GUARD_TOKEN=error 找不到 OAuth 应用或用户"
  else
    at = Doorkeeper::AccessToken.create!(
      application: app,
      resource_owner_id: user.id,
      scopes: "write_api read_prefs",
      expires_in: 10 * 365 * 24 * 3600 # 10 年
    )
    File.write(path, at.token)
    puts "GUARD_TOKEN=created"
  end
end
