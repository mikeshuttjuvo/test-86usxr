# frozen_string_literal: true

require 'active_support/core_ext/integer/time'

Rails.application.configure do
  # Code Loading and Reloading
  # -------------------------
  config.cache_classes = false
  config.eager_load = false
  config.reload_classes_only_on_change = true
  config.file_watcher = ActiveSupport::EventedFileUpdateChecker

  # Logging and Debugging
  # --------------------
  config.consider_all_requests_local = true
  config.server_timing = true
  config.log_level = :debug
  config.log_tags = [:request_id, :session_id, :remote_ip]
  config.logger = ActiveSupport::Logger.new(STDOUT)
  config.logger.formatter = ::Logger::Formatter.new
  config.active_support.report_deprecations = true
  config.log_formatter = ::Logger::Formatter.new
  config.colorize_logging = true

  # Caching Configuration
  # -------------------
  config.action_controller.perform_caching = true
  config.cache_store = :redis_cache_store, {
    url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'),
    pool_size: ENV.fetch('RAILS_MAX_THREADS', 5).to_i,
    pool_timeout: 5,
    error_handler: ->(method:, returning:, exception:) {
      Rails.logger.error "Redis cache error: #{exception.class}: #{exception.message}"
    },
    reconnect_attempts: 3,
    namespace: 'development_cache',
    expires_in: 1.hour,
    race_condition_ttl: 10.seconds
  }

  # Database Configuration
  # --------------------
  config.active_record.migration_error = :page_load
  config.active_record.verbose_query_logs = true
  config.active_record.maintain_test_schema = true
  config.active_record.schema_format = :ruby
  config.active_record.dump_schema_after_migration = true
  config.active_record.log_level = :debug
  config.active_record.connection_pool.size = ENV.fetch('RAILS_MAX_THREADS', 5).to_i
  config.active_record.connection_timeout = 5

  # Action Mailer Configuration
  # -------------------------
  config.action_mailer.raise_delivery_errors = false
  config.action_mailer.perform_caching = false
  config.action_mailer.delivery_method = :smtp
  config.action_mailer.smtp_settings = {
    address: 'localhost',
    port: 1025,
    enable_starttls_auto: true
  }
  config.action_mailer.default_url_options = {
    host: 'localhost',
    port: 3000,
    protocol: 'http'
  }
  config.action_mailer.perform_deliveries = true

  # Active Job Configuration
  # ----------------------
  config.active_job.queue_adapter = :sidekiq
  config.active_job.retry_jitter = true
  config.active_job.log_arguments = true

  # Action Cable Configuration
  # ------------------------
  config.action_cable.disable_request_forgery_protection = false
  config.action_cable.allowed_request_origins = ['http://localhost:*']

  # Security Configuration
  # --------------------
  config.action_controller.allow_forgery_protection = true
  config.action_controller.default_protect_from_forgery = true
  config.action_controller.raise_on_missing_callback_actions = true

  # Active Support Configuration
  # -------------------------
  config.active_support.deprecation = :log
  config.active_support.disallowed_deprecation = :raise
  config.active_support.disallowed_deprecation_warnings = :log
  config.active_support.cache_format_version = '7.0'

  # Host Authorization
  # ----------------
  config.hosts = [
    'localhost',
    '127.0.0.1',
    '0.0.0.0',
    '.local.test'
  ]

  # Development-specific Error Handling
  # --------------------------------
  config.exceptions_app = ->(env) {
    ActionDispatch::PublicExceptions.new(Rails.public_path).call(env)
  }

  # Asset Handling
  # ------------
  config.public_file_server.enabled = true
  config.public_file_server.headers = {
    'Cache-Control' => "public, max-age=#{1.hour.to_i}"
  }

  # Bullet Configuration for N+1 Query Detection
  # -----------------------------------------
  config.after_initialize do
    Bullet.enable = true
    Bullet.alert = true
    Bullet.bullet_logger = true
    Bullet.console = true
    Bullet.rails_logger = true
    Bullet.add_footer = true
  end

  # Development Performance Monitoring
  # -------------------------------
  config.after_initialize do
    # Enable memory tracking in development
    MemoryProfiler.start if defined?(MemoryProfiler)
    
    # Enable rack-mini-profiler if available
    if defined?(Rack::MiniProfiler)
      Rack::MiniProfiler.config.position = 'bottom-right'
      Rack::MiniProfiler.config.start_hidden = false
    end
  end
end