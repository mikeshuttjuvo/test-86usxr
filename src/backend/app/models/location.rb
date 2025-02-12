# frozen_string_literal: true

# Represents a location entity with enhanced geocoding capabilities, optimized caching,
# and comprehensive audit logging functionality.
#
# @version 1.0.0
# @see Technical Specifications/3.2.1/Schema Design
class Location < ApplicationRecord
  # Include required modules for enhanced functionality
  include Auditable
  include Cacheable
  include SoftDeletable
  include Geocoder::Model::ActiveRecord

  # Geocoding configuration
  geocoded_by :address
  after_validation :geocode_async, if: ->(obj) { obj.address_changed? && obj.address.present? }

  # Attributes
  attribute :name, :string
  attribute :address, :string
  attribute :latitude, :decimal, precision: 10, scale: 6
  attribute :longitude, :decimal, precision: 10, scale: 6
  attribute :active, :boolean, default: true
  attribute :geocoding_status, :string, default: 'pending'
  attribute :geocoding_metadata, :json, default: {}

  # Validations
  validates :name, presence: true, length: { maximum: 255 }
  validates :address, presence: true, length: { maximum: 1000 }
  validates :latitude, numericality: { greater_than_or_equal_to: -90, less_than_or_equal_to: 90 }, allow_nil: true
  validates :longitude, numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }, allow_nil: true
  validates :geocoding_status, inclusion: { in: %w[pending processing completed failed] }

  # Scopes
  scope :geocoded, -> { where.not(latitude: nil, longitude: nil) }
  scope :pending_geocoding, -> { where(geocoding_status: 'pending') }
  scope :failed_geocoding, -> { where(geocoding_status: 'failed') }

  # Cache configuration
  caches_with ttl: 1.hour, version: 1

  # Callbacks
  before_save :update_geocoding_metadata
  after_commit :invalidate_nearby_cache, if: :coordinates_changed?

  # Class methods
  class << self
    # Finds locations within specified radius using optimized spatial query
    # @param latitude [Float] Center point latitude
    # @param longitude [Float] Center point longitude
    # @param radius_km [Float] Search radius in kilometers
    # @param options [Hash] Additional search options
    # @return [ActiveRecord::Relation] Collection of nearby locations
    def nearby(latitude:, longitude:, radius_km:, options: {})
      cache_key = generate_nearby_cache_key(latitude, longitude, radius_km, options)

      Rails.cache.fetch(cache_key, expires_in: 1.hour) do
        geocoded
          .within(radius_km, origin: [latitude, longitude])
          .where(active: true)
          .limit(options[:limit] || 100)
          .order(options[:order] || 'distance ASC')
      end
    end

    private

    def generate_nearby_cache_key(latitude, longitude, radius_km, options)
      components = [
        'locations',
        'nearby',
        latitude.round(4),
        longitude.round(4),
        radius_km,
        options.to_s
      ]
      Digest::SHA256.hexdigest(components.join(':'))
    end
  end

  # Instance methods

  # Asynchronously updates latitude and longitude based on address
  # @return [Boolean] Success of geocoding job enqueue
  def geocode_async
    return false unless address_changed? && address.present?

    self.geocoding_status = 'processing'
    self.geocoding_metadata = geocoding_metadata.merge(
      last_attempt: Time.current.iso8601,
      attempts: (geocoding_metadata['attempts'] || 0) + 1
    )

    LocationGeocodingJob.perform_later(id)
    true
  rescue StandardError => e
    Rails.logger.error("Failed to enqueue geocoding job: #{e.message}")
    false
  end

  # Updates location coordinates with validation and cache invalidation
  # @param new_latitude [Decimal] New latitude value
  # @param new_longitude [Decimal] New longitude value
  # @return [Boolean] Success of update operation
  def update_coordinates(new_latitude, new_longitude)
    return false unless valid_coordinates?(new_latitude, new_longitude)

    transaction do
      self.latitude = new_latitude
      self.longitude = new_longitude
      self.geocoding_status = 'completed'
      self.geocoding_metadata = geocoding_metadata.merge(
        updated_at: Time.current.iso8601,
        source: 'manual_update'
      )

      save
    end
  end

  # Returns location coordinates as array
  # @return [Array<Float>] Array containing latitude and longitude
  def coordinates
    return nil unless latitude && longitude
    [latitude.to_f, longitude.to_f]
  end

  private

  def coordinates_changed?
    saved_changes.key?('latitude') || saved_changes.key?('longitude')
  end

  def valid_coordinates?(lat, lng)
    lat.present? && lng.present? &&
      lat.to_f.between?(-90, 90) &&
      lng.to_f.between?(-180, 180)
  end

  def update_geocoding_metadata
    return unless coordinates_changed? || address_changed?

    self.geocoding_metadata = geocoding_metadata.merge(
      last_updated: Time.current.iso8601,
      address_hash: Digest::SHA256.hexdigest(address.to_s)
    )
  end

  def invalidate_nearby_cache
    Rails.cache.delete_matched("locations:nearby:*")
  end
end