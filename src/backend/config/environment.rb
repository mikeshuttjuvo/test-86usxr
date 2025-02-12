# frozen_string_literal: true

# Version: rails ~> 7.0.0
# Purpose: Primary Rails environment configuration file that bootstraps the application
# and initializes all required components for the REST API service.

# Load the Rails application
require_relative 'application'

# Initialize monitoring for boot performance
boot_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

begin
  # Initialize the Rails application with environment-specific configurations
  Rails.application.initialize!

  # Configure NewRelic monitoring for production and staging
  if Rails.env.production? || Rails.env.staging?
    # Version: newrelic_rpm ~> 8.0
    require 'newrelic_rpm'
    NewRelic::Agent.manual_start(
      app_name: ENV.fetch('NEW_RELIC_APP_NAME', 'REST API Service'),
      monitor_mode: true,
      distributed_tracing: { enabled: true },
      transaction_tracer: { 
        record_sql: 'obfuscated',
        enabled: true,
        transaction_threshold: 0.5 # 500ms as per performance requirements
      }
    )
  end

  # Configure Datadog metrics collection
  # Version: ddtrace ~> 1.0
  if Rails.env.production? || Rails.env.staging?
    require 'datadog/statsd'
    require 'ddtrace'
    Datadog.configure do |c|
      c.service = 'rest-api-service'
      c.env = Rails.env
      c.version = ENV['APP_VERSION']
      c.runtime_metrics.enabled = true
      c.tracing.instrument :rails
      c.tracing.instrument :redis
      c.tracing.instrument :pg
    end
  end

  # Configure Sidekiq for background job processing
  # Version: sidekiq ~> 7.0
  if defined?(Sidekiq)
    Sidekiq.configure_server do |config|
      config.redis = { 
        url: ENV['REDIS_URL'],
        pool_size: ENV.fetch('SIDEKIQ_CONCURRENCY', 25).to_i
      }
    end

    Sidekiq.configure_client do |config|
      config.redis = { 
        url: ENV['REDIS_URL'],
        pool_size: ENV.fetch('RAILS_MAX_THREADS', 5).to_i
      }
    end
  end

  # Log successful boot completion with performance metrics in production
  if Rails.env.production?
    boot_duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - boot_start
    Rails.logger.info(
      {
        event: 'application_boot',
        duration_seconds: boot_duration.round(4),
        rails_env: Rails.env,
        ruby_version: RUBY_VERSION,
        rails_version: Rails.version,
        database_adapter: ActiveRecord::Base.connection.adapter_name,
        database_pool_size: ActiveRecord::Base.connection_pool.size,
        redis_url: ENV['REDIS_URL']&.gsub(/:[^:@]+@/, ':****@'),
        cache_store: Rails.application.config.cache_store.first.to_s
      }.to_json
    )
  end

rescue StandardError => e
  # Log detailed error information for boot failures
  Rails.logger.error(
    {
      event: 'application_boot_error',
      error_class: e.class.name,
      error_message: e.message,
      backtrace: e.backtrace&.first(10),
      rails_env: Rails.env
    }.to_json
  )
  raise e
end