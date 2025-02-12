# frozen_string_literal: true

require_relative 'boot'
require 'rails'
require 'active_model/railtie'
require 'active_job/railtie'
require 'active_record/railtie'
require 'action_controller/railtie'
require 'action_mailer/railtie'
require 'rails/test_unit/railtie'

# Version: rack-cors ~> 2.0
require 'rack/cors'
# Version: rack-attack ~> 6.6.0
require 'rack/attack'
# Version: active_model_serializers ~> 0.10.0
require 'active_model_serializers'

# Load gems from Gemfile based on current environment
Bundler.require(*Rails.groups)

module RestApiService
  class Application < Rails::Application
    # Initialize configuration defaults for Rails 7.0
    config.load_defaults 7.0

    # Configure for API-only application
    config.api_only = true

    # Security Configuration
    # ---------------------

    # Force SSL in production
    config.force_ssl = true if Rails.env.production?

    # Configure sensitive parameter filtering
    config.filter_parameters += [
      :password, :token, :secret, :key, :authorization,
      :credit_card, :api_key, :access_token
    ]

    # CORS Configuration
    config.middleware.insert_before 0, Rack::Cors do |cors|
      cors.allow do |allow|
        allow.origins ENV.fetch('ALLOWED_ORIGINS', '*').split(',')
        allow.resource '*',
          headers: :any,
          methods: [:get, :post, :put, :patch, :delete, :options, :head],
          credentials: false,
          max_age: 86400
      end
    end

    # Rate Limiting Configuration
    config.middleware.use Rack::Attack
    Rack::Attack.cache.store = ActiveSupport::Cache::RedisCacheStore.new(
      url: ENV['REDIS_URL'],
      pool_size: ENV.fetch('RAILS_MAX_THREADS', 5).to_i,
      pool_timeout: 5
    )

    # Define rate limiting rules
    Rack::Attack.throttle('requests by ip', limit: 1000, period: 1.hour) do |req|
      req.ip
    end

    # Performance Configuration
    # ------------------------

    # Configure Redis caching
    config.cache_store = :redis_cache_store, {
      url: ENV['REDIS_URL'],
      pool_size: ENV.fetch('RAILS_MAX_THREADS', 5).to_i,
      pool_timeout: 5,
      connect_timeout: 1,
      read_timeout: 1,
      write_timeout: 1,
      reconnect_attempts: 3,
      error_handler: -> (method:, returning:, exception:) {
        Rails.logger.error "Redis cache error: #{exception.class}: #{exception.message}"
        Datadog::Statsd.new.increment('redis.cache.error')
      }
    }

    # Configure eager loading
    config.eager_load_paths += %W[
      #{config.root}/lib
      #{config.root}/app/services
      #{config.root}/app/serializers
    ]

    # Configure autoloading
    config.autoload_paths += %W[
      #{config.root}/app/services
      #{config.root}/app/serializers
      #{config.root}/lib
    ]

    # Time Zone and Locale Configuration
    # ---------------------------------
    
    config.time_zone = 'UTC'
    config.active_record.default_timezone = :utc
    config.i18n.default_locale = :en
    config.i18n.available_locales = [:en]
    config.i18n.fallbacks = true

    # Logging Configuration
    # -------------------

    config.log_level = ENV.fetch('RAILS_LOG_LEVEL', 'info').to_sym
    config.log_tags = [
      :request_id,
      :remote_ip,
      :subdomain,
      ->(req) { "v#{req.headers['X-API-Version']}" if req.headers['X-API-Version'] }
    ]

    # Use structured logging in production
    if Rails.env.production?
      config.log_formatter = proc do |severity, time, progname, msg|
        {
          severity: severity,
          time: time,
          progname: progname,
          message: msg,
          service: 'rest-api-service',
          environment: Rails.env
        }.to_json + "\n"
      end
    end

    # Generator Configuration
    # ---------------------

    config.generators do |g|
      g.skip_routes true
      g.skip_views true
      g.skip_helpers true
      g.api_only true
      g.test_framework :rspec
      g.fixture_replacement :factory_bot
    end

    # Health Check Configuration
    # ------------------------

    config.middleware.insert_after Rails::Rack::Logger, Class.new {
      def initialize(app)
        @app = app
      end

      def call(env)
        if env['PATH_INFO'] == '/health'
          [200, {'Content-Type' => 'application/json'}, [{
            status: 'ok',
            version: ENV['APP_VERSION'],
            timestamp: Time.current.iso8601
          }.to_json]]
        else
          @app.call(env)
        end
      end
    }

    # API Versioning Configuration
    # --------------------------

    config.x.api.version = '1.0'
    config.x.api.version_header = 'X-API-Version'

    # Error Handling Configuration
    # --------------------------

    config.exceptions_app = ->(env) {
      ErrorsController.action(:show).call(env)
    }

    # Initialize custom configuration
    config.after_initialize do
      # Set up NewRelic custom attributes
      if defined?(NewRelic)
        NewRelic::Agent.add_custom_attributes(
          app_version: config.x.api.version,
          deployment_type: ENV['DEPLOYMENT_TYPE']
        )
      end
    end
  end
end