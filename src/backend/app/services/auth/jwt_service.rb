# frozen_string_literal: true

require 'jwt'
require 'securerandom'
require 'newrelic_rpm'

# Service class that handles JWT token operations with comprehensive security controls
# Implements secure token generation, validation, and lifecycle management
#
# @example
#   service = JWTService.new(payload: { user_id: 1 })
#   token = service.generate_token
#   
#   validator = JWTService.new(token: token)
#   if validator.validate_token.success?
#     handle_valid_token(validator.payload)
#   end
class JWTService < ApplicationService
  include NewRelic::Agent::MethodTracer

  ALGORITHM = 'HS256'
  TOKEN_TYPE = 'access'
  TOKEN_LIFETIME = 24.hours
  REQUIRED_CLAIMS = %w[jti iat exp typ].freeze
  LEEWAY = 30.seconds

  # @return [String] JWT token for validation operations
  attr_reader :token

  # @return [Hash] Token payload for generation operations
  attr_reader :payload

  # @return [Hash] Service configuration options
  attr_reader :options

  # Initializes the JWT service with token or payload
  #
  # @param token_or_payload [String, Hash] JWT token for validation or payload for generation
  # @param options [Hash] Configuration options
  # @option options [Integer] :token_lifetime Token lifetime in seconds
  # @option options [Integer] :leeway Time leeway for validation in seconds
  def initialize(token_or_payload, options = {})
    super()
    initialize_attributes(token_or_payload, options)
    setup_monitoring
  end

  # Generates a new JWT token with secure claims
  #
  # @return [String] Generated JWT token if successful
  add_method_tracer :generate_token
  def generate_token
    validate_payload_format
    
    begin
      @token = JWT.encode(
        prepared_payload,
        jwt_secret,
        ALGORITHM
      )
      
      report_token_generation
      @success = true
      @result = @token
    rescue JWT::EncodeError => e
      handle_jwt_error(e, __method__)
    end

    @token
  end

  # Validates JWT token authenticity and claims
  #
  # @return [JWTService] self with validation result
  add_method_tracer :validate_token
  def validate_token
    return invalid_token_error if @token.nil? || @token.empty?

    begin
      decoded_payload = JWT.decode(
        @token,
        jwt_secret,
        true,
        decode_options
      ).first

      if valid_payload?(decoded_payload) && !token_blacklisted?(decoded_payload)
        @payload = decoded_payload
        @success = true
        @result = @payload
      end
    rescue JWT::ExpiredSignature => e
      handle_jwt_error(e, __method__, 'Token has expired')
    rescue JWT::InvalidJtiError => e
      handle_jwt_error(e, __method__, 'Invalid token ID (jti)')
    rescue JWT::DecodeError => e
      handle_jwt_error(e, __method__, 'Invalid token format or signature')
    end

    self
  end

  private

  def initialize_attributes(token_or_payload, options)
    @options = default_options.merge(options)
    @issued_at = Time.current.to_i
    @expires_at = @issued_at + @options[:token_lifetime]
    @jwt_id = SecureRandom.uuid

    case token_or_payload
    when String
      @token = token_or_payload
    when Hash
      @payload = token_or_payload
    else
      raise ArgumentError, 'Must provide either token string or payload hash'
    end
  end

  def default_options
    {
      token_lifetime: TOKEN_LIFETIME,
      leeway: LEEWAY
    }
  end

  def setup_monitoring
    ::NewRelic::Agent.add_custom_attributes(
      service: self.class.name,
      operation_type: @token ? 'validation' : 'generation'
    )
  end

  def prepared_payload
    {
      jti: @jwt_id,
      iat: @issued_at,
      exp: @expires_at,
      typ: TOKEN_TYPE
    }.merge(@payload || {})
  end

  def decode_options
    {
      algorithm: ALGORITHM,
      leeway: @options[:leeway],
      verify_jti: true,
      verify_iat: true,
      verify_expiration: true,
      required_claims: REQUIRED_CLAIMS
    }
  end

  def valid_payload?(payload)
    return false unless payload.is_a?(Hash)
    
    REQUIRED_CLAIMS.all? { |claim| payload.key?(claim) } &&
      payload['typ'] == TOKEN_TYPE &&
      payload['iat'].is_a?(Integer) &&
      payload['exp'].is_a?(Integer) &&
      payload['jti'].is_a?(String)
  end

  def token_blacklisted?(payload)
    blacklist_service = TokenBlacklistService.new(@token)
    blacklist_service.blacklisted?
  end

  def jwt_secret
    ENV['JWT_SECRET'] or raise 'JWT_SECRET environment variable not set'
  end

  def handle_jwt_error(error, operation, message = nil)
    handle_error(error)
    
    ::NewRelic::Agent.notice_error(
      error,
      custom_params: {
        operation: operation,
        message: message || error.message
      }
    )
  end

  def invalid_token_error
    error = JWT::DecodeError.new('Token is missing or empty')
    handle_jwt_error(error, __method__)
    self
  end

  def validate_payload_format
    unless @payload.is_a?(Hash)
      raise ArgumentError, 'Payload must be a hash'
    end
  end

  def report_token_generation
    ::NewRelic::Agent.record_metric(
      'Custom/JWT/token_generation',
      1
    )
  end

  # Decodes token without validation for inspection
  #
  # @return [Hash, nil] Raw decoded payload or nil if decode fails
  def decode_token
    return nil if @token.nil? || @token.empty?

    begin
      JWT.decode(
        @token,
        nil,
        false
      ).first
    rescue JWT::DecodeError => e
      handle_jwt_error(e, __method__)
      nil
    end
  end
end