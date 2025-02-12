# frozen_string_literal: true

# Model representing audit logs for tracking changes and actions across the application.
# Provides comprehensive audit trail functionality with enhanced performance, security,
# and compliance features.
#
# @version 1.0.0
# @see Technical Specifications/7.3.3/Security Monitoring
# @see Technical Specifications/7.3.4/Compliance Requirements
class AuditLog < ApplicationRecord
  # Constants for configuration
  RETENTION_PERIOD = 90.days
  BATCH_SIZE = 1000
  SENSITIVE_FIELDS = %w[password token secret credit_card ssn tax_id].freeze
  VALID_ACTIONS = %w[create update delete soft_delete restore permanent_delete].freeze

  # Make audit logs immutable after creation
  after_create :make_immutable
  
  # Validations
  validates :action, presence: true, inclusion: { in: VALID_ACTIONS }
  validates :resource_type, presence: true
  validates :resource_id, presence: true
  validates :changes, presence: true
  validates :user_id, presence: true
  validates :ip_address, presence: true

  # Scopes for efficient querying
  scope :recent, -> { order(created_at: :desc).limit(100) }
  scope :for_resource, ->(type, id) { where(resource_type: type, resource_id: id) }
  scope :within_period, ->(start_date, end_date) { where(created_at: start_date..end_date) }
  scope :by_action, ->(action) { where(action: action) }
  scope :by_user, ->(user_id) { where(user_id: user_id) }

  # Class methods for audit log management
  class << self
    # Creates a new audit log entry with security and performance optimizations
    #
    # @param action [String] The audited action
    # @param resource_type [String] The type of resource being audited
    # @param resource_id [Integer] The ID of the audited resource
    # @param changes [Hash] The changes made to the resource
    # @param user_id [Integer] The ID of the user who performed the action
    # @param ip_address [String] The IP address from which the action originated
    # @return [AuditLog] The created audit log entry
    def log_action(action:, resource_type:, resource_id:, changes:, user_id:, ip_address:)
      transaction_with_retry do
        create!(
          action: action,
          resource_type: resource_type,
          resource_id: resource_id,
          changes: sanitize_changes(changes),
          user_id: user_id,
          ip_address: ip_address,
          created_at: Time.current.utc
        )
      end
    rescue StandardError => e
      Rails.logger.error("Failed to create audit log: #{e.message}")
      report_error(e, {
        action: action,
        resource_type: resource_type,
        resource_id: resource_id
      })
      raise
    end

    # Retrieves audit logs for a specific resource with caching
    #
    # @param resource_type [String] The type of resource
    # @param resource_id [Integer] The ID of the resource
    # @return [Array<AuditLog>] Collection of audit logs
    def for_resource(resource_type, resource_id)
      cache_key = "audit_logs:#{resource_type}:#{resource_id}"
      
      REDIS_CACHE_POOL.with do |redis|
        cached = redis.get(cache_key)
        
        if cached
          JSON.parse(cached)
        else
          logs = where(resource_type: resource_type, resource_id: resource_id)
                .order(created_at: :desc)
                .limit(100)
                .to_a
          
          redis.setex(cache_key, 1.hour.to_i, logs.to_json)
          logs
        end
      end
    end

    # Retrieves audit logs within a specified time period
    #
    # @param start_date [DateTime] Start of the period
    # @param end_date [DateTime] End of the period
    # @return [Array<AuditLog>] Collection of audit logs
    def within_period(start_date, end_date)
      raise ArgumentError, 'Invalid date range' if start_date >= end_date

      where(created_at: start_date..end_date)
        .order(created_at: :desc)
    end

    # Cleans up old audit logs based on retention period
    #
    # @return [Integer] Number of records cleaned up
    def cleanup_old_records
      cutoff_date = RETENTION_PERIOD.ago
      
      transaction_with_retry do
        where('created_at < ?', cutoff_date)
          .in_batches(of: BATCH_SIZE)
          .delete_all
      end
    end

    private

    # Sanitizes changes hash by masking sensitive data
    #
    # @param changes [Hash] The changes to sanitize
    # @return [Hash] Sanitized changes
    def sanitize_changes(changes)
      changes.deep_dup.tap do |sanitized|
        SENSITIVE_FIELDS.each do |field|
          if sanitized[field]
            sanitized[field] = '[REDACTED]'
          end
        end
      end
    end

    # Reports errors to monitoring system
    #
    # @param error [StandardError] The error that occurred
    # @param context [Hash] Additional error context
    def report_error(error, context = {})
      Rails.error.report(
        error,
        component: 'AuditLog',
        operation: context[:action],
        resource_type: context[:resource_type],
        resource_id: context[:resource_id]
      )
    end
  end

  private

  # Makes the record immutable after creation
  def make_immutable
    self.readonly!
  end

  # Prevents updates to audit log records
  def readonly?
    !new_record?
  end
end