# frozen_string_literal: true

# activejob ~> 7.0.0
# sidekiq ~> 7.0.0
# globalid ~> 1.0

class ApplicationJob < ActiveJob::Base
  include Sidekiq::Worker
  include GlobalID::Identification
  include ActiveSupport::Configurable

  # Default configuration constants
  DEFAULT_MAX_RETRIES = 3
  DEFAULT_RETRY_DELAY = 5
  DEFAULT_QUEUE = 'default'
  DEFAULT_TIMEOUT = 3600

  # Error handler mapping for different exception types
  ERROR_HANDLERS = {
    StandardError => :handle_standard_error,
    ActiveRecord::RecordNotFound => :handle_not_found,
    Redis::BaseError => :handle_redis_error,
    Timeout::Error => :handle_timeout
  }.freeze

  # Initialize base job configuration
  def initialize
    super
    configure_sidekiq
    configure_error_tracking
    configure_performance_monitoring
  end

  class << self
    # Configure automatic retry behavior for specific exceptions
    # @param exceptions [Array<Class>] Exception classes to retry on
    # @param options [Hash] Retry configuration options
    def retry_on(*exceptions, **options)
      options = {
        wait: DEFAULT_RETRY_DELAY,
        attempts: DEFAULT_MAX_RETRIES,
        queue: :default,
        priority: nil,
        exponential_backoff: true
      }.merge(options)

      super(*exceptions) do |job, error|
        job.executions < options[:attempts] ? handle_retry(job, error, options) : handle_final_failure(job, error)
      end

      track_retry_metrics(exceptions, options)
    end

    # Configure job discard behavior for specific exceptions
    # @param exceptions [Array<Class>] Exception classes to discard on
    # @param options [Hash] Discard configuration options
    def discard_on(*exceptions, **options)
      options = {
        notify: true,
        track: true,
        cleanup: true
      }.merge(options)

      super(*exceptions) do |job, error|
        handle_discard(job, error, options)
      end

      track_discard_metrics(exceptions, options)
    end

    # Set the queue for job processing
    # @param queue_name [Symbol] Name of the queue
    # @param options [Hash] Queue configuration options
    def queue_as(queue_name, **options)
      options = {
        priority: nil,
        resource_limits: {},
        timeout: DEFAULT_TIMEOUT
      }.merge(options)

      validate_queue(queue_name)
      configure_queue_settings(queue_name, options)
      super(queue_name)
    end

    private

    def handle_retry(job, error, options)
      delay = calculate_backoff(job.executions, options[:wait])
      report_error(error, job, :retry, delay)
      job.retry_job(wait: delay)
    end

    def handle_final_failure(job, error)
      report_error(error, job, :failure)
      notify_failure(job, error)
      cleanup_resources(job)
    end

    def handle_discard(job, error, options)
      report_error(error, job, :discard)
      notify_discard(job, error) if options[:notify]
      cleanup_resources(job) if options[:cleanup]
    end

    def calculate_backoff(attempts, base_delay)
      return base_delay unless attempts > 0
      base_delay * (2 ** (attempts - 1))
    end

    def validate_queue(queue_name)
      raise ArgumentError, "Invalid queue name: #{queue_name}" unless queue_name.to_s.match?(/\A[a-z0-9_]+\z/)
    end

    def configure_queue_settings(queue_name, options)
      Sidekiq.configure_server do |config|
        config.options[:queues] ||= []
        config.options[:queues] << queue_name.to_s
        
        if options[:resource_limits]
          config.options[:limits] ||= {}
          config.options[:limits][queue_name.to_s] = options[:resource_limits]
        end
      end
    end

    def track_retry_metrics(exceptions, options)
      # Implementation for tracking retry metrics
      # This would typically integrate with monitoring systems
    end

    def track_discard_metrics(exceptions, options)
      # Implementation for tracking discard metrics
      # This would typically integrate with monitoring systems
    end

    def report_error(error, job, type, delay = nil)
      # Implementation for error reporting
      # This would typically integrate with error tracking systems
    end

    def notify_failure(job, error)
      # Implementation for failure notifications
      # This would typically integrate with notification systems
    end

    def notify_discard(job, error)
      # Implementation for discard notifications
      # This would typically integrate with notification systems
    end

    def cleanup_resources(job)
      # Implementation for resource cleanup
      # This would typically handle any necessary cleanup tasks
    end
  end

  private

  def configure_sidekiq
    self.class.sidekiq_options(
      retry: DEFAULT_MAX_RETRIES,
      queue: DEFAULT_QUEUE,
      backtrace: true,
      timeout: DEFAULT_TIMEOUT
    )
  end

  def configure_error_tracking
    # Implementation for setting up error tracking
    # This would typically integrate with error monitoring services
  end

  def configure_performance_monitoring
    # Implementation for setting up performance monitoring
    # This would typically integrate with APM services
  end
end