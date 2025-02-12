# frozen_string_literal: true

require 'active_support/testing/time_helpers'
require 'active_record/test_case'
require 'database_cleaner'

# Test environment configuration implementing comprehensive test settings
# for automated testing, performance monitoring, security testing, and CI/CD pipeline integration
Rails.application.configure do
  # Cache and Code Loading Configuration
  # ----------------------------------
  config.cache_classes = true
  config.eager_load = false
  config.consider_all_requests_local = true

  # Cache Store Configuration
  # -----------------------
  config.cache_store = :null_store, {
    namespace: 'test_cache'
  }

  # Action Controller Configuration
  # -----------------------------
  config.action_controller.perform_caching = false
  config.action_controller.allow_forgery_protection = false
  config.action_controller.raise_on_missing_callback_actions = true
  config.action_controller.default_protect_from_forgery = false

  # Active Support Configuration
  # --------------------------
  config.active_support.deprecation = :stderr
  config.active_support.disallowed_deprecation = :raise
  config.active_support.disallowed_deprecation_warnings = :log
  config.active_support.report_deprecations = false
  config.active_support.test_order = :random

  # Active Record Configuration
  # -------------------------
  config.active_record.migration_error = false
  config.active_record.verbose_query_logs = true
  config.active_record.maintain_test_schema = true

  # Configure DatabaseCleaner strategy
  DatabaseCleaner.strategy = :transaction
  DatabaseCleaner.clean_with(:truncation)

  # Enable parallel testing
  config.active_record.parallel_testing = {
    enabled: true,
    workers: :processors
  }

  # Active Job Configuration
  # ----------------------
  config.active_job.queue_adapter = :test
  config.active_job.retry = false

  # Action Mailer Configuration
  # -------------------------
  config.action_mailer.delivery_method = :test
  config.action_mailer.perform_deliveries = false
  config.action_mailer.raise_delivery_errors = false
  config.action_mailer.perform_caching = false
  config.action_mailer.default_url_options = { host: 'test.example.com' }

  # Action Cable Configuration
  # ------------------------
  config.action_cable.disable_request_forgery_protection = true
  config.action_cable.allowed_request_origins = ['http://test.example.com']

  # Public File Server Configuration
  # -----------------------------
  config.public_file_server.enabled = true
  config.public_file_server.headers = {
    'Cache-Control' => 'public, max-age=3600'
  }

  # Logging Configuration
  # -------------------
  config.log_level = :debug
  config.log_tags = [:request_id, :test_run_id, :test_suite]

  config.logger = Logger.new($stdout)
  config.logger.formatter = ::Logger::Formatter.new
  config.logger.level = :debug
  config.log_formatter = proc do |severity, datetime, progname, msg|
    {
      severity: severity,
      timestamp: datetime.iso8601,
      progname: progname,
      message: msg,
      test_run_id: Thread.current[:test_run_id],
      test_suite: Thread.current[:test_suite]
    }.to_json + "\n"
  end

  # Test Framework Configuration
  # --------------------------
  
  # Enable parallel testing
  config.parallel_testing = true

  # Configure test coverage
  config.coverage_enabled = true
  config.coverage_dir = 'coverage'

  # Performance monitoring configuration
  config.x.test.performance_monitoring = {
    enabled: true,
    threshold_ms: 500,
    track_sql_queries: true,
    track_memory_usage: true
  }

  # Security testing configuration
  config.x.test.security_testing = {
    enable_brakeman: true,
    enable_bundle_audit: true,
    cors_testing: true
  }

  # Configure test-specific middleware
  config.middleware.use(Class.new do
    def initialize(app)
      @app = app
    end

    def call(env)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status, headers, response = @app.call(env)
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

      if config.x.test.performance_monitoring[:enabled] &&
         duration * 1000 > config.x.test.performance_monitoring[:threshold_ms]
        Rails.logger.warn(
          "Slow test request: #{env['PATH_INFO']} took #{duration * 1000}ms"
        )
      end

      [status, headers, response]
    end
  end)

  # Initialize test-specific configurations after application loads
  config.after_initialize do
    # Set up test-specific ActiveSupport::Testing::TimeHelpers
    include ActiveSupport::Testing::TimeHelpers

    # Configure test database connection pool
    ActiveRecord::Base.connection_pool.disconnect!
    config.connection_pool_size = ENV.fetch('TEST_DB_POOL', 5).to_i
    ActiveRecord::Base.establish_connection

    # Set up test-specific error handling
    config.exception_handler = proc do |exception|
      Rails.logger.error "Test Exception: #{exception.class} - #{exception.message}"
      Rails.logger.error exception.backtrace.join("\n")
    end
  end
end