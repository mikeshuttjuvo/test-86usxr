# frozen_string_literal: true

# Base controller class that provides core functionality for all API controllers
# including enhanced error handling, authentication, rate limiting, and security monitoring.
#
# @version 1.0.0
# @see Technical Specifications/3.1.1 API Architecture
class ApplicationController < ActionController::API
  # External dependencies
  # actionpack ~> 7.0.0
  # newrelic_rpm ~> 8.0.0

  # Include core functionality modules
  include ApiErrorHandler
  include JWTAuthenticable
  include RateLimitable

  # Configure before actions
  before_action :set_default_format
  before_action :track_request
  before_action :set_security_headers
  before_action :validate_content_type

  # Configure after actions
  after_action :set_response_headers

  # Request tracking attributes
  attr_reader :request_id, :request_metrics

  # Initialize request metrics tracking
  def initialize
    super
    @request_metrics = {
      started_at: nil,
      controller: nil,
      action: nil,
      status: nil,
      duration: nil
    }
  end

  private

  # Sets default response format to JSON
  #
  # @return [void]
  def set_default_format
    request.format = :json
    response.content_type = 'application/json'
  end

  # Tracks request metrics and sets correlation IDs
  #
  # @return [void]
  def track_request
    @request_id = SecureRandom.uuid
    @request_metrics[:started_at] = Time.current
    @request_metrics[:controller] = controller_name
    @request_metrics[:action] = action_name

    # Set correlation headers
    response.headers['X-Request-Id'] = @request_id
    response.headers['X-Correlation-Id'] = @request_id

    # Configure NewRelic custom parameters
    ::NewRelic::Agent.add_custom_parameters(
      request_id: @request_id,
      controller: controller_name,
      action: action_name,
      client_ip: request.remote_ip
    )
  end

  # Sets security headers according to OWASP recommendations
  #
  # @return [void]
  def set_security_headers
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['X-Frame-Options'] = 'DENY'
    response.headers['X-XSS-Protection'] = '1; mode=block'
    response.headers['Strict-Transport-Security'] = 'max-age=31536000; includeSubDomains'
    response.headers['Content-Security-Policy'] = "default-src 'none'"
    response.headers['Cache-Control'] = 'no-store'
    response.headers['Pragma'] = 'no-cache'
  end

  # Validates request content type
  #
  # @return [void]
  # @raise [ActionController::InvalidAuthenticityToken] if content type is invalid
  def validate_content_type
    return if request.get? || request.head?

    unless request.content_type == 'application/json'
      render json: {
        error: 'invalid_content_type',
        message: 'Content-Type must be application/json'
      }, status: :unsupported_media_type
    end
  end

  # Sets standard response headers
  #
  # @return [void]
  def set_response_headers
    @request_metrics[:status] = response.status
    @request_metrics[:duration] = Time.current - @request_metrics[:started_at]

    response.headers['X-Runtime'] = @request_metrics[:duration].to_s
    response.headers['X-API-Version'] = '1.0'

    # Record response metrics
    record_response_metrics
  end

  # Records response metrics to monitoring service
  #
  # @return [void]
  def record_response_metrics
    ::NewRelic::Agent.record_metric(
      "Custom/Response/#{controller_name}/#{action_name}",
      @request_metrics[:duration]
    )

    ::NewRelic::Agent.record_metric(
      "Custom/Response/Status/#{response.status}",
      1
    )

    if @request_metrics[:duration] > 0.5 # 500ms threshold
      ::NewRelic::Agent.notice_error(
        'Slow API response detected',
        custom_params: @request_metrics
      )
    end
  end

  # Renders a standardized error response
  #
  # @param message [String] error message
  # @param status [Symbol] HTTP status code
  # @return [void]
  def render_error(message, status)
    render json: {
      error: status.to_s,
      message: message,
      request_id: @request_id,
      timestamp: Time.current.iso8601
    }, status: status
  end
end