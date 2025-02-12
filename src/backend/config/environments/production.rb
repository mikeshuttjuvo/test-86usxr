# frozen_string_literal: true

require 'active_support/core_ext/integer/time'
require 'newrelic_rpm' # Version ~> 8.0
require 'sidekiq' # Version ~> 7.0
require 'redis' # Version ~> 5.0

Rails.application.configure do
  # Code Loading
  config.cache_classes = true
  config.eager_load = true
  config.require_master_key = true
  config.check_yarn_integrity = false

  # Logging
  config.log_level = :info
  config.log_tags = [:request_id, :remote_ip]
  config.log_formatter = ::Logger::Formatter.new
  config.logger = ActiveSupport::Logger.new($stdout)
  config.logger.formatter = proc do |severity, time, progname, msg|
    {
      severity: severity,
      time: time.iso8601,
      progname: progname,
      message: msg,
      service: 'rest-api-service',
      environment: Rails.env
    }.to_json + "\n"
  end
  config.active_support.report_deprecations = false
  
  # Lograge configuration for structured logging
  config.lograge.enabled = true
  config.lograge.base_controller_class = ['ActionController::API']
  config.lograge.custom_options = lambda do |event|
    {
      time: event.time,
      request_id: event.payload[:request_id],
      remote_ip: event.payload[:remote_ip],
      user_agent: event.payload[:user_agent]
    }
  end

  # Cache Configuration
  redis_config = {
    url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'),
    pool_size: ENV.fetch('RAILS_MAX_THREADS', 10).to_i,
    pool_timeout: 5,
    connect_timeout: 1,
    read_timeout: 1,
    write_timeout: 1,
    reconnect_attempts: 3,
    error_handler: -> (method:, returning:, exception:) {
      Rails.logger.error "Redis cache error: #{exception.class}: #{exception.message}"
      NewRelic::Agent.notice_error(exception)
    }
  }

  config.cache_store = :redis_cache_store, redis_config
  config.action_controller.perform_caching = true
  config.public_file_server.headers = {
    'Cache-Control' => "public, max-age=#{1.year.to_i}"
  }

  # Security Configuration
  config.force_ssl = true
  config.ssl_options = {
    hsts: {
      subdomains: true,
      preload: true,
      expires: 1.year.to_i
    },
    redirect: { status: 308 }
  }
  config.action_dispatch.default_headers = {
    'X-Frame-Options' => 'DENY',
    'X-Content-Type-Options' => 'nosniff',
    'X-XSS-Protection' => '1; mode=block',
    'X-Download-Options' => 'noopen',
    'X-Permitted-Cross-Domain-Policies' => 'none',
    'Referrer-Policy' => 'strict-origin-when-cross-origin',
    'Content-Security-Policy' => "default-src 'none'; frame-ancestors 'none'"
  }
  config.action_controller.allow_forgery_protection = false
  config.session_store = false

  # API Configuration
  config.api_only = true
  config.debug_exception_response_format = :api
  config.action_controller.default_url_options = { protocol: 'https' }
  config.action_dispatch.tld_length = ENV.fetch('TLD_LENGTH', 2).to_i

  # Active Record Configuration
  config.active_record.database_selector = {
    delay: 2.seconds,
    database_resolver: ActiveRecord::Middleware::DatabaseSelector::Resolver,
    database_resolver_context: ActiveRecord::Middleware::DatabaseSelector::Resolver::Session
  }
  config.active_record.database_resolver = {
    read: {
      delay: 2.seconds
    }
  }
  config.active_record.migration_error = :page_load
  config.active_record.verbose_query_logs = false
  config.active_record.dump_schema_after_migration = false
  config.active_record.maintain_test_schema = false
  config.active_record.connection_pool.size = ENV.fetch('DB_POOL_SIZE', 10).to_i

  # Active Job Configuration
  config.active_job.queue_adapter = :sidekiq
  config.active_job.queue_name_prefix = "api_service_prod"
  config.active_job.retry_jitter = true
  config.active_job.default_priority = 'medium'

  # Action Mailer Configuration
  config.action_mailer.perform_caching = true
  config.action_mailer.delivery_method = :smtp
  config.action_mailer.smtp_settings = {
    address: ENV['SMTP_ADDRESS'],
    port: ENV.fetch('SMTP_PORT', 587).to_i,
    user_name: ENV['SMTP_USERNAME'],
    password: ENV['SMTP_PASSWORD'],
    authentication: :login,
    enable_starttls_auto: true
  }

  # Monitoring Configuration
  NewRelic::Agent.config.update!(
    app_name: ENV.fetch('NEW_RELIC_APP_NAME', 'REST API Service'),
    monitor_mode: true,
    distributed_tracing: {
      enabled: true
    },
    transaction_tracer: {
      record_sql: 'obfuscated',
      enabled: true,
      transaction_threshold: 4.0
    }
  )

  # Exception Notification
  config.middleware.use ExceptionNotification::Rack,
    email: {
      sender_address: ENV['EXCEPTION_SENDER'],
      exception_recipients: ENV['EXCEPTION_RECIPIENTS']&.split(',')
    },
    slack: {
      webhook_url: ENV['SLACK_WEBHOOK_URL'],
      channel: '#exceptions',
      additional_parameters: {
        mrkdwn: true
      }
    }

  # Rack Timeout
  config.middleware.insert_before Rack::Runtime, Rack::Timeout, service_timeout: 15

  # Enable gzip compression
  config.middleware.use Rack::Deflater

  # I18n Configuration
  config.i18n.fallbacks = true
  config.i18n.default_locale = :en
  config.i18n.available_locales = [:en]
end