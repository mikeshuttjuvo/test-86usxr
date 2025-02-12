# frozen_string_literal: true

class LocationSerializer < ApplicationSerializer
  # Current version for cache key generation
  VERSION = '1.0.0'

  # Define attributes to be serialized
  attributes :id, :name, :address, :latitude, :longitude, :active

  # Define association
  has_many :jobs, if: :include_jobs?

  # Cache configuration with Redis
  caches_options expires_in: 1.hour,
                 race_condition_ttl: 10.seconds,
                 compress: true

  # Initialize with custom configuration
  def initialize(object, options = {})
    super
    @permission_level = options[:permission_level] || :basic
    @masking_patterns = {
      address: { prefix_length: 3, suffix_length: 0, mask_char: '*' }
    }
    setup_geolocation_precision
  end

  # Override attributes method to implement permission-based filtering
  def attributes(*args)
    attrs = super
    filtered_attrs = case @permission_level
                    when :admin
                      attrs
                    when :manager
                      attrs.except(:created_at, :updated_at)
                    else
                      attrs.except(:created_at, :updated_at)
                           .merge(mask_address(attrs[:address]))
                           .merge(round_coordinates(attrs))
                    end

    mask_sensitive_data(filtered_attrs)
  end

  # Custom cache key generation incorporating permissions and context
  def cache_key
    base_key = super
    permission_component = Digest::SHA256.hexdigest(@permission_level.to_s)
    "#{base_key}/#{permission_component}/#{geo_precision_level}"
  end

  # Optimized job serialization with batch loading
  def jobs
    return [] unless include_jobs?

    @jobs ||= begin
      jobs = object.jobs.includes(:location) # Eager loading
      ActiveModel::Serializer::CollectionSerializer.new(
        jobs,
        serializer: JobSerializer,
        permission_level: @permission_level,
        include_timestamps: include_timestamps?
      )
    end
  end

  private

  def setup_geolocation_precision
    @geo_precision = case @permission_level
                    when :admin
                      8  # Full precision
                    when :manager
                      6  # ~10m precision
                    else
                      4  # ~100m precision
                    end
  end

  def round_coordinates(attrs)
    return attrs unless attrs[:latitude] && attrs[:longitude]

    {
      latitude: attrs[:latitude].round(@geo_precision),
      longitude: attrs[:longitude].round(@geo_precision)
    }
  end

  def mask_address(address)
    return {} unless address

    masked = if @permission_level == :basic
              apply_address_masking(address)
            else
              address
            end

    { address: masked }
  end

  def apply_address_masking(address)
    pattern = @masking_patterns[:address]
    prefix = address[0...pattern[:prefix_length]]
    mask = pattern[:mask_char] * (address.length - pattern[:prefix_length])
    "#{prefix}#{mask}"
  end

  def include_jobs?
    @instance_options[:include]&.include?(:jobs)
  end

  def geo_precision_level
    Digest::SHA256.hexdigest(@geo_precision.to_s)
  end

  # Audit logging for sensitive data access
  def log_sensitive_access
    return unless Rails.configuration.enable_audit_logging

    Rails.logger.info(
      {
        event: 'sensitive_data_access',
        model: 'Location',
        id: object.id,
        permission_level: @permission_level,
        accessed_at: Time.current.iso8601(6)
      }.to_json
    )
  end

  # Cache warming strategy
  def self.warm_cache(location)
    [:basic, :manager, :admin].each do |permission_level|
      Rails.cache.fetch(
        "locations/#{location.id}/#{permission_level}",
        expires_in: 1.hour
      ) do
        new(location, permission_level: permission_level).to_json
      end
    end
  end
end