# active_model_serializers ~> 0.10.0
# rails ~> 7.0.0

# Configure ActiveModel::Serializers for standardized JSON:API serialization
# with Redis caching, security controls, and performance optimizations

require 'active_model_serializers'

# Configure JSON:API format settings
ActiveModelSerializers.config.adapter = :json_api
ActiveModelSerializers.config.key_transform = :camel_lower
ActiveModelSerializers.config.jsonapi_resource_type = :singular
ActiveModelSerializers.config.jsonapi_namespace = 'Api::V1'
ActiveModelSerializers.config.jsonapi_include_toplevel_object = true
ActiveModelSerializers.config.jsonapi_pagination_links_enabled = true

# Configure default includes and data settings
ActiveModelSerializers.config.include_data_default = false
ActiveModelSerializers.config.default_includes = []

# Configure caching with Redis and performance optimizations
ActiveModelSerializers.config.cache_store = Rails.cache
ActiveModelSerializers.config.perform_caching = Rails.env.production?
ActiveModelSerializers.config.cache_key_prefix = 'api/v1'

# Configure cache options with race condition prevention
ActiveModelSerializers.config.cache_options = {
  expires_in: 1.hour,
  race_condition_ttl: 10.seconds,
  compress: true,
  namespace: "ams:#{Rails.env}"
}

# Configure versioned cache key generation
ActiveModelSerializers.config.cache_key_format = Proc.new do |serializer|
  [
    serializer.object_id,
    serializer.cache_timestamp,
    serializer.class.name,
    'v1',
    Rails.env
  ].join('/')
end

# Configure error serialization format according to RFC 7807
ActiveModel::Serializer.config.error_serializer = ActiveModel::Serializer::ErrorSerializer

# Set up monitoring hooks for cache operations
if Rails.env.production?
  ActiveSupport::Notifications.subscribe('cache_read.active_model_serializers') do |*args|
    event = ActiveSupport::Notifications::Event.new(*args)
    # Log cache read metrics
    Rails.logger.info(
      "AMS Cache Read: #{event.duration}ms - #{event.payload[:key]}"
    )
  end

  ActiveSupport::Notifications.subscribe('cache_write.active_model_serializers') do |*args|
    event = ActiveSupport::Notifications::Event.new(*args)
    # Log cache write metrics
    Rails.logger.info(
      "AMS Cache Write: #{event.duration}ms - #{event.payload[:key]}"
    )
  end
end

# Configure serialization context for request-specific data
ActiveModelSerializers.config.serialization_context = ->(request) {
  ActiveModelSerializers::SerializationContext.new(
    request,
    namespace: 'Api::V1',
    url_helpers: Rails.application.routes.url_helpers
  )
}

# Configure JSON:API content type and format handlers
Mime::Type.register 'application/vnd.api+json', :json_api
ActionController::Renderers.add :json_api do |obj, options|
  self.content_type = Mime[:json_api]
  self.response_body = obj.to_json(options)
end

# Configure sensitive data filtering in serialization
ActiveModelSerializers.config.filter_parameters = Rails.application.config.filter_parameters