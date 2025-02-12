# frozen_string_literal: true

module Api
  module V1
    # Base controller for API v1 endpoints providing core functionality including
    # JWT authentication, rate limiting, error handling, and performance monitoring.
    #
    # @version 1.0.0
    # @see Technical Specifications/3.1.1 API Architecture
    class ApplicationController < ::ApplicationController
      # Include core functionality modules
      include ApiErrorHandler
      include JWTAuthenticable
      include RateLimitable

      # API version identifier
      API_VERSION = 'v1'
      # Default rate limit per hour
      DEFAULT_RATE_LIMIT = 1000
      # Request timeout in seconds
      REQUEST_TIMEOUT = 30

      # Configure before actions
      before_action :set_api_version
      before_action :require_authentication
      before_action :check_version_deprecation
      before_action :set_security_headers
      before_action :set_correlation_id
      before_action :track_request_metrics

      # Configure after actions
      after_action :track_response_metrics

      private

      # Sets API version for the request
      #
      # @return [void]
      def set_api_version
        response.headers['X-API-Version'] = API_VERSION
      end

      # Ensures request is authenticated with valid JWT token
      #
      # @return [void]
      # @raise [UnauthorizedError] if authentication fails
      def require_authentication
        unless authenticate_request
          render_unauthorized('Authentication required')
        end
      end

      # Checks if current API version is deprecated
      #
      # @return [void]
      def check_version_deprecation
        # Implement version deprecation logic here
        # For now, v1 is current and not deprecated
      end

      # Sets required security headers for all responses
      #
      # @return [void]
      def set_security_headers
        response.headers.merge!({
          'Content-Security-Policy' => "default-src 'none'",
          'Strict-Transport-Security' => 'max-age=31536000; includeSubDomains',
          'X-Content-Type-Options' => 'nosniff',
          'X-Frame-Options' => 'DENY',
          'X-XSS-Protection' => '1; mode=block',
          'Cache-Control' => 'no-store',
          'Pragma' => 'no-cache'
        })
      end

      # Sets correlation ID for request tracking
      #
      # @return [void]
      def set_correlation_id
        @correlation_id = request.headers['X-Correlation-ID'].presence || SecureRandom.uuid
        response.headers['X-Correlation-ID'] = @correlation_id

        NewRelic::Agent.add_custom_parameters(
          correlation_id: @correlation_id,
          api_version: API_VERSION
        )
      end

      # Tracks request metrics for monitoring
      #
      # @return [void]
      def track_request_metrics
        @request_start_time = Time.current

        NewRelic::Agent.record_custom_event(
          'APIRequest',
          {
            version: API_VERSION,
            controller: controller_name,
            action: action_name,
            method: request.method,
            path: request.path,
            correlation_id: @correlation_id,
            client_ip: request.remote_ip
          }
        )
      end

      # Tracks response metrics for monitoring
      #
      # @return [void]
      def track_response_metrics
        duration = (Time.current - @request_start_time) * 1000.0 # Convert to milliseconds

        NewRelic::Agent.record_metric(
          "Custom/API/V1/#{controller_name}/#{action_name}/Duration",
          duration
        )

        if duration > 500.0 # Alert on responses over 500ms
          NewRelic::Agent.notice_error(
            'Slow API response detected',
            custom_params: {
              duration: duration,
              controller: controller_name,
              action: action_name,
              correlation_id: @correlation_id
            }
          )
        end

        response.headers['X-Runtime'] = duration.to_s
      end

      # Renders standardized unauthorized response
      #
      # @param message [String] error message
      # @return [void]
      def render_unauthorized(message)
        render json: {
          error: 'unauthorized',
          message: message,
          status: 401,
          correlation_id: @correlation_id,
          timestamp: Time.current.iso8601
        }, status: :unauthorized
      end

      # Renders standardized error response
      #
      # @param error [StandardError] the error that occurred
      # @param status [Symbol] HTTP status code
      # @return [void]
      def render_error(error, status)
        error_response = {
          error: status.to_s,
          message: error.message,
          status: Rack::Utils.status_code(status),
          correlation_id: @correlation_id,
          timestamp: Time.current.iso8601
        }

        render json: error_response, status: status
      end
    end
  end
end