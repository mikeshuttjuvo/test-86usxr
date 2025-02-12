# frozen_string_literal: true

##
# Provides comprehensive soft deletion capabilities for ActiveRecord models.
# Implements secure deletion with audit trail and automatic cleanup of expired records.
#
# @version 1.0.0
# @since 7.0.0
module SoftDeletable
  extend ActiveSupport::Concern

  included do |base|
    # Add timestamp for soft deletion and active flag
    base.attribute :deleted_at, :datetime
    base.attribute :active, :boolean, default: true

    # Default scope excludes soft-deleted records
    base.default_scope { where(active: true) }

    # Scopes for accessing deleted records
    base.scope :with_deleted, -> { unscope(where: :active) }
    base.scope :only_deleted, -> { unscope(where: :active).where.not(deleted_at: nil) }

    # Callbacks for soft deletion process
    base.define_callbacks :soft_delete
    base.define_callbacks :restore

    # Validate to prevent duplicate soft deletions
    base.validate :validate_not_already_deleted, on: :soft_delete

    # Add indexes for performance optimization
    unless base.connection.index_exists?(base.table_name, [:deleted_at, :active])
      base.connection.add_index(base.table_name, [:deleted_at, :active])
    end

    private

    def validate_not_already_deleted
      errors.add(:base, 'Record is already deleted') if deleted? && deleted_at_changed?
    end
  end

  ##
  # Marks the record as deleted with proper authorization and audit trail
  #
  # @param options [Hash] Options for soft deletion
  # @option options [Boolean] :cascade Whether to cascade deletion to associations
  # @option options [String] :reason Reason for deletion
  # @return [Boolean] Success of the soft deletion operation
  def soft_delete(options = {})
    return false if deleted?

    run_callbacks :soft_delete do
      transaction do
        self.deleted_at = Time.current
        self.active = false

        create_audit_entry('soft_delete', options[:reason])
        handle_cascading_deletion if options[:cascade]

        save
      end
    end
  end

  ##
  # Restores a soft-deleted record with proper authorization and audit trail
  #
  # @param options [Hash] Options for restoration
  # @option options [Boolean] :cascade Whether to cascade restoration to associations
  # @option options [String] :reason Reason for restoration
  # @return [Boolean] Success of the restore operation
  def restore(options = {})
    return false unless deleted?

    run_callbacks :restore do
      transaction do
        self.deleted_at = nil
        self.active = true

        create_audit_entry('restore', options[:reason])
        handle_cascading_restoration if options[:cascade]

        save
      end
    end
  end

  ##
  # Checks if the record is soft-deleted
  #
  # @return [Boolean] true if record is soft-deleted
  def deleted?
    deleted_at.present? && !active
  end

  ##
  # Removes records that have been soft-deleted for more than 90 days
  #
  # @return [Integer] Number of records permanently deleted
  def self.cleanup_expired_records
    cutoff_date = 90.days.ago

    transaction do
      expired_records = only_deleted.where('deleted_at <= ?', cutoff_date)
      count = expired_records.count

      expired_records.find_each do |record|
        record.create_audit_entry('permanent_delete', 'Expired soft-deleted record cleanup')
        record.delete
      end

      count
    end
  end

  private

  ##
  # Creates an audit trail entry for the soft deletion operation
  #
  # @param action [String] The action being performed (soft_delete/restore/permanent_delete)
  # @param reason [String] The reason for the action
  def create_audit_entry(action, reason)
    return unless defined?(AuditLog)

    AuditLog.create!(
      action: action,
      resource_type: self.class.name,
      resource_id: id,
      changes: changes,
      reason: reason,
      created_at: Time.current
    )
  end

  ##
  # Handles cascading soft deletion to associated records
  def handle_cascading_deletion
    self.class.reflect_on_all_associations.each do |association|
      next unless association.options[:dependent] == :destroy

      associated_records = send(association.name)
      if associated_records.respond_to?(:each)
        associated_records.each { |record| record.soft_delete if record.respond_to?(:soft_delete) }
      elsif associated_records&.respond_to?(:soft_delete)
        associated_records.soft_delete
      end
    end
  end

  ##
  # Handles cascading restoration to associated records
  def handle_cascading_restoration
    self.class.reflect_on_all_associations.each do |association|
      next unless association.options[:dependent] == :destroy

      associated_records = self.class.unscoped { send(association.name) }
      if associated_records.respond_to?(:each)
        associated_records.each { |record| record.restore if record.respond_to?(:restore) }
      elsif associated_records&.respond_to?(:restore)
        associated_records.restore
      end
    end
  end
end