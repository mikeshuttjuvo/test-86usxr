# frozen_string_literal: true

# redis ~> 4.8.0

class CacheCleanupJob < ApplicationJob
  # Configure job queue and retry behavior
  queue_as :maintenance
  retry_on Redis::ConnectionError, wait: 30.seconds, attempts: 3
  retry_on Redis::TimeoutError, wait: 15.seconds, attempts: 5

  # Constants for job configuration
  BATCH_SIZE = 1000
  MAX_EXECUTION_TIME = 300 # 5 minutes maximum execution time
  SCAN_PATTERN = '*'

  # Metrics tracking keys
  METRICS_KEYS = {
    scanned: 'cache_cleanup.keys_scanned',
    expired: 'cache_cleanup.keys_expired',
    deleted: 'cache_cleanup.keys_deleted',
    errors: 'cache_cleanup.errors',
    duration: 'cache_cleanup.duration'
  }.freeze

  def initialize
    super
    @stats = {
      start_time: Time.current,
      keys_scanned: 0,
      keys_expired: 0,
      keys_deleted: 0,
      errors: 0,
      batches_processed: 0
    }
    @execution_deadline = Time.current + MAX_EXECUTION_TIME
  end

  def perform
    Rails.logger.info("Starting cache cleanup job at #{@stats[:start_time]}")

    REDIS_CACHE_POOL.with do |redis|
      process_cache_cleanup(redis)
    end

    log_cleanup_stats
    report_metrics

    @stats
  rescue StandardError => e
    handle_job_error(e)
    raise
  end

  private

  def process_cache_cleanup(redis)
    cursor = '0'
    
    loop do
      break if Time.current >= @execution_deadline

      cursor, keys = redis.scan(
        cursor,
        match: SCAN_PATTERN,
        count: BATCH_SIZE
      )

      if keys.any?
        batch_stats = cleanup_batch(redis, keys)
        update_stats(batch_stats)
      end

      @stats[:batches_processed] += 1
      
      break if cursor == '0'
    end
  end

  def cleanup_batch(redis, keys)
    batch_stats = { expired: 0, deleted: 0, errors: 0 }

    # Get TTL for all keys in batch using pipeline
    ttls = redis.pipelined do |pipe|
      keys.each { |key| pipe.ttl(key) }
    end

    # Identify expired keys (TTL <= 0)
    expired_keys = keys.zip(ttls).select { |_, ttl| ttl <= 0 }.map(&:first)
    batch_stats[:expired] = expired_keys.size

    return batch_stats if expired_keys.empty?

    # Delete expired keys in pipeline
    begin
      redis.pipelined do |pipe|
        expired_keys.each { |key| pipe.del(key) }
      end
      batch_stats[:deleted] = expired_keys.size
    rescue Redis::BaseError => e
      batch_stats[:errors] += 1
      Rails.logger.error("Error deleting cache keys: #{e.message}")
      report_error(e)
    end

    batch_stats
  end

  def update_stats(batch_stats)
    @stats[:keys_scanned] += BATCH_SIZE
    @stats[:keys_expired] += batch_stats[:expired]
    @stats[:keys_deleted] += batch_stats[:deleted]
    @stats[:errors] += batch_stats[:errors]
  end

  def log_cleanup_stats
    duration = Time.current - @stats[:start_time]
    @stats[:duration] = duration

    message = "Cache cleanup completed in #{duration.round(2)}s: " \
              "#{@stats[:keys_scanned]} keys scanned, " \
              "#{@stats[:keys_expired]} expired keys found, " \
              "#{@stats[:keys_deleted]} keys deleted, " \
              "#{@stats[:errors]} errors encountered, " \
              "#{@stats[:batches_processed]} batches processed"

    if @stats[:errors] > 0
      Rails.logger.warn(message)
    else
      Rails.logger.info(message)
    end
  end

  def report_metrics
    METRICS_KEYS.each do |key, metric_name|
      NewRelic::Agent.record_metric(metric_name, @stats[key])
    end

    # Report cache efficiency metrics
    if @stats[:keys_scanned] > 0
      expiration_rate = (@stats[:keys_expired].to_f / @stats[:keys_scanned]) * 100
      NewRelic::Agent.record_metric('cache_cleanup.expiration_rate', expiration_rate)
    end

    # Report success rate
    if @stats[:keys_expired] > 0
      success_rate = (@stats[:keys_deleted].to_f / @stats[:keys_expired]) * 100
      NewRelic::Agent.record_metric('cache_cleanup.success_rate', success_rate)
    end
  end

  def handle_job_error(error)
    Rails.logger.error("Cache cleanup job failed: #{error.message}")
    NewRelic::Agent.notice_error(error)
    
    # Record error metrics
    NewRelic::Agent.increment_metric('cache_cleanup.job_errors')
    
    # Ensure partial stats are still reported
    report_metrics
  end

  def report_error(error)
    NewRelic::Agent.notice_error(error)
    NewRelic::Agent.increment_metric('cache_cleanup.operation_errors')
  end
end