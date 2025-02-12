# frozen_string_literal: true

require 'active_support'

# Service object responsible for handling job status updates with validation,
# audit logging, and cache management. Implements comprehensive status transition
# rules and transaction management while maintaining data integrity.
#
# @version 1.0.0
# @see Technical Specifications/1.3/Core Features/Job Management
class StatusUpdateService < ApplicationService
  include NewRelic::Agent::Instrumentation::ControllerInstrumentation

  # Status transition rules defining allowed state changes
  ALLOWED_TRANSITIONS = {
    'pending' => %w[active cancelled],
    'active' => %w[completed cancelled],
    'completed' => [],
    'cancelled' => []
  }.freeze

  # @return [Job] The job being updated
  attr_reader :job

  # @return [String] The new status to be applied
  attr_reader :new_status

  # @return [Hash] Context information for the update
  attr_reader :context

  # Initializes the service with required parameters
  #
  # @param job [Job] The job to update
  # @param new_status [String] The target status
  # @param context [Hash] Additional context for the update
  def initialize(job:, new_status:, context: {})
    super()
    @job = job
    @new_status = new_status.to_s.downcase
    @context = context.to_h
    
    # Set up NewRelic custom attributes
    ::NewRelic::Agent.add_custom_attributes({
      job_id: job&.id,
      old_status: job&.status,
      new_status: new_status,
      user_id: context[:user_id]
    })
  end

  private

  # Performs the status update operation with validation and error handling
  #
  # @return [Boolean] Success status of the operation
  def perform
    return false unless validate_job && validate_status_transition

    transaction_with_retry do
      update_job_status
      create_audit_log
      invalidate_caches
    end

    @success = true
  rescue StandardError => e
    handle_error(e)
    @success = false
  end

  # Validates the job exists and is accessible
  #
  # @return [Boolean] Whether the job is valid for update
  def validate_job
    return add_error('Job not found') if job.nil?
    return add_error('Job is not active') unless job.active?
    
    # Check user permissions if context includes user
    if context[:user_id].present?
      return add_error('Unauthorized access') unless authorized_for_update?
    end

    true
  end

  # Validates the requested status transition is allowed
  #
  # @return [Boolean] Whether the status transition is valid
  def validate_status_transition
    return add_error('Invalid status') unless Job::VALID_STATUSES.include?(new_status)
    
    allowed_transitions = ALLOWED_TRANSITIONS[job.status]
    unless allowed_transitions&.include?(new_status)
      return add_error("Cannot transition from #{job.status} to #{new_status}")
    end

    true
  end

  # Updates the job status within a transaction
  #
  # @return [Boolean] Success of the update operation
  def update_job_status
    job.with_lock do
      unless job.update_status(new_status)
        raise ActiveRecord::RecordInvalid.new(job)
      end
      true
    end
  end

  # Creates a detailed audit log entry for the status change
  #
  # @return [void]
  def create_audit_log
    AuditLogJob.perform_later(
      action: 'status_update',
      resource_type: 'Job',
      resource_id: job.id,
      changes: {
        status: {
          from: job.status_was,
          to: new_status
        }
      },
      user_id: context[:user_id],
      ip_address: context[:ip_address],
      metadata: {
        reason: context[:reason],
        source: context[:source],
        correlation_id: context[:correlation_id]
      }
    )
  end

  # Invalidates related caches after status update
  #
  # @return [void]
  def invalidate_caches
    REDIS_CACHE_POOL.with do |redis|
      # Invalidate job-specific caches
      job.invalidate_cache
      
      # Invalidate associated location caches
      job.location&.invalidate_cache
      
      # Invalidate any list caches that might include this job
      redis.del("jobs:status:#{job.status_was}")
      redis.del("jobs:status:#{new_status}")
      redis.del("jobs:location:#{job.location_id}")
    end
  end

  # Checks if the current user is authorized for the update
  #
  # @return [Boolean] Whether the user is authorized
  def authorized_for_update?
    # Implementation would depend on authorization system
    # For now, assume any user with a user_id can update
    context[:user_id].present?
  end

  # Adds an error message to the service
  #
  # @param message [String] The error message
  # @return [Boolean] Always returns false
  def add_error(message)
    @errors << {
      type: 'status_update_error',
      message: message,
      job_id: job&.id,
      attempted_status: new_status
    }
    false
  end

  # Handles errors during the status update process
  #
  # @param error [StandardError] The error that occurred
  def handle_error(error)
    Rails.logger.error("Job status update failed: #{error.message}")
    
    NewRelic::Agent.notice_error(error, custom_params: {
      job_id: job&.id,
      old_status: job&.status_was,
      new_status: new_status,
      error_type: error.class.name
    })
    
    add_error(error.message)
  end

  # Add NewRelic transaction tracing
  add_transaction_tracer :perform, category: :task
end