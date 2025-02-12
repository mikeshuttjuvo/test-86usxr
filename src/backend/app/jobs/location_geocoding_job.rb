# frozen_string_literal: true

# Background job responsible for processing location geocoding operations with comprehensive
# error handling, monitoring, and transaction safety.
#
# @version 1.0.0
# @see Technical Specifications/1.3/Core Features/Location Management
class LocationGeocodingJob < ApplicationJob
  include Sidekiq::Worker

  # Configure job processing options
  sidekiq_options(
    queue: :geocoding,
    retry: 5,
    backtrace: true,
    dead: false,
    tags: ['geocoding', 'location']
  )

  # Constants for configuration
  MAX_RETRIES = 5
  RETRY_DELAY = 30
  LOCK_TIMEOUT = 300
  QUEUE_NAME = 'geocoding'

  # Configure automatic retry behavior
  retry_on GeocodingService::GeocodingError,
          wait: :exponentially_longer,
          attempts: MAX_RETRIES

  # Configure rate limit error handling
  retry_on GeocodingService::RateLimitError,
          wait: RETRY_DELAY,
          attempts: MAX_RETRIES,
          jitter: true

  # Discard job on fatal errors
  discard_on ActiveRecord::RecordNotFound do |job, error|
    Rails.logger.error("Location not found for geocoding job: #{error.message}")
    report_error(error, job)
  end

  # Process geocoding for a single location
  #
  # @param location_id [Integer] ID of the location to geocode
  # @return [Boolean] Success status of the geocoding operation
  def perform(location_id)
    start_time = Time.current

    location = Location.find(location_id)
    return false unless validate_location(location)

    location.with_lock(timeout: LOCK_TIMEOUT) do
      process_geocoding(location)
    end

    record_metrics(start_time)
    true
  rescue StandardError => e
    handle_error(e, location_id)
    false
  end

  private

  # Validates location data before processing
  #
  # @param location [Location] Location to validate
  # @return [Boolean] Validation result
  def validate_location(location)
    return false if location.address.blank?
    return false if location.geocoding_status == 'completed'
    true
  end

  # Processes geocoding for a location with error handling
  #
  # @param location [Location] Location to geocode
  def process_geocoding(location)
    geocoding_service = GeocodingService.new(location)
    
    ApplicationRecord.transaction_with_retry do
      result = geocoding_service.call

      if result.success?
        update_location_status(location, 'completed')
      else
        handle_geocoding_failure(location, geocoding_service.errors)
      end
    end
  end

  # Updates location status after geocoding
  #
  # @param location [Location] Location to update
  # @param status [String] New status value
  def update_location_status(location, status)
    location.update!(
      geocoding_status: status,
      geocoding_metadata: location.geocoding_metadata.merge(
        completed_at: Time.current.iso8601,
        attempts: location.geocoding_metadata['attempts'].to_i + 1
      )
    )
  end

  # Handles geocoding failure
  #
  # @param location [Location] Failed location
  # @param errors [Array] Geocoding errors
  def handle_geocoding_failure(location, errors)
    update_location_status(location, 'failed')
    
    Rails.logger.error(
      "Geocoding failed for location #{location.id}: #{errors.join(', ')}"
    )
  end

  # Records performance metrics
  #
  # @param start_time [Time] Job start time
  def record_metrics(start_time)
    duration = (Time.current - start_time) * 1000.0

    REDIS_CACHE_POOL.with do |redis|
      redis.pipelined do |pipe|
        pipe.hincrby('geocoding:jobs:daily', Date.current.to_s, 1)
        pipe.hset('geocoding:jobs:duration', Time.current.to_i.to_s, duration)
      end
    end
  rescue Redis::BaseError => e
    Rails.logger.warn("Failed to record geocoding metrics: #{e.message}")
  end

  # Handles and reports job errors
  #
  # @param error [StandardError] The error that occurred
  # @param location_id [Integer] ID of the location being processed
  def handle_error(error, location_id)
    error_context = {
      job_class: self.class.name,
      location_id: location_id,
      error_class: error.class.name,
      error_message: error.message,
      backtrace: error.backtrace&.first(5)
    }

    Rails.logger.error("Geocoding job failed: #{error_context}")
    report_error(error, error_context)
  end

  # Reports errors to monitoring system
  #
  # @param error [StandardError] The error to report
  # @param context [Hash] Error context
  def report_error(error, context)
    Rails.error.report(
      error,
      component: 'LocationGeocodingJob',
      operation: 'perform',
      severity: 'error',
      context: context
    )
  end
end