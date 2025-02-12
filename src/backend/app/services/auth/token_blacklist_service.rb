# frozen_string_literal: true

require 'redis'
require 'jwt'
require 'connection_pool'
require 'newrelic_rpm'

# Service class that manages JWT token blacklisting with high availability and performance optimization
# Handles token invalidation, blacklist checking, and cleanup of expired tokens using Redis
#
# @example
#   service = TokenBlacklistService.new(token)
#   service.blacklist # Adds token to blacklist
#   service.blacklisted? # Checks if token is blacklisted
class TokenBlacklistService < ApplicationService
  include NewRelic::Agent::MethodTracer

  REDIS_POOL_SIZE = 5
  REDIS_TIMEOUT = 5
  REDIS_NAMESPACE = 'token_blacklist'
  MAX_RETRIES = 3
  BATCH_SIZE = 1000
  CACHE_TTL = 300 # 5 minutes

  # @return [String] JWT token to be managed
  attr_reader :token

  # @return [Hash] Decoded JWT payload
  attr_reader :payload

  # Initializes the blacklist service with configuration
  #
  # @param token [String] JWT token to manage
  # @param options [Hash] Configuration options
  # @option options [Integer] :pool_size Redis connection pool size
  # @option options [Integer] :timeout Redis operation timeout
  # @option options [Integer] :batch_size Cleanup batch size
  # @option options [Integer] :cache_ttl Local cache TTL
  def initialize(token, options = {})
    super()
    @token = token
    @options = default_options.merge(options)
    @retry_count = 0
    
    initialize_redis_connection
    decode_and_validate_token
    setup_monitoring
  end

  # Adds token to blacklist with proper expiration
  #
  # @return [Boolean] true if blacklisting succeeded
  add_method_tracer :blacklist
  def blacklist
    return false unless @payload

    jti = @payload['jti']
    expiration = calculate_expiration

    redis_operation do |redis|
      redis.multi do |transaction|
        transaction.hset(blacklist_key, jti, Time.current.to_i)
        transaction.expireat(blacklist_key, expiration)
      end

      log_blacklist_operation(jti)
      report_blacklist_metrics

      @success = true
      true
    end
  rescue Redis::BaseError => e
    handle_redis_error(e, __method__)
    false
  end

  # Checks if token is in the blacklist
  #
  # @return [Boolean] true if token is blacklisted
  add_method_tracer :blacklisted?
  def blacklisted?
    return false unless @payload

    jti = @payload['jti']
    cached_result = read_from_cache(jti)
    return cached_result unless cached_result.nil?

    redis_operation do |redis|
      result = redis.hexists(blacklist_key, jti)
      write_to_cache(jti, result)
      result
    end
  rescue Redis::BaseError => e
    handle_redis_error(e, __method__)
    false
  end

  # Removes expired tokens from blacklist
  #
  # @return [Integer] number of tokens removed
  add_method_tracer :cleanup_expired
  def cleanup_expired
    removed_count = 0

    redis_operation do |redis|
      cursor = 0
      current_time = Time.current.to_i

      loop do
        cursor, tokens = redis.hscan(blacklist_key, cursor, count: @options[:batch_size])
        
        expired_tokens = tokens.select { |_, timestamp| timestamp.to_i < current_time }
        if expired_tokens.any?
          redis.hdel(blacklist_key, expired_tokens.map(&:first))
          removed_count += expired_tokens.size
        end

        break if cursor == "0"
      end

      report_cleanup_metrics(removed_count)
      @success = true
      removed_count
    end
  rescue Redis::BaseError => e
    handle_redis_error(e, __method__)
    0
  end

  private

  def default_options
    {
      pool_size: REDIS_POOL_SIZE,
      timeout: REDIS_TIMEOUT,
      batch_size: BATCH_SIZE,
      cache_ttl: CACHE_TTL
    }
  end

  def initialize_redis_connection
    @redis = ConnectionPool.new(size: @options[:pool_size], timeout: @options[:timeout]) do
      Redis.new(url: ENV['REDIS_URL'], driver: :hiredis)
    end
  end

  def decode_and_validate_token
    @payload = JWT.decode(
      @token,
      ENV['JWT_SECRET'],
      true,
      { algorithm: 'HS256' }
    ).first
  rescue JWT::DecodeError => e
    handle_error(e)
    @payload = nil
  end

  def setup_monitoring
    ::NewRelic::Agent.add_custom_attributes(
      service: self.class.name,
      redis_pool_size: @options[:pool_size]
    )
  end

  def redis_operation
    result = nil
    @redis.with do |redis|
      result = yield(redis)
    end
    result
  rescue Redis::BaseError => e
    if (@retry_count += 1) <= MAX_RETRIES
      sleep(0.1 * @retry_count)
      retry
    end
    raise e
  ensure
    @retry_count = 0
  end

  def blacklist_key
    "#{REDIS_NAMESPACE}:tokens"
  end

  def calculate_expiration
    (@payload['exp'] || Time.current.to_i + 24.hours.to_i)
  end

  def read_from_cache(jti)
    Rails.cache.read("#{REDIS_NAMESPACE}:#{jti}")
  end

  def write_to_cache(jti, value)
    Rails.cache.write("#{REDIS_NAMESPACE}:#{jti}", value, expires_in: @options[:cache_ttl])
  end

  def log_blacklist_operation(jti)
    Rails.logger.info(
      "[TokenBlacklist] Token blacklisted - JTI: #{jti}, " \
      "Expires: #{Time.at(calculate_expiration)}"
    )
  end

  def report_blacklist_metrics
    ::NewRelic::Agent.record_metric(
      'Custom/TokenBlacklist/blacklist_operation',
      1
    )
  end

  def report_cleanup_metrics(count)
    ::NewRelic::Agent.record_metric(
      'Custom/TokenBlacklist/cleanup_operation',
      count
    )
  end

  def handle_redis_error(error, operation)
    handle_error(error)
    ::NewRelic::Agent.notice_error(
      error,
      custom_params: {
        operation: operation,
        retry_count: @retry_count
      }
    )
  end
end