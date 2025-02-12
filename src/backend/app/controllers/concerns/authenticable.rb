# frozen_string_literal: true

require 'active_support/concern'

# Provides comprehensive authentication functionality with JWT token management,
# rate limiting, and security monitoring for Rails controllers.
#
# @version 1.0.0
# @see Technical Specifications/7.1/Authentication and Authorization
module Authenticable
  extend ActiveSupport::Concern

  # Constants for authentication configuration
  TOKEN_LIFETIME = 24.hours
  RATE_LIMIT_MAX_REQUESTS = 1000
  RATE_LIMIT_WINDOW = 1.hour
  CACHE_TTL = 1.hour
  AUTH_HEADER = 'Authorization'
  BEARER_PATTERN = /^Bearer /i

  included do
    before_action :track_auth_metrics
    rescue_from JWT::DecodeError, with: :handle_invalid_token
    rescue_from JWT::ExpiredSignature, with: :handle_expired_token
  end

  # Returns the currently authenticated user with enhanced caching and security checks
  #
  # @return [User, nil] Currently authenticated user instance or nil
  def current_user
    return @current_user if defined?(@current_user)

    token = extract_token_from_header
    return nil unless token

    REDIS_AUTH_POOL.with do |redis|
      cache_key = "user:#{token_payload['user_id']}:current"
      
      @current_user = Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
        verify_token(token) do |payload|
          user = User.find(payload['user_id'])
          verify_user_status(user)
          user
        end
      end
    end

    track_authentication_attempt(@current_user)
    @current_user
  rescue StandardError => e
    handle_authentication_error(e)
    nil
  end

  # Ensures user authentication with comprehensive security checks
  #
  # @raise [UnauthorizedError] If authentication fails
  # @return [Boolean] True if authentication successful
  def authenticate_user!
    verify_rate_limit!
    
    unless user_signed_in?
      track_failed_authentication
      raise UnauthorizedError, 'Authentication required'
    end
    
    true
  end

  # Verifies user authentication status with enhanced security checks
  #
  # @return [Boolean] True if user is signed in with valid token
  def user_signed_in?
    return @user_signed_in if defined?(@user_signed_in)
    
    @user_signed_in = current_user.present?
  end

  private

  # Extracts JWT token from Authorization header
  #
  # @return [String, nil] JWT token or nil if not present
  def extract_token_from_header
    return nil unless request.headers[AUTH_HEADER]&.match(BEARER_PATTERN)
    
    request.headers[AUTH_HEADER].gsub(BEARER_PATTERN, '')
  end

  # Verifies JWT token validity and expiration
  #
  # @param token [String] JWT token to verify
  # @yield [Hash] Decoded token payload
  # @return [Object] Result of the block
  def verify_token(token)
    payload = Devise::JWT::TokenVerifier.verify(token)
    
    if payload && block_given?
      yield payload
    else
      payload
    end
  end

  # Verifies user account status and permissions
  #
  # @param user [User] User to verify
  # @raise [UnauthorizedError] If user is inactive or locked
  # @return [User] Verified user
  def verify_user_status(user)
    raise UnauthorizedError, 'Account inactive' unless user.active?
    raise UnauthorizedError, 'Account locked' if user.access_locked?
    user
  end

  # Verifies rate limiting for current client
  #
  # @raise [RateLimitExceededError] If rate limit exceeded
  def verify_rate_limit!
    REDIS_AUTH_POOL.with do |redis|
      key = "rate_limit:#{request.ip}"
      count = redis.incr(key)
      
      if count == 1
        redis.expire(key, RATE_LIMIT_WINDOW.to_i)
      end
      
      if count > RATE_LIMIT_MAX_REQUESTS
        track_rate_limit_exceeded
        raise RateLimitExceededError, 'Rate limit exceeded'
      end
    end
  end

  # Tracks authentication metrics and attempts
  #
  # @param user [User, nil] Authenticated user or nil
  def track_authentication_attempt(user)
    REDIS_AUTH_POOL.with do |redis|
      redis.hincrby('auth:metrics:attempts', Date.today.to_s, 1)
      redis.hincrby('auth:metrics:success', Date.today.to_s, 1) if user
    end
  end

  # Tracks failed authentication attempts
  def track_failed_authentication
    REDIS_AUTH_POOL.with do |redis|
      redis.hincrby('auth:metrics:failures', Date.today.to_s, 1)
      redis.hincrby("auth:failures:#{request.ip}", Date.today.to_s, 1)
    end
  end

  # Tracks rate limit exceeded events
  def track_rate_limit_exceeded
    REDIS_AUTH_POOL.with do |redis|
      redis.hincrby('auth:metrics:rate_limits', Date.today.to_s, 1)
    end
  end

  # Tracks general authentication metrics
  def track_auth_metrics
    REDIS_AUTH_POOL.with do |redis|
      redis.hincrby('auth:metrics:requests', Date.today.to_s, 1)
    end
  end

  # Handles authentication errors with proper logging
  #
  # @param error [StandardError] The error that occurred
  def handle_authentication_error(error)
    Rails.logger.error("Authentication error: #{error.message}")
    NewRelic::Agent.notice_error(error) if defined?(NewRelic)
  end

  # Handles invalid token errors
  def handle_invalid_token
    track_failed_authentication
    render_unauthorized('Invalid authentication token')
  end

  # Handles expired token errors
  def handle_expired_token
    track_failed_authentication
    render_unauthorized('Authentication token has expired')
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

  # Custom error classes
  class UnauthorizedError < StandardError; end
  class RateLimitExceededError < StandardError; end
end