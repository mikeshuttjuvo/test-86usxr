# frozen_string_literal: true

require 'active_support/concern'
require 'active_record/base'

# AuditLogJob handles asynchronous processing of audit log entries with reliability guarantees
# and optimized database operations to ensure compliance with SOC 2 and ISO 27001 requirements.
#
# @version 1.0.0
# @see Technical Specifications/7.3.3/Security Monitoring
# @see Technical Specifications/7.3.4/Compliance Requirements
class AuditLogJob < ApplicationJob
  # Configure dedicated audit queue for isolated processing
  queue_as :audit

  # Configure retry behavior for database-related errors
  retry_on ActiveRecord::ConnectionError, 
          wait: 5.seconds, 
          attempts: 3, 
          jitter: 0.30

  retry_on ActiveRecord::DeadlockVictimError, 
          wait: 5.seconds, 
          attempts: 3, 
          jitter: 0.30

  # Constants for configuration
  AUDIT_QUEUE = 'audit'
  MAX_RETRIES = 3
  RETRY_DELAY = 5
  REQUIRED_FIELDS = %w[action resource_type resource_id changes user_id ip_address].freeze
  
  # Process a single audit log entry with transaction safety and optimized SQL
  #
  # @param action [String] The audited action (e.g., 'create', 'update', 'delete')
  # @param resource_type [String] The type of resource being audited
  # @param resource_id [Integer] The ID of the audited resource
  # @param changes [Hash] The changes made to the resource
  # @param user_id [Integer] The ID of the user who performed the action
  # @param ip_address [String] The IP address from which the action originated
  #
  # @return [Boolean] Success status of the audit log creation
  def perform(action:, resource_type:, resource_id:, changes:, user_id:, ip_address:)
    validate_parameters!(action, resource_type, resource_id, changes, user_id, ip_address)
    
    ActiveRecord::Base.connection_pool.with_connection do |conn|
      conn.transaction(isolation: :read_committed) do
        execute_audit_log_creation(
          action: sanitize_input(action),
          resource_type: sanitize_input(resource_type),
          resource_id: resource_id,
          changes: serialize_changes(changes),
          user_id: user_id,
          ip_address: sanitize_input(ip_address),
          created_at: Time.current.utc
        )
      end
    end
    
    true
  rescue StandardError => e
    handle_error(e)
    false
  end

  private

  # Validates presence and format of all required parameters
  #
  # @raise [ArgumentError] If any required parameter is missing or invalid
  def validate_parameters!(*params)
    action, resource_type, resource_id, changes, user_id, ip_address = params
    
    raise ArgumentError, 'Action must be present' if action.blank?
    raise ArgumentError, 'Resource type must be present' if resource_type.blank?
    raise ArgumentError, 'Resource ID must be present' if resource_id.blank?
    raise ArgumentError, 'Changes must be a hash' unless changes.is_a?(Hash)
    raise ArgumentError, 'User ID must be present' if user_id.blank?
    raise ArgumentError, 'IP address must be present' if ip_address.blank?
  end

  # Sanitizes input strings to prevent SQL injection and ensure data consistency
  #
  # @param input [String] The input string to sanitize
  # @return [String] Sanitized input string
  def sanitize_input(input)
    ActiveRecord::Base.connection.quote_string(input.to_s)
  end

  # Serializes the changes hash to JSON with proper error handling
  #
  # @param changes [Hash] The changes to serialize
  # @return [String] JSON-serialized changes
  def serialize_changes(changes)
    changes.to_json
  rescue JSON::GeneratorError => e
    logger.error("Failed to serialize changes: #{e.message}")
    '{}'
  end

  # Executes optimized SQL insert for audit log creation
  #
  # @param params [Hash] Parameters for audit log creation
  def execute_audit_log_creation(params)
    sql = <<-SQL
      INSERT INTO audit_logs (
        action, resource_type, resource_id, changes, 
        user_id, ip_address, created_at, updated_at
      ) VALUES (
        '#{params[:action]}', '#{params[:resource_type]}', #{params[:resource_id]},
        '#{params[:changes]}', #{params[:user_id]}, '#{params[:ip_address]}',
        '#{params[:created_at]}', '#{params[:created_at]}'
      )
    SQL
    
    ActiveRecord::Base.connection.execute(sql)
  end

  # Handles errors during audit log creation with proper logging and monitoring
  #
  # @param error [StandardError] The error to handle
  def handle_error(error)
    logger.error("Audit log creation failed: #{error.message}")
    logger.error(error.backtrace.join("\n"))
    
    # Report error to monitoring system
    report_error(
      error,
      component: 'AuditLogJob',
      operation: 'perform',
      severity: 'error'
    )
  end

  # Reports errors to the configured error tracking system
  #
  # @param error [StandardError] The error to report
  # @param context [Hash] Additional context for the error
  def report_error(error, context = {})
    # Implementation would integrate with configured error tracking service
    Rails.error.report(error, context)
  end
end