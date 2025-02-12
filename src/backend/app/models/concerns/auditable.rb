# frozen_string_literal: true

require 'active_support/concern'
require 'active_record/base'

# Provides comprehensive audit logging functionality to ActiveRecord models with secure
# change tracking, asynchronous processing, and optimized audit trail retrieval.
#
# @version 1.0.0
# @see Technical Specifications/7.2/Data Security/Data Protection Measures
# @see Technical Specifications/7.3.4/Compliance Requirements
module Auditable
  extend ActiveSupport::Concern

  # Current version of the auditing implementation
  AUDIT_VERSION = '1.0.0'

  # Fields that require special handling for security/privacy
  SENSITIVE_FIELDS = %w[
    password
    password_digest
    token
    secret
    credit_card
    ssn
    tax_id
  ].freeze

  included do
    # Set up callbacks with transaction safety
    after_create_commit :audit_create
    after_update_commit :audit_update
    after_destroy_commit :audit_destroy

    # Cache configuration for audit logs
    class_attribute :audit_cache_enabled, default: true
    class_attribute :audit_cache_ttl, default: 1.hour
    class_attribute :custom_sensitive_fields, default: []
  end

  class_methods do
    # Configure sensitive fields for the model
    # @param fields [Array<String>] Additional sensitive fields to mask
    def audit_sensitive_fields(*fields)
      self.custom_sensitive_fields = fields.map(&:to_s)
    end

    # Configure audit caching behavior
    # @param enabled [Boolean] Whether to enable caching
    # @param ttl [ActiveSupport::Duration] Cache TTL
    def configure_audit_cache(enabled: true, ttl: 1.hour)
      self.audit_cache_enabled = enabled
      self.audit_cache_ttl = ttl
    end
  end

  # Records audit log for model creation
  # @return [Boolean] Success status of audit creation
  def audit_create
    enqueue_audit_job(
      action: 'create',
      changes: sanitize_attributes(attributes),
      resource_id: id,
      resource_type: self.class.name
    )
  end

  # Records audit log for model updates
  # @return [Boolean] Success status of audit creation
  def audit_update
    return true if changes.empty?

    enqueue_audit_job(
      action: 'update',
      changes: sanitize_attributes(changes),
      resource_id: id,
      resource_type: self.class.name
    )
  end

  # Records audit log for model deletion
  # @return [Boolean] Success status of audit creation
  def audit_destroy
    enqueue_audit_job(
      action: 'destroy',
      changes: sanitize_attributes(attributes),
      resource_id: id,
      resource_type: self.class.name
    )
  end

  # Retrieves audit logs for the model instance with caching and pagination
  # @param options [Hash] Query options including pagination and filters
  # @return [Array<AuditLog>] Collection of audit logs
  def audit_logs(options = {})
    cache_key = audit_cache_key(options)
    
    if audit_cache_enabled && (cached = Rails.cache.read(cache_key))
      return cached
    end

    logs = fetch_audit_logs(options)
    
    if audit_cache_enabled
      Rails.cache.write(cache_key, logs, expires_in: audit_cache_ttl)
    end
    
    logs
  end

  private

  # Enqueues an audit log job with error handling
  # @param attributes [Hash] Audit log attributes
  # @return [Boolean] Success status
  def enqueue_audit_job(attributes)
    AuditLogJob.perform_later(
      action: attributes[:action],
      resource_type: attributes[:resource_type],
      resource_id: attributes[:resource_id],
      changes: attributes[:changes],
      user_id: try(:current_user_id) || try(:user_id),
      ip_address: try(:current_ip_address) || '0.0.0.0'
    )
    true
  rescue StandardError => e
    Rails.logger.error("Failed to create audit log: #{e.message}")
    report_audit_error(e, attributes)
    false
  end

  # Sanitizes attributes by masking sensitive data
  # @param attrs [Hash] Attributes to sanitize
  # @return [Hash] Sanitized attributes
  def sanitize_attributes(attrs)
    attrs.deep_dup.tap do |safe_attrs|
      sensitive_fields.each do |field|
        safe_attrs[field] = '[REDACTED]' if safe_attrs.key?(field)
      end
    end
  end

  # Combines default and custom sensitive fields
  # @return [Array<String>] Complete list of sensitive fields
  def sensitive_fields
    SENSITIVE_FIELDS | custom_sensitive_fields
  end

  # Generates a cache key for audit logs
  # @param options [Hash] Query options
  # @return [String] Cache key
  def audit_cache_key(options)
    components = [
      self.class.name,
      id,
      'audit_logs',
      options.to_s,
      AUDIT_VERSION
    ]
    
    Digest::SHA256.hexdigest(components.join('-'))
  end

  # Fetches audit logs with optimized querying
  # @param options [Hash] Query options
  # @return [Array<AuditLog>] Collection of audit logs
  def fetch_audit_logs(options)
    page = options.fetch(:page, 1)
    per_page = options.fetch(:per_page, 25)
    
    base_query = <<-SQL
      SELECT * FROM audit_logs
      WHERE resource_type = ? AND resource_id = ?
      ORDER BY created_at DESC
      LIMIT ? OFFSET ?
    SQL
    
    binds = [
      self.class.name,
      id,
      per_page,
      (page - 1) * per_page
    ]
    
    ActiveRecord::Base.connection.execute(
      sanitize_sql_array([base_query, *binds])
    )
  end

  # Reports audit-related errors to monitoring system
  # @param error [StandardError] The error that occurred
  # @param context [Hash] Additional error context
  def report_audit_error(error, context)
    Rails.error.report(
      error,
      component: 'Auditable',
      operation: context[:action],
      resource_type: context[:resource_type],
      resource_id: context[:resource_id]
    )
  end

  # Sanitizes SQL queries with proper escaping
  # @param query [Array] Query and binds
  # @return [String] Sanitized query
  def sanitize_sql_array(query)
    ActiveRecord::Base.send(:sanitize_sql_array, query)
  end
end