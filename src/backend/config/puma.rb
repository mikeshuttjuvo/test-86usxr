# frozen_string_literal: true

# Version: puma ~> 6.0
# Purpose: Production-grade Puma web server configuration optimized for REST API service
# with specific tuning for high-throughput performance and resource utilization.

# Load Rails application environment for worker processes
require_relative 'environment'

# Thread Configuration
# ------------------
max_threads_count = ENV.fetch('RAILS_MAX_THREADS') { ENV['RAILS_ENV'] == 'production' ? 16 : 5 }
min_threads_count = ENV.fetch('RAILS_MIN_INSTANCES') { ENV['RAILS_ENV'] == 'production' ? 8 : 2 }
threads min_threads_count, max_threads_count

# Worker Configuration
# ------------------
workers ENV.fetch('WEB_CONCURRENCY') { ENV['RAILS_ENV'] == 'production' ? 4 : 2 }
worker_timeout ENV.fetch('WORKER_TIMEOUT') { ENV['RAILS_ENV'] == 'production' ? 60 : 3600 }

# Server Configuration
# ------------------
port ENV.fetch('PORT') { 3000 }
environment ENV.fetch('RAILS_ENV') { 'development' }
pidfile ENV.fetch('PIDFILE') { 'tmp/pids/server.pid' }

# Cluster Mode Configuration
# ------------------------
state_path 'tmp/pids/puma.state'
bind "tcp://0.0.0.0:#{ENV.fetch('PORT') { 3000 }}"
bind 'unix:///tmp/puma.sock'
activate_control_app 'unix:///tmp/pumactl.sock', { auth_token: ENV['PUMA_CONTROL_TOKEN'] }

# Performance Optimizations
# -----------------------
preload_app!
fork_worker!
prune_bundler
tag ENV.fetch('RACK_ENV') { environment }

# Low-level TCP settings for high throughput
persistent_timeout 20
first_data_timeout 30
backlog 1024
tcp_mode!
optimize_for_latency!

# Quiet logging in production for better performance
quiet if environment == 'production'

# Redirect logs
if ENV['RAILS_ENV'] == 'production'
  stdout_redirect 'log/puma.stdout.log', 'log/puma.stderr.log', true
end

# Worker Process Lifecycle
# ----------------------
on_worker_boot do
  # Load Rails environment
  require_relative 'environment'

  # Configure ActiveRecord connection pool
  ActiveRecord::Base.establish_connection if defined?(ActiveRecord)

  # Configure Redis connection pool
  if defined?(Redis)
    Redis.current = Redis.new(
      url: ENV['REDIS_URL'],
      timeout: 1,
      reconnect_attempts: 3,
      pool_size: max_threads_count
    )
  end

  # Initialize NewRelic monitoring for worker process
  if defined?(NewRelic) && ENV['RAILS_ENV'] == 'production'
    NewRelic::Agent.after_fork(force_reconnect: true)
  end

  # Configure worker process metrics
  if defined?(Datadog)
    Datadog.configure do |c|
      c.runtime_metrics.enabled = true
      c.profiling.enabled = true if ENV['RAILS_ENV'] == 'production'
    end
  end
end

on_worker_shutdown do
  # Clean up database connections
  ActiveRecord::Base.connection_pool.disconnect! if defined?(ActiveRecord)

  # Clear Redis connections
  Redis.current.disconnect! if defined?(Redis) && Redis.current

  # Flush any pending logs
  Rails.logger.flush if defined?(Rails) && Rails.logger.respond_to?(:flush)

  # Report final metrics before shutdown
  if defined?(Datadog) && ENV['RAILS_ENV'] == 'production'
    Datadog::Statsd.new.increment('puma.worker.shutdown')
  end
end

# Low-level Error Handler
# ---------------------
lowlevel_error_handler do |error, env|
  # Log error details
  error_details = {
    error: error.class.name,
    message: error.message,
    backtrace: error.backtrace&.first(10),
    env: env['REQUEST_URI']
  }

  # Report to error tracking
  if defined?(NewRelic) && ENV['RAILS_ENV'] == 'production'
    NewRelic::Agent.notice_error(error)
  end

  # Log error for monitoring
  if defined?(Rails)
    Rails.logger.error(error_details.to_json)
  else
    warn error_details.to_json
  end

  # Return error response
  [500, {}, ['An error has occurred. Please try again later.']]
end