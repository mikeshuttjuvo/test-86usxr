# frozen_string_literal: true

# Base class for all models in the application providing shared functionality
# including audit logging, caching, and soft deletion capabilities.
#
# @version 1.0.0
# @see Technical Specifications/3.2/Database Design
class ApplicationRecord < ActiveRecord::Base
  # Version 7.0.0 for Rails framework
  # Version 8.0.0 for NewRelic monitoring
  # Version 1.0.0 for CircuitBreaker implementation

  # Mark as abstract class
  self.abstract_class = true

  # Include shared functionality from concerns
  include Auditable
  include Cacheable
  include SoftDeletable

  # Default attributes present in all models
  attribute :active, :boolean, default: true
  attribute :created_at, :datetime
  attribute :updated_at, :datetime

  # Circuit breaker configuration
  CIRCUIT_BREAKER_OPTIONS = {
    failure_threshold: 5,
    reset_timeout: 30,
    monitor_timeout: 60
  }.freeze

  # Initialize circuit breaker for database operations
  class_attribute :circuit_breaker
  self.circuit_breaker = CircuitBreaker.new(**CIRCUIT_BREAKER_OPTIONS)

  class << self
    # Executes a block within a database transaction with retry logic
    # @param max_retries [Integer] Maximum number of retry attempts
    # @param initial_wait [Float] Initial wait time between retries
    # @param max_wait [Float] Maximum wait time between retries
    # @param block [Proc] The transaction block to execute
    def transaction_with_retry(max_retries: 3, initial_wait: 0.1, max_wait: 2.0, &block)
      retries = 0
      begin
        circuit_breaker.run do
          transaction(isolation: :read_committed, &block)
        end
      rescue ActiveRecord::DeadlockVictimError, ActiveRecord::LockWaitTimeout => e
        if (retries += 1) <= max_retries
          wait_time = [initial_wait * (2**retries), max_wait].min
          NewRelic::Agent.notice_error(e, custom_params: {
            retries: retries,
            wait_time: wait_time
          })
          sleep(wait_time)
          retry
        else
          raise
        end
      rescue StandardError => e
        NewRelic::Agent.notice_error(e)
        raise
      end
    end

    # Executes a block with connection pool management
    # @param block [Proc] The database operation to execute
    def with_connection_pool(&block)
      pool = ActiveRecord::Base.connection_pool
      connection = pool.checkout
      begin
        yield connection
      ensure
        pool.checkin(connection)
      end
    end
  end

  private

  # Callback to ensure connections are released
  def release_connection
    self.class.connection_pool.release_connection
  end

  # Callback to track database metrics
  def track_metrics
    return unless NewRelic::Agent.instance.started?
    
    NewRelic::Agent.record_metric(
      "Database/#{self.class.name}/operation",
      started_at: Time.current
    )
  end

  # Callback to handle circuit breaker failures
  def handle_circuit_breaker_failure(error)
    NewRelic::Agent.notice_error(error, custom_params: {
      model: self.class.name,
      operation: caller_locations(1,1)[0].label
    })
    Rails.logger.error("Circuit breaker opened for #{self.class.name}: #{error.message}")
  end
end