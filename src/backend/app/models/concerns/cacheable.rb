# frozen_string_literal: true

require 'active_support/concern'
require 'zlib'

# Provides Redis-based caching functionality for ActiveRecord models with automatic
# cache invalidation, compression, monitoring and distributed cache support.
#
# @version 1.0.0
# @since 7.0.0
module Cacheable
  extend ActiveSupport::Concern

  # Default TTL for cached entries (1 hour)
  DEFAULT_TTL = 3600

  # Current cache version for key namespacing
  CACHE_VERSION = '1'

  # Threshold in bytes for compression (1KB)
  COMPRESSION_THRESHOLD = 1024

  # Global cache namespace
  CACHE_NAMESPACE = 'app:cache'

  included do
    after_commit :invalidate_model_cache, on: [:update, :destroy]
    after_touch :invalidate_model_cache

    class_attribute :cache_options, default: {}
  end

  class_methods do
    # Configure caching options for the model
    # @param opts [Hash] caching options
    def caches_with(opts = {})
      self.cache_options = opts
    end
  end

  # Generates a versioned cache key for the model instance
  #
  # @param namespace [String] optional namespace override
  # @param options [Hash] additional key generation options
  # @return [String] namespaced and versioned cache key
  def cache_key(namespace = nil, options = {})
    components = []
    components << (namespace || CACHE_NAMESPACE)
    components << self.class.table_name
    components << id
    components << CACHE_VERSION
    
    if respond_to?(:updated_at) && updated_at
      components << updated_at.utc.to_s(:nsec)
    end

    if options[:include_associations]
      belongs_to_associations = self.class.reflect_on_all_associations(:belongs_to)
      association_keys = belongs_to_associations.map do |assoc|
        if (associated = send(assoc.name))
          "#{assoc.name}:#{associated.cache_key}"
        end
      end.compact
      components.concat(association_keys)
    end

    components.join(':')
  end

  # Fetches data from cache with compression support
  #
  # @param key [String] cache key
  # @param options [Hash] caching options
  # @return [Object] cached data or block result
  def cache_fetch(key, options = {})
    full_key = cache_key(options[:namespace])
    ttl = options[:ttl] || self.class.cache_options[:ttl] || DEFAULT_TTL

    REDIS_CACHE_POOL.with do |redis|
      begin
        if cached_data = redis.get(full_key)
          update_cache_metrics(:hit)
          decompress_if_needed(cached_data)
        else
          update_cache_metrics(:miss)
          result = yield if block_given?
          
          if should_compress?(result)
            compressed_result = compress(result)
            redis.setex(full_key, ttl, compressed_result)
          else
            redis.setex(full_key, ttl, result)
          end
          
          result
        end
      rescue Redis::BaseError => e
        Rails.logger.error("Cache operation failed for key #{full_key}: #{e.message}")
        update_cache_metrics(:error)
        yield if block_given?
      end
    end
  end

  # Invalidates cached data with pattern support
  #
  # @param pattern [String] optional key pattern to invalidate
  # @param options [Hash] invalidation options
  # @return [Boolean] true if cache was invalidated
  def invalidate_cache(pattern = nil, options = {})
    REDIS_CACHE_POOL.with do |redis|
      begin
        keys_to_delete = if pattern
          redis.keys("#{CACHE_NAMESPACE}:#{pattern}")
        else
          [cache_key]
        end

        if options[:cascade] && respond_to?(:associated_models)
          associated_models.each do |model|
            keys_to_delete << model.cache_key
          end
        end

        return true if keys_to_delete.empty?

        if keys_to_delete.size > 1000 && options[:async]
          CacheInvalidationJob.perform_later(keys_to_delete)
          true
        else
          redis.del(*keys_to_delete) > 0
        end
      rescue Redis::BaseError => e
        Rails.logger.error("Cache invalidation failed: #{e.message}")
        false
      end
    end
  end

  private

  def invalidate_model_cache
    invalidate_cache
  end

  def should_compress?(data)
    return false unless data.is_a?(String)
    data.bytesize >= COMPRESSION_THRESHOLD
  end

  def compress(data)
    return data unless data.is_a?(String)
    compressed = Zlib::Deflate.deflate(data)
    "compressed:#{compressed}"
  end

  def decompress_if_needed(data)
    return data unless data.is_a?(String) && data.start_with?('compressed:')
    Zlib::Inflate.inflate(data.sub('compressed:', ''))
  end

  def update_cache_metrics(type)
    return unless Rails.application.config.cache_metrics_enabled
    
    metric_key = "cache_metrics:#{self.class.name}:#{type}"
    REDIS_CACHE_POOL.with do |redis|
      redis.hincrby(metric_key, Date.today.to_s, 1)
    end
  rescue Redis::BaseError => e
    Rails.logger.warn("Failed to update cache metrics: #{e.message}")
  end
end