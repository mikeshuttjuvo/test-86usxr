# frozen_string_literal: true

# Represents a job entity in the system with comprehensive status management,
# validation, caching, and audit logging capabilities.
#
# @version 1.0.0
# @see Technical Specifications/3.2.1/Schema Design
class Job < ApplicationRecord
  # Include shared functionality
  include Auditable
  include Cacheable
  include SoftDeletable

  # Constants for status management
  VALID_STATUSES = %w[pending active completed cancelled].freeze
  MAX_TITLE_LENGTH = 255
  MAX_DESCRIPTION_LENGTH = 5000
  MIN_DATE_RANGE = 1.hour
  MAX_DATE_RANGE = 1.year

  # Attributes
  attribute :title, :string
  attribute :description, :text
  attribute :status, :string, default: 'pending'
  attribute :start_date, :datetime
  attribute :end_date, :datetime
  attribute :active, :boolean, default: true
  attribute :deleted_at, :datetime

  # Associations
  belongs_to :location, optional: false

  # Validations
  validates :title, presence: true, length: { maximum: MAX_TITLE_LENGTH }
  validates :description, presence: true, length: { maximum: MAX_DESCRIPTION_LENGTH }
  validates :status, presence: true, inclusion: { in: VALID_STATUSES }
  validates :start_date, :end_date, presence: true
  validate :validate_dates
  validate :validate_status_transition, on: :update

  # Callbacks
  before_validation :set_default_status, on: :create
  after_commit :invalidate_associated_caches, on: [:create, :update, :destroy]
  after_touch :invalidate_associated_caches

  # Scopes
  scope :active_jobs, -> { where(status: 'active') }
  scope :completed_jobs, -> { where(status: 'completed') }
  scope :upcoming_jobs, -> { where('start_date > ?', Time.current) }
  scope :by_location, ->(location_id) { where(location_id: location_id) }
  scope :date_range, ->(start_date, end_date) {
    where('start_date >= ? AND end_date <= ?', start_date, end_date)
  }

  # Configure caching options
  caches_with ttl: 1.hour, version: '1.0'

  # Updates job status with validation and audit logging
  #
  # @param new_status [String] The new status to set
  # @return [Boolean] Success of the status update operation
  def update_status(new_status)
    return false unless VALID_STATUSES.include?(new_status)
    
    transaction do
      self.status = new_status
      
      if save
        audit_update
        invalidate_cache
        true
      else
        false
      end
    end
  rescue StandardError => e
    Rails.logger.error("Failed to update job status: #{e.message}")
    false
  end

  # Custom cache key generation including status and dates
  #
  # @param options [Hash] Additional options for cache key generation
  # @return [String] Cache key for the job
  def cache_key(options = {})
    components = [
      super,
      status,
      start_date&.to_i,
      end_date&.to_i,
      location_id
    ]
    
    components.join(':')
  end

  private

  # Validates date constraints for the job
  def validate_dates
    return if start_date.blank? || end_date.blank?

    if start_date < Time.current
      errors.add(:start_date, 'cannot be in the past')
    end

    if end_date <= start_date
      errors.add(:end_date, 'must be after start date')
    end

    date_range = end_date - start_date
    if date_range < MIN_DATE_RANGE
      errors.add(:base, 'Job duration must be at least 1 hour')
    end

    if date_range > MAX_DATE_RANGE
      errors.add(:base, 'Job duration cannot exceed 1 year')
    end
  end

  # Validates status transitions
  def validate_status_transition
    return unless status_changed?
    
    old_status, new_status = status_change
    allowed_transitions = {
      'pending' => %w[active cancelled],
      'active' => %w[completed cancelled],
      'completed' => [],
      'cancelled' => []
    }

    unless allowed_transitions[old_status]&.include?(new_status)
      errors.add(:status, "cannot transition from #{old_status} to #{new_status}")
    end
  end

  # Sets the default status for new jobs
  def set_default_status
    self.status ||= 'pending'
  end

  # Invalidates associated caches
  def invalidate_associated_caches
    Rails.cache.delete_matched("#{cache_key}*")
    location&.invalidate_cache
  end
end