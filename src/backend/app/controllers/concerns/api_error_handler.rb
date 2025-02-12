# frozen_string_literal: true

# External gem: activesupport ~> 7.0.0
require 'active_support/concern'

# ApiErrorHandler implements RFC 7807 Problem Details for HTTP APIs with comprehensive
# error handling, security controls, and monitoring integration.
module ApiErrorHandler
  extend ActiveSupport::Concern

  # Define standard error type URIs
  ERROR_TYPES = {
    NOT_FOUND: 'https://api.example.com/errors/not_found',
    VALIDATION_ERROR: 'https://api.example.com/errors/validation_error',
    UNAUTHORIZED: 'https://api.example.com/errors/unauthorized',
    RATE_LIMIT: 'https://api.example.com/errors/rate_limit',
    INTERNAL_ERROR: 'https://api.example.com/errors/internal_error'
  }.freeze

  included do
    rescue_from ActiveRecord::RecordNotFound, with: :handle_record_not_found
    rescue_from ActiveRecord::RecordInvalid, with: :handle_record_invalid
    rescue_from JWT::DecodeError, JWT::ExpiredSignature, JWT::InvalidIssuerError, with: :handle_unauthorized
    rescue_from RateLimit::ExceededError, with: :handle_rate_limit_exceeded
    rescue_from StandardError, with: :handle_standard_error
  end

  private

  # Handles ActiveRecord::RecordNotFound with RFC 7807 compliant 404 responses
  #
  # @param exception [ActiveRecord::RecordNotFound] the not found exception
  # @return [void]
  def handle_record_not_found(exception)
    resource_type = exception.model.underscore
    resource_id = exception.id

    error_response = {
      type: ERROR_TYPES[:NOT_FOUND],
      title: 'Resource Not Found',
      status: 404,
      detail: "Could not find #{resource_type} with id #{resource_id}",
      instance: request.path,
      request_id: request.request_id
    }

    Rails.logger.info(
      error: 'record_not_found',
      resource_type: resource_type,
      resource_id: resource_id,
      request_id: request.request_id,
      path: request.path,
      ip: request.remote_ip
    )

    render json: error_response, status: :not_found
  end

  # Handles ActiveRecord::RecordInvalid with detailed validation errors
  #
  # @param exception [ActiveRecord::RecordInvalid] the validation exception
  # @return [void]
  def handle_record_invalid(exception)
    error_response = {
      type: ERROR_TYPES[:VALIDATION_ERROR],
      title: 'Validation Failed',
      status: 422,
      detail: exception.message,
      instance: request.path,
      request_id: request.request_id,
      errors: format_validation_errors(exception.record.errors)
    }

    Rails.logger.info(
      error: 'validation_failed',
      resource_type: exception.record.class.name,
      validation_errors: exception.record.errors.to_hash,
      request_id: request.request_id,
      path: request.path
    )

    render json: error_response, status: :unprocessable_entity
  end

  # Handles authentication and authorization failures securely
  #
  # @param exception [JWT::DecodeError] the JWT exception
  # @return [void]
  def handle_unauthorized(exception)
    error_response = {
      type: ERROR_TYPES[:UNAUTHORIZED],
      title: 'Authentication Failed',
      status: 401,
      detail: 'Invalid or expired authentication credentials',
      instance: request.path,
      request_id: request.request_id
    }

    Rails.logger.warn(
      error: 'authentication_failed',
      error_type: exception.class.name,
      request_id: request.request_id,
      path: request.path,
      ip: request.remote_ip
    )

    # Track failed authentication attempts for security monitoring
    SecurityAuditLogger.log_auth_failure(
      ip: request.remote_ip,
      path: request.path,
      request_id: request.request_id
    )

    response.headers['WWW-Authenticate'] = 'Bearer realm="API"'
    render json: error_response, status: :unauthorized
  end

  # Handles rate limit violations with detailed headers
  #
  # @param exception [RateLimit::ExceededError] the rate limit exception
  # @return [void]
  def handle_rate_limit_exceeded(exception)
    reset_time = Time.at(exception.reset_at).utc
    
    error_response = {
      type: ERROR_TYPES[:RATE_LIMIT],
      title: 'Rate Limit Exceeded',
      status: 429,
      detail: 'API rate limit has been exceeded',
      instance: request.path,
      request_id: request.request_id,
      rate_limit: {
        limit: exception.limit,
        remaining: 0,
        reset_at: reset_time.iso8601
      }
    }

    Rails.logger.info(
      error: 'rate_limit_exceeded',
      client_id: current_client&.id,
      request_id: request.request_id,
      path: request.path,
      ip: request.remote_ip
    )

    response.headers['X-RateLimit-Limit'] = exception.limit.to_s
    response.headers['X-RateLimit-Remaining'] = '0'
    response.headers['X-RateLimit-Reset'] = reset_time.to_i.to_s
    
    render json: error_response, status: :too_many_requests
  end

  # Handles unexpected errors securely with monitoring integration
  #
  # @param exception [StandardError] the unexpected exception
  # @return [void]
  def handle_standard_error(exception)
    error_id = SecureRandom.uuid

    error_response = {
      type: ERROR_TYPES[:INTERNAL_ERROR],
      title: 'Internal Server Error',
      status: 500,
      detail: 'An unexpected error occurred',
      instance: request.path,
      request_id: request.request_id,
      error_id: error_id
    }

    # Log detailed error information securely
    Rails.logger.error(
      error: 'internal_server_error',
      error_id: error_id,
      error_class: exception.class.name,
      error_message: exception.message,
      backtrace: exception.backtrace,
      request_id: request.request_id,
      path: request.path,
      params: filter_sensitive_params(params.to_unsafe_h),
      ip: request.remote_ip
    )

    # Notify error monitoring service
    ErrorMonitoring.notify(
      exception,
      error_id: error_id,
      request_id: request.request_id,
      context: error_monitoring_context
    )

    # Track error metrics
    ErrorMetrics.increment(
      'api.errors.internal',
      tags: [
        "error_class:#{exception.class.name}",
        "path:#{request.path}"
      ]
    )

    render json: error_response, status: :internal_server_error
  end

  # Formats validation errors according to RFC 7807
  #
  # @param errors [ActiveModel::Errors] the validation errors
  # @return [Hash] formatted errors
  def format_validation_errors(errors)
    errors.to_hash(true).transform_values do |messages|
      messages.map do |message|
        {
          code: error_code_for_message(message),
          message: message
        }
      end
    end
  end

  # Maps validation messages to error codes
  #
  # @param message [String] the validation message
  # @return [String] the error code
  def error_code_for_message(message)
    # Map common validation messages to codes
    case message
    when /can't be blank/i
      'missing_field'
    when /has already been taken/i
      'duplicate_value'
    when /is invalid/i
      'invalid_format'
    else
      'validation_failed'
    end
  end

  # Filters sensitive parameters for logging
  #
  # @param params_hash [Hash] the parameters hash
  # @return [Hash] filtered parameters
  def filter_sensitive_params(params_hash)
    Rails.application.config.filter_parameters.each do |param|
      params_hash.deep_transform_values! do |value|
        value.to_s.include?(param.to_s) ? '[FILTERED]' : value
      end
    end
    params_hash
  end

  # Builds context for error monitoring
  #
  # @return [Hash] monitoring context
  def error_monitoring_context
    {
      request_id: request.request_id,
      path: request.path,
      method: request.method,
      client_id: current_client&.id,
      ip: request.remote_ip,
      user_agent: request.user_agent
    }
  end
end