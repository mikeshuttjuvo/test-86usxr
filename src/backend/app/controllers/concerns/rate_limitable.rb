# frozen_string_literal: true

# Rate limiting concern for API controllers with Redis-based distributed rate limiting,
# NewRelic monitoring, and comprehensive security features.
#
# @version 1.0.0
# @see Technical Specifications/3.1.1 API Architecture
module RateLimitable
  extend ActiveSupport::Concern

  # Redis key prefix for rate limiting
  RATE_LIMIT_KEY_PREFIX = 'rate_limit'
  # Default rate limit of 1000 requests per hour
  DEFAULT_RATE_LIMIT = 1000
  # Rate limit window in seconds (1 hour)
  RATE_LIMIT_WINDOW = 3600
  # Alert threshold for rate limit monitoring (80%)
  RATE_LIMIT_ALERT_THRESHOLD = 0.8
  # Error message for rate limit exceeded
  RATE_LIMIT_EXCEEDED_MESSAGE = 'Rate limit exceeded. Please try again later.'

  included do
    before_action :check_rate_limit

    rescue_from RateLimitExceededError, with: :handle_rate_limit_exceeded
  end

  private

  # Custom error class for rate limit exceeded
  class RateLimitExceededError < StandardError; end

  # Circuit breaker for Redis operations
  REDIS_CIRCUIT = Circuit::Breaker.new(
    invocation_timeout: 0.5,
    failure_threshold: 5,
    reset_timeout: 30
  )

  # Checks if the current request exceeds the rate limit
  # @return [Boolean] true if request is allowed, false if rate limit exceeded
  # @raise [RateLimitExceededError] when rate limit is exceeded
  def check_rate_limit
    key = rate_limit_key
    current_count = 0

    REDIS_RATE_LIMIT_POOL.with do |redis|
      REDIS_CIRCUIT.run do
        current_count = redis.get(key).to_i

        if current_count >= DEFAULT_RATE_LIMIT
          record_metrics(client_ip, current_count)
          raise RateLimitExceededError
        end

        # Increment counter and set expiry atomically using multi
        redis.multi do |transaction|
          transaction.incr(key)
          transaction.expire(key, RATE_LIMIT_WINDOW) if current_count.zero?
        end
      end
    end

    record_metrics(client_ip, current_count + 1)
    set_rate_limit_headers(current_count + 1)
    true
  rescue Circuit::Breaker::Error => e
    NewRelic::Agent.notice_error(e)
    Rails.logger.error("Rate limit circuit breaker opened: #{e.message}")
    true # Fail open on circuit breaker errors
  rescue Redis::BaseError => e
    NewRelic::Agent.notice_error(e)
    Rails.logger.error("Redis rate limiting error: #{e.message}")
    true # Fail open on Redis errors
  end

  # Generates a secure rate limit key for the current client
  # @return [String] Redis key for rate limiting
  def rate_limit_key
    "#{RATE_LIMIT_KEY_PREFIX}:#{client_ip}:#{controller_name}"
  end

  # Extracts client IP considering trusted proxies
  # @return [String] client IP address
  def client_ip
    request.remote_ip
  end

  # Handles rate limit exceeded errors
  # @return [Hash] error response with headers
  def handle_rate_limit_exceeded
    NewRelic::Agent.increment_metric('Custom/RateLimit/Exceeded')
    
    response.headers['Retry-After'] = RATE_LIMIT_WINDOW.to_s
    response.headers['X-RateLimit-Reset'] = (Time.current + RATE_LIMIT_WINDOW).to_i.to_s
    
    render json: {
      error: 'rate_limit_exceeded',
      message: RATE_LIMIT_EXCEEDED_MESSAGE
    }, status: :too_many_requests
  end

  # Sets rate limit headers on response
  # @param current_count [Integer] current request count
  def set_rate_limit_headers(current_count)
    response.headers['X-RateLimit-Limit'] = DEFAULT_RATE_LIMIT.to_s
    response.headers['X-RateLimit-Remaining'] = (DEFAULT_RATE_LIMIT - current_count).to_s
    response.headers['X-RateLimit-Reset'] = (Time.current + RATE_LIMIT_WINDOW).to_i.to_s
  end

  # Records rate limiting metrics to NewRelic
  # @param client_ip [String] client IP address
  # @param current_count [Integer] current request count
  def record_metrics(client_ip, current_count)
    utilization = current_count.to_f / DEFAULT_RATE_LIMIT
    
    NewRelic::Agent.record_metric('Custom/RateLimit/RequestCount', current_count)
    NewRelic::Agent.record_metric('Custom/RateLimit/Utilization', utilization)

    if utilization >= RATE_LIMIT_ALERT_THRESHOLD
      NewRelic::Agent.notice_error(
        "Rate limit threshold exceeded for #{client_ip}",
        custom_params: {
          client_ip: client_ip,
          utilization: utilization,
          current_count: current_count
        }
      )
    end
  end
end