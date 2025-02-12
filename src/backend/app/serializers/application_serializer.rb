# frozen_string_literal: true

# active_model_serializers ~> 0.10.0
require 'active_model_serializers'

class ApplicationSerializer < ActiveModel::Serializer
  # Cache configuration for Redis with 1-hour TTL
  caches_options expires_in: 1.hour,
                 race_condition_ttl: 10.seconds,
                 compress: true

  # Default timestamp attributes that can be toggled via options
  attributes :created_at, :updated_at, if: :include_timestamps?

  # Initialize with additional configuration for sensitive data handling
  def initialize(object, options = {})
    super
    @sensitive_patterns = Rails.configuration.sensitive_data_patterns
  end

  # Generates a unique cache key for model serialization
  # @return [String] Cache key combining model info and version
  def cache_key
    model = object.class
    version = self.class::VERSION || '1'
    
    key_components = [
      model.name.underscore,
      object.id,
      object.updated_at.utc.to_s(:nsec),
      version
    ]
    
    Digest::SHA256.hexdigest(key_components.join('-'))
  end

  # Determines if timestamps should be included in serialized output
  # @return [Boolean] Whether to include created_at and updated_at
  def include_timestamps?
    instance_options.fetch(:include_timestamps, true)
  end

  # Provides Redis caching configuration
  # @return [Hash] Cache configuration including TTL and namespace
  def cache_options
    {
      expires_in: 1.hour,
      namespace: object.class.name,
      version: self.class::VERSION || '1',
      race_condition_ttl: 10.seconds,
      compress: true,
      cache_nils: false
    }
  end

  protected

  # Applies data masking to sensitive fields
  # @param attributes [Hash] Raw attribute hash
  # @return [Hash] Attributes with sensitive data masked
  def mask_sensitive_data(attributes)
    return attributes unless @sensitive_patterns

    @sensitive_patterns.each do |pattern, mask_config|
      attributes.each do |key, value|
        next unless key.to_s.match?(pattern)
        next unless value.is_a?(String)

        # Apply masking while preserving configured number of characters
        prefix_length = mask_config[:prefix_length] || 0
        suffix_length = mask_config[:suffix_length] || 0
        mask_char = mask_config[:mask_char] || '*'

        if value.length > (prefix_length + suffix_length)
          masked_portion = mask_char * (value.length - prefix_length - suffix_length)
          attributes[key] = value[0...prefix_length] + masked_portion + value[-suffix_length..-1]
        end
      end
    end

    attributes
  end

  private

  # Hook method called before serialization to apply masking
  def serializable_hash(adapter_options = nil, options = {}, adapter_instance = self.class.serialization_adapter_instance)
    hash = super
    mask_sensitive_data(hash)
  end

  # Ensure proper cache key generation for collections
  def self.cache_key_for_collection(collection_key, collection_serializer)
    "#{collection_serializer.object.model.name.underscore}/collection/#{collection_key}"
  end

  # Set up default caching behavior
  def self.cache_enabled?
    Rails.configuration.action_controller.perform_caching
  end
end