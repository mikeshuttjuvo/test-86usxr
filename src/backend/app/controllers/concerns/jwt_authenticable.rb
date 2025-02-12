# frozen_string_literal: true

require 'active_support/concern'
require 'redis'

# Provides JWT-based authentication functionality for API controllers with enhanced
# security controls, performance optimizations, and comprehensive error handling.
#
# @version 1.0.0
# @see Technical Specifications/7.1/Authentication Flow
module JWTAuthenticable
  extend ActiveSupport::Concern
  include Authenticable

  # Constants for configuration
  TOKEN_CACHE_TTL = 1.hour
  USER_CACHE_TTL = 15.minutes
  BLACKLIST_CACHE_TTL = 5.minutes
  AUTH_HEADER = 'Authorization'
  BEARER_PATTERN = /^Bearer /i

  included do
    before_action :authenticate_from_token
    rescue_from JWT::DecodeError, with: :handle_invalid_token
    rescue_from JWT::ExpiredSignature, with: :handle_expired_token
  end

  private

  # Authenticates user from JWT token with enhanced security checks and caching
  #
  # @return [User, nil] Authenticated user instance or nil with error context
  def authenticate_from_token
    token = extract_token_from_header
    return nil unless token

    cached_validation = validate_token_cache(token)
    return cached_validation if cached_validation

    begin
      jwt_service = JWTService.new(token)
      validation_result = jwt_service.validate_token

      if validation_result.success?
        user = find_and_validate_user(validation_result.result['user_id'])
        update_token_cache(token, user)
        @current_authenticated_user = user
      else
        handle_validation_failure(validation_result.errors)
        nil
      end
    rescue StandardError => e
      handle_authentication_error(e)
      nil
    end
  end

  # Extracts and validates JWT token from request headers
  #
  # @return [String, nil] Validated JWT token string or nil
  def extract_token_from_header
    auth_header = request.headers[AUTH_HEADER]
    return nil unless auth_header&.match(BEARER_PATTERN)

    token = auth_header.gsub(BEARER_PATTERN, '')
    return nil if token.blank?

    log_token_extraction(token)
    token
  end

  # Manages token validation caching for performance optimization
  #
  # @param token [String] JWT token to validate
  # @return [User, nil] Cached user or nil if cache miss
  def validate_token_cache(token)
    cache_key = "jwt_auth:#{Digest::SHA256.hexdigest(token)}"
    
    REDIS_AUTH_POOL.with do |redis|
      if cached_user_id = redis.get(cache_key)
        find_cached_user(cached_user_id)
      end
    end
  rescue Redis::BaseError => e
    Rails.logger.error("Token cache validation failed: #{e.message}")
    nil
  end

  # Finds and validates user with caching support
  #
  # @param user_id [Integer] User ID to find
  # @return [User, nil] Valid user instance or nil
  def find_and_validate_user(user_id)
    cache_key = "user:#{user_id}:auth"
    
    Rails.cache.fetch(cache_key, expires_in: USER_CACHE_TTL) do
      user = User.find_by(id: user_id)
      return nil unless user&.active?
      user
    end
  rescue ActiveRecord::RecordNotFound
    nil
  end

  # Updates token validation cache
  #
  # @param token [String] JWT token
  # @param user [User] Authenticated user
  def update_token_cache(token, user)
    return unless user

    cache_key = "jwt_auth:#{Digest::SHA256.hexdigest(token)}"
    
    REDIS_AUTH_POOL.with do |redis|
      redis.setex(cache_key, TOKEN_CACHE_TTL, user.id)
    end
  rescue Redis::BaseError => e
    Rails.logger.error("Token cache update failed: #{e.message}")
  end

  # Finds user from cache with proper error handling
  #
  # @param user_id [String] Cached user ID
  # @return [User, nil] Cached user instance or nil
  def find_cached_user(user_id)
    cache_key = "user:#{user_id}:auth"
    
    Rails.cache.fetch(cache_key, expires_in: USER_CACHE_TTL) do
      User.find_by(id: user_id)
    end
  rescue StandardError => e
    Rails.logger.error("Cached user lookup failed: #{e.message}")
    nil
  end

  # Handles JWT validation failures
  #
  # @param errors [Array<Hash>] Validation errors
  def handle_validation_failure(errors)
    Rails.logger.warn("JWT validation failed: #{errors}")
    track_failed_authentication
  end

  # Handles invalid token errors
  #
  # @param exception [JWT::DecodeError] Token decode error
  def handle_invalid_token(exception)
    track_failed_authentication
    log_authentication_failure('invalid_token', exception)
    render_unauthorized('Invalid authentication token')
  end

  # Handles expired token errors
  #
  # @param exception [JWT::ExpiredSignature] Token expiration error
  def handle_expired_token(exception)
    track_failed_authentication
    log_authentication_failure('expired_token', exception)
    render_unauthorized('Authentication token has expired')
  end

  # Handles general authentication errors
  #
  # @param error [StandardError] Authentication error
  def handle_authentication_error(error)
    Rails.logger.error("Authentication error: #{error.message}")
    NewRelic::Agent.notice_error(error) if defined?(NewRelic)
    render_unauthorized('Authentication failed')
  end

  # Logs token extraction attempt
  #
  # @param token [String] Extracted token
  def log_token_extraction(token)
    Rails.logger.debug(
      "Token extracted from request",
      token_present: token.present?,
      request_id: request.request_id
    )
  end

  # Logs authentication failures
  #
  # @param reason [String] Failure reason
  # @param exception [Exception] Related exception
  def log_authentication_failure(reason, exception)
    Rails.logger.warn(
      "Authentication failed: #{reason}",
      error: exception.message,
      request_id: request.request_id
    )
  end

  # Renders standardized unauthorized response
  #
  # @param message [String] Error message
  def render_unauthorized(message)
    render json: {
      error: 'Unauthorized',
      message: message,
      status: 401
    }, status: :unauthorized
  end
end