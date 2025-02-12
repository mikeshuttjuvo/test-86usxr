# frozen_string_literal: true

# Redis client v4.8.0 - Thread-safe Redis client with SSL/TLS support
require 'redis'
# ConnectionPool v2.4.0 - Thread-safe connection pooling
require 'connection_pool'
require 'concurrent/hash'

# Load Redis configuration from config/redis.yml and symbolize keys
REDIS_CONFIG = Rails.application.config_for(:redis).deep_symbolize_keys

# Build Redis configuration based on pool type with proper security settings
def build_redis_config(pool_type)
  base_config = REDIS_CONFIG[pool_type].merge({
    timeout: REDIS_CONFIG[:connection_timeout],
    read_timeout: REDIS_CONFIG[:read_timeout],
    write_timeout: REDIS_CONFIG[:write_timeout],
    reconnect_attempts: REDIS_CONFIG[:reconnect_attempts],
    driver: :ruby # Use native Ruby driver for better SSL support
  })

  # Configure SSL if enabled
  if REDIS_CONFIG[:ssl_enabled]
    base_config.merge!({
      ssl: true,
      ssl_params: {
        verify_mode: OpenSSL::SSL::VERIFY_PEER,
        ca_file: Rails.root.join('config', 'ssl', 'redis-ca.crt').to_s
      }
    })
  end

  # Configure Sentinel if enabled
  if REDIS_CONFIG[:sentinel_enabled]
    base_config.merge!({
      sentinels: REDIS_CONFIG[:sentinels],
      role: :master
    })
  end

  base_config
end

# Configure Redis logging and error handling
def configure_redis_logging
  Redis.silence_warnings = true unless Rails.env.development?
  
  Redis::Client.logger = Rails.logger
  Redis::Client.logger.level = Rails.env.production? ? Logger::WARN : Logger::DEBUG

  # Configure error handling
  Redis::Client.error_handler = -> (method:, returning:, exception:) {
    error_data = {
      method: method,
      returning: returning,
      error: exception.class.name,
      message: exception.message
    }

    Rails.logger.error("Redis operation failed: #{error_data}")
    Sentry.capture_exception(exception) if defined?(Sentry)
    
    # Update metrics
    REDIS_METRICS[:errors] ||= Concurrent::Hash.new(0)
    REDIS_METRICS[:errors][exception.class.name] += 1
  }
end

# Verify Redis connections with retry mechanism
def verify_redis_connections
  pools = {
    cache: REDIS_CACHE_POOL,
    sidekiq: REDIS_SIDEKIQ_POOL,
    auth: REDIS_AUTH_POOL
  }

  pools.all? do |name, pool|
    retries = 0
    begin
      pool.with do |redis|
        redis.ping == 'PONG'
      end
    rescue Redis::BaseError => e
      retries += 1
      if retries <= REDIS_CONFIG[:retry_attempts]
        Rails.logger.warn("Retrying Redis #{name} connection (attempt #{retries}/#{REDIS_CONFIG[:retry_attempts]})")
        sleep(REDIS_CONFIG[:retry_delay])
        retry
      else
        Rails.logger.error("Failed to verify Redis #{name} connection: #{e.message}")
        false
      end
    end
  end
end

# Initialize metrics tracking
REDIS_METRICS = Concurrent::Hash.new

# Configure Redis logging and error handling
configure_redis_logging

# Initialize connection pools with proper configuration
redis_cache_config = build_redis_config(:cache)
redis_sidekiq_config = build_redis_config(:sidekiq)
redis_auth_config = build_redis_config(:auth)

# Create connection pools with configured sizes and timeouts
REDIS_CACHE_POOL = ConnectionPool.new(
  size: REDIS_CONFIG[:cache_pool_size],
  timeout: REDIS_CONFIG[:default_pool_timeout]
) { Redis.new(redis_cache_config) }

REDIS_SIDEKIQ_POOL = ConnectionPool.new(
  size: REDIS_CONFIG[:sidekiq_pool_size],
  timeout: REDIS_CONFIG[:default_pool_timeout]
) { Redis.new(redis_sidekiq_config) }

REDIS_AUTH_POOL = ConnectionPool.new(
  size: REDIS_CONFIG[:auth_pool_size],
  timeout: REDIS_CONFIG[:default_pool_timeout]
) { Redis.new(redis_auth_config) }

# Verify connections on initialization
unless verify_redis_connections
  raise 'Failed to establish Redis connections. Check configuration and connectivity.'
end

# Set up periodic health checks if enabled
if REDIS_CONFIG[:metrics_enabled] && REDIS_CONFIG[:health_check_interval]
  Thread.new do
    loop do
      REDIS_METRICS[:health_check] = verify_redis_connections
      sleep REDIS_CONFIG[:health_check_interval]
    end
  end
end

# Cleanup on process exit
at_exit do
  [REDIS_CACHE_POOL, REDIS_SIDEKIQ_POOL, REDIS_AUTH_POOL].each do |pool|
    pool.shutdown { |redis| redis.quit }
  end
end