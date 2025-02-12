# frozen_string_literal: true

require 'geocoder'
require 'redis'

# Service object responsible for geocoding location addresses into latitude and longitude coordinates
# with comprehensive error handling, rate limiting, and performance optimization.
#
# @version 1.0.0
# @see Technical Specifications/3.1.3/Integration Requirements
class GeocodingService < ApplicationService
  # Redis rate limit key prefix
  RATE_LIMIT_PREFIX = 'geocoding:rate_limit'
  
  # Default configuration values
  DEFAULTS = {
    retry_attempts: 3,
    retry_delay: 1.0,
    rate_limit_threshold: 1000,
    rate_limit_window: 3600,
    timeout: 5
  }.freeze

  # Error messages following RFC 7807 format
  ERRORS = {
    invalid_address: 'Address format is invalid or missing',
    rate_limit_exceeded: 'Geocoding rate limit exceeded',
    geocoding_failed: 'Failed to geocode address',
    service_unavailable: 'Geocoding service is temporarily unavailable'
  }.freeze

  # @return [Location] The location to be geocoded
  attr_reader :location

  # Initialize the geocoding service
  # @param location [Location] The location object to geocode
  # @param options [Hash] Configuration options for the service
  def initialize(location, options = {})
    super()
    @location = location
    @rate_limiter = REDIS_CACHE_POOL
    @geocoding_config = DEFAULTS.merge(options)
    @retry_attempts = @geocoding_config[:retry_attempts]
    @retry_delay = @geocoding_config[:retry_delay]
    @rate_limit_threshold = @geocoding_config[:rate_limit_threshold]
    @rate_limit_window = @geocoding_config[:rate_limit_window]

    configure_geocoder
  end

  private

  # Main service execution method
  # @return [Boolean] Success status of the geocoding operation
  def perform
    return false unless validate_address
    return false unless check_rate_limit

    coordinates = geocode_with_retries
    return false unless coordinates

    update_coordinates(coordinates)
  rescue StandardError => e
    handle_geocoding_error(e)
    false
  end

  # Validates the location address format
  # @return [Boolean] Address validation result
  def validate_address
    return true if location.address.present? && valid_address_format?

    add_error(
      type: 'validation_error',
      title: 'Invalid Address',
      detail: ERRORS[:invalid_address],
      status: 400
    )
    false
  end

  # Checks if the current request exceeds rate limits
  # @return [Boolean] Rate limit check result
  def check_rate_limit
    key = "#{RATE_LIMIT_PREFIX}:#{Time.current.to_i / @rate_limit_window}"

    @rate_limiter.with do |redis|
      count = redis.incr(key)
      redis.expire(key, @rate_limit_window) if count == 1

      if count > @rate_limit_threshold
        add_error(
          type: 'rate_limit_error',
          title: 'Rate Limit Exceeded',
          detail: ERRORS[:rate_limit_exceeded],
          status: 429
        )
        return false
      end
    end
    true
  rescue Redis::BaseError => e
    Rails.logger.error("Rate limit check failed: #{e.message}")
    true # Fail open on rate limit errors
  end

  # Attempts to geocode the address with retries
  # @return [Hash, nil] Geocoding results or nil on failure
  def geocode_with_retries
    retries = 0
    start_time = Time.current

    begin
      results = Geocoder.search(location.address)
      return nil if results.empty?

      record_geocoding_metrics(Time.current - start_time)
      { latitude: results.first.latitude, longitude: results.first.longitude }
    rescue Geocoder::Error => e
      retries += 1
      if retries <= @retry_attempts
        sleep(@retry_delay * retries)
        retry
      end
      handle_geocoding_error(e)
      nil
    end
  end

  # Updates location coordinates in database
  # @param coordinates [Hash] Latitude and longitude values
  # @return [Boolean] Update success status
  def update_coordinates(coordinates)
    ApplicationRecord.transaction_with_retry do
      location.update!(
        latitude: coordinates[:latitude],
        longitude: coordinates[:longitude]
      )
    end
    true
  rescue ActiveRecord::RecordInvalid => e
    handle_validation_error(e)
    false
  end

  # Configures the Geocoder gem
  def configure_geocoder
    Geocoder.configure(
      timeout: @geocoding_config[:timeout],
      lookup: :google,
      api_key: Rails.application.credentials.google_maps_api_key,
      use_https: true,
      cache: REDIS_CACHE_POOL,
      cache_prefix: 'geocoder:',
      always_raise: [
        Geocoder::OverQueryLimitError,
        Geocoder::RequestDenied,
        Geocoder::InvalidRequest,
        Geocoder::InvalidApiKey
      ]
    )
  end

  # Validates address format using basic rules
  # @return [Boolean] Address format validation result
  def valid_address_format?
    address = location.address.to_s
    address.present? &&
      address.length >= 3 &&
      address.length <= 1000 &&
      !address.match?(/^\s*$/) &&
      !address.match?(/^[0-9]+$/)
  end

  # Records geocoding performance metrics
  # @param duration [Float] Time taken for geocoding operation
  def record_geocoding_metrics(duration)
    REDIS_CACHE_POOL.with do |redis|
      redis.pipelined do |pipe|
        pipe.hincrby('geocoding:metrics:daily', Date.current.to_s, 1)
        pipe.hset('geocoding:metrics:latency', Time.current.to_i.to_s, duration)
      end
    end
  rescue Redis::BaseError => e
    Rails.logger.warn("Failed to record geocoding metrics: #{e.message}")
  end

  # Handles geocoding-specific errors
  # @param error [StandardError] The error to handle
  def handle_geocoding_error(error)
    error_data = case error
                 when Geocoder::OverQueryLimitError
                   { type: 'rate_limit_error', status: 429, detail: ERRORS[:rate_limit_exceeded] }
                 when Geocoder::RequestDenied
                   { type: 'authorization_error', status: 403, detail: 'Geocoding request was denied' }
                 when Geocoder::InvalidApiKey
                   { type: 'configuration_error', status: 500, detail: 'Invalid API key configuration' }
                 else
                   { type: 'service_error', status: 500, detail: ERRORS[:service_unavailable] }
                 end

    add_error(
      type: error_data[:type],
      title: error.class.name,
      detail: error_data[:detail],
      status: error_data[:status]
    )
  end

  # Handles validation errors
  # @param error [ActiveRecord::RecordInvalid] The validation error
  def handle_validation_error(error)
    add_error(
      type: 'validation_error',
      title: 'Validation Error',
      detail: error.message,
      status: 400
    )
  end
end