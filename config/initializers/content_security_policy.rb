# frozen_string_literal: true

# Be sure to restart your server when you modify this file.

# Define an application-wide content security policy.
# See the Securing Rails Applications Guide for more information:
# https://guides.rubyonrails.org/security.html#content-security-policy-header

Rails.application.configure do
  connect_src = [:self, "tile.openstreetmap.org", "api.thunderforest.com", "tile.tracestrack.com", "*.openstreetmap.fr", "vector.openstreetmap.org", "api.maptiler.com"]
  img_src = [:self, :data, "www.gravatar.com", "*.wp.com", "tile.openstreetmap.org", "gps.tile.openstreetmap.org", "api.thunderforest.com", "tile.tracestrack.com", "*.openstreetmap.fr"]
  script_src = [:self]

  # Tiles are served through the `edge` reverse proxy on the same origin as the
  # site, and both config files below now use root-relative paths
  # ("/tile/{z}/{x}/{y}.png"), so the browser resolves them against :self and
  # nothing has to be added here. The loop is kept because an absolute URL is
  # still perfectly valid in either file - for example an overlay served by a
  # third party, or a setup that bypasses the edge - and hardcoding the
  # resulting origin a second time is exactly how a self hosted instance ends
  # up with every tile blocked by CSP.
  #
  # Two files describe tile sources nowadays:
  #   config/layers.yml      - the Leaflet map on the main site
  #   config/id_imagery.yml  - the basemap list of the iD editor (/id)
  # Both need their origins allowed; the key holding the URL template differs.
  begin
    {
      "config/layers.yml" => %w[tileUrl tileUrlDark styleUrl styleUrlDark],
      "config/id_imagery.yml" => %w[template]
    }.each do |relative_path, url_keys|
      path = Rails.root.join(relative_path)
      next unless path.exist?

      Array(YAML.load_file(path)).each do |layer|
        next unless layer.is_a?(Hash)

        layer.values_at(*url_keys).compact.each do |template|
          origin = template.sub("{s}", "*")[/\Ahttps?:\/\/[^\/]+/]
          next if origin.blank?

          connect_src << origin unless connect_src.include?(origin)
          img_src << origin unless img_src.include?(origin)
        end
      end
    end
  rescue StandardError => e
    warn "content_security_policy: could not derive tile sources from config: #{e.message}"
  end

  connect_src << Settings.matomo["location"] if defined?(Settings.matomo)
  img_src << Settings.matomo["location"] if defined?(Settings.matomo)
  script_src << Settings.matomo["location"] if defined?(Settings.matomo)

  img_src << Settings.avatar_storage_url if Settings.key?(:avatar_storage_url)
  img_src << Settings.trace_image_storage_url if Settings.key?(:trace_image_storage_url)

  config.content_security_policy do |policy|
    policy.default_src :self
    policy.child_src(:self)
    policy.connect_src(*connect_src)
    policy.font_src(:self)
    policy.form_action(:self)
    policy.frame_ancestors(:self)
    policy.frame_src(:self)
    policy.img_src(*img_src)
    policy.manifest_src(:self)
    policy.media_src(:none)
    policy.object_src(:none)
    policy.plugin_types
    policy.script_src(*script_src)
    policy.style_src(:self)
    policy.worker_src(:blob)
    policy.manifest_src(:self)
    policy.report_uri(Settings.csp_report_url) if Settings.key?(:csp_report_url)
  end

  # Generate session nonces for permitted importmap, inline scripts, and inline styles.
  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(24) }
  config.content_security_policy_nonce_directives = %w[script-src style-src]

  # Report violations without enforcing the policy.
  config.content_security_policy_report_only = true unless Settings.csp_enforce
end
