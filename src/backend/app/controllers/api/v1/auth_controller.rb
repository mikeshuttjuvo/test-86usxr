# frozen_string_literal: true

module Api
  module V1
    # Handles authentication operations with enhanced security controls and monitoring
    # @version 1.0.0
    # @see Technical Specifications/7.1/Authentication Flow
    class AuthController < Api::V1::ApplicationController
      include NewRelic::Agent::Instrumentation::ControllerInstrumentation

      # Skip authentication for login endpoint
      skip_before_action :require_authentication, only: [:login]

      # Configure rate limiting per endpoint
      rate_limit :login, limit: 5, period: 20.minutes
      rate_limit :logout, limit: 10, period: 1.hour
      rate_limit :refresh, limit: 10, period: 1.hour
      rate_limit :validate, limit: 100, period: 1.hour

      # Initialize blacklist service
      def initialize
        super
        @blacklist_service = TokenBlacklistService.new(nil)
      end

      # Authenticates user credentials and returns JWT token
      #
      # @param [String] email User's email
      # @param [String] password User's password
      # @return [JSON] JWT token and user info if successful
      add_transaction_tracer :login
      def login
        validate_login_params

        user = find_and_authenticate_user
        token = generate_token_for_user(user)

        track_successful_login(user)

        render json: {
          token: token,
          user: user_response_data(user),
          expires_in: JWTService::TOKEN_LIFETIME
        }, status: :ok
      rescue StandardError => e
        handle_login_error(e)
      end

      # Invalidates current JWT token
      #
      # @return [JSON] Success message if token blacklisted
      add_transaction_tracer :logout
      def logout
        token = extract_token_from_header
        blacklist_service = TokenBlacklistService.new(token)

        if blacklist_service.blacklist
          track_successful_logout
          render json: { message: 'Successfully logged out' }, status: :ok
        else
          handle_api_error(blacklist_service.errors.first)
        end
      rescue StandardError => e
        handle_logout_error(e)
      end

      # Issues new JWT token with sliding window expiration
      #
      # @return [JSON] New JWT token if refreshed
      add_transaction_tracer :refresh
      def refresh
        token = extract_token_from_header
        jwt_service = JWTService.new(token)
        validation = jwt_service.validate_token

        if validation.success?
          handle_token_refresh(validation.result)
        else
          handle_api_error(validation.errors.first)
        end
      rescue StandardError => e
        handle_refresh_error(e)
      end

      # Validates current JWT token
      #
      # @return [JSON] User info if token valid
      add_transaction_tracer :validate
      def validate
        token = extract_token_from_header
        jwt_service = JWTService.new(token)
        validation = jwt_service.validate_token

        if validation.success?
          render json: { 
            valid: true, 
            user: user_response_data(current_user)
          }, status: :ok
        else
          handle_api_error(validation.errors.first)
        end
      rescue StandardError => e
        handle_validation_error(e)
      end

      private

      def validate_login_params
        unless params[:email].present? && params[:password].present?
          raise ArgumentError, 'Email and password are required'
        end
      end

      def find_and_authenticate_user
        user = User.find_by(email: params[:email].downcase)
        raise AuthenticationError, 'Invalid email or password' unless user
        
        unless user.valid_password?(params[:password])
          track_failed_login(user)
          raise AuthenticationError, 'Invalid email or password'
        end

        raise AuthenticationError, 'Account is locked' if user.access_locked?
        raise AuthenticationError, 'Account is inactive' unless user.active?

        user
      end

      def generate_token_for_user(user)
        jwt_service = JWTService.new(
          user_id: user.id,
          email: user.email,
          role: user.role
        )
        token = jwt_service.generate_token
        raise JWT::EncodeError, 'Failed to generate token' unless token
        token
      end

      def handle_token_refresh(payload)
        return handle_api_error('Token not eligible for refresh') unless token_expiring_soon?(payload)
        
        old_token = extract_token_from_header
        new_token = generate_token_for_user(current_user)

        blacklist_service = TokenBlacklistService.new(old_token)
        blacklist_service.blacklist

        render json: {
          token: new_token,
          user: user_response_data(current_user),
          expires_in: JWTService::TOKEN_LIFETIME
        }, status: :ok
      end

      def token_expiring_soon?(payload)
        exp_time = Time.at(payload['exp'])
        Time.current >= (exp_time - 6.hours)
      end

      def user_response_data(user)
        {
          id: user.id,
          email: user.email,
          role: user.role,
          first_name: user.first_name,
          last_name: user.last_name,
          active: user.active
        }
      end

      def track_successful_login(user)
        NewRelic::Agent.record_custom_event(
          'Authentication',
          {
            action: 'login',
            status: 'success',
            user_id: user.id,
            ip_address: request.remote_ip
          }
        )
      end

      def track_failed_login(user)
        NewRelic::Agent.record_custom_event(
          'Authentication',
          {
            action: 'login',
            status: 'failed',
            user_id: user&.id,
            ip_address: request.remote_ip
          }
        )
      end

      def track_successful_logout
        NewRelic::Agent.record_custom_event(
          'Authentication',
          {
            action: 'logout',
            status: 'success',
            user_id: current_user.id,
            ip_address: request.remote_ip
          }
        )
      end

      def handle_login_error(error)
        NewRelic::Agent.notice_error(error)
        case error
        when ArgumentError
          render_error('Invalid login parameters', :bad_request)
        when AuthenticationError
          render_error(error.message, :unauthorized)
        else
          render_error('Authentication failed', :internal_server_error)
        end
      end

      def handle_logout_error(error)
        NewRelic::Agent.notice_error(error)
        render_error('Logout failed', :internal_server_error)
      end

      def handle_refresh_error(error)
        NewRelic::Agent.notice_error(error)
        render_error('Token refresh failed', :unauthorized)
      end

      def handle_validation_error(error)
        NewRelic::Agent.notice_error(error)
        render_error('Token validation failed', :unauthorized)
      end

      class AuthenticationError < StandardError; end
    end
  end
end