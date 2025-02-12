# frozen_string_literal: true

require 'json'
require 'rspec/core'

# Helper module providing comprehensive utility methods for testing API requests
# Includes robust JSON response parsing, JWT authentication header generation,
# and standardized request header setup according to RFC 7807 specifications
#
# @example
#   RSpec.describe 'API Endpoints' do
#     include RequestSpecHelper
#
#     it 'returns correct JSON response' do
#       get '/api/v1/locations', headers: json_request_headers
#       expect(json_response[:data]).to be_present
#     end
#
#     it 'requires authentication' do
#       get '/api/v1/jobs', headers: auth_headers(user)
#       expect(response).to have_http_status(:ok)
#     end
#   end
module RequestSpecHelper
  # Parses and validates JSON response body with comprehensive error handling
  #
  # @return [Hash] Parsed JSON response with symbolized keys
  # @raise [JSON::ParserError] if response body contains invalid JSON
  def json_response
    raise 'Response body is empty' if response&.body.blank?

    begin
      @json_response ||= JSON.parse(response.body, symbolize_names: true)
    rescue JSON::ParserError => e
      raise JSON::ParserError, "Invalid JSON in response: #{e.message}"
    end
  end

  # Generates authentication headers with JWT token for a given user
  #
  # @param user [User] User instance for token generation
  # @return [Hash] Headers hash with Authorization and content type
  # @raise [ArgumentError] if user is invalid or missing required attributes
  def auth_headers(user)
    raise ArgumentError, 'User must be provided' if user.nil?
    raise ArgumentError, 'Invalid user object' unless user.respond_to?(:id)

    jwt_service = JWTService.new(
      {
        user_id: user.id,
        email: user.email,
        roles: user.roles
      }
    )

    token = jwt_service.generate_token
    raise 'Failed to generate JWT token' unless token

    json_request_headers.merge(
      'Authorization' => "Bearer #{token}"
    )
  end

  # Returns standardized headers for JSON API requests
  #
  # @return [Hash] Headers hash with content type and accept headers
  def json_request_headers
    {
      'Accept' => 'application/json',
      'Content-Type' => 'application/json; charset=utf-8'
    }
  end

  # Validates RFC 7807 problem details format in error responses
  #
  # @param error_response [Hash] The error response to validate
  # @return [Boolean] true if response matches RFC 7807 format
  def valid_error_response?(error_response)
    required_keys = %i[type title status detail]
    required_keys.all? { |key| error_response.key?(key) }
  end

  # Extracts error details from response for easier testing
  #
  # @return [Hash] Extracted error details
  # @raise [KeyError] if response doesn't contain error details
  def error_details
    error_response = json_response
    raise KeyError, 'Response does not contain error details' unless valid_error_response?(error_response)

    error_response
  end

  # Validates pagination metadata in response
  #
  # @param response_body [Hash] The response body to validate
  # @return [Boolean] true if pagination metadata is valid
  def valid_pagination?(response_body)
    metadata = response_body[:meta]
    return false unless metadata

    %i[current_page total_pages total_count].all? { |key| metadata.key?(key) }
  end

  # Helper to check if response indicates rate limiting
  #
  # @return [Boolean] true if response indicates rate limiting
  def rate_limited?
    response.headers['X-RateLimit-Remaining'].to_i.zero? &&
      response.status == 429
  end

  private

  # Clears memoized JSON response between examples
  def clear_json_response_cache
    @json_response = nil
  end

  # Validates JWT token format
  #
  # @param token [String] JWT token to validate
  # @return [Boolean] true if token format is valid
  def valid_jwt_format?(token)
    token.split('.').length == 3
  rescue StandardError
    false
  end
end