# frozen_string_literal: true

require 'active_support/concern'
require 'active_support/callbacks'
require 'active_support/configurable'

# Base service class implementing the Service Object pattern for encapsulating business logic.
# Provides common functionality for error handling, result management, and debugging capabilities.
#
# @example
#   class MyService < ApplicationService
#     def perform
#       # Implement service logic here
#       @result = calculated_value
#       @success = true
#     end
#   end
#
#   service = MyService.call(context: { user: current_user })
#   if service.success?
#     handle_success(service.result)
#   else
#     handle_errors(service.errors)
#   end
class ApplicationService
  include ActiveSupport::Callbacks # version ~> 7.0.0
  include ActiveSupport::Configurable # version ~> 7.0.0

  # Define callbacks for service execution lifecycle
  define_callbacks :perform

  class_attribute :debug_enabled, default: false

  class << self
    # Instantiates and executes the service with error handling
    #
    # @param context [Hash] Contextual data for service execution
    # @param args [Array] Additional arguments for service execution
    # @return [ApplicationService] Instance of service after execution
    def call(context = {}, *args)
      new(context).tap do |service|
        begin
          service.run_callbacks(:perform) do
            service.send(:perform, *args)
          end
        rescue StandardError => e
          service.send(:handle_error, e)
        ensure
          service.send(:log_execution) if debug_enabled
        end
      end
    end
  end

  # @return [Boolean] Success status of the service execution
  attr_reader :success

  # @return [Array<Hash>] List of RFC 7807 compliant error objects
  attr_reader :errors

  # @return [Object] Typed result of the service operation
  attr_reader :result

  # @return [Hash] Execution context
  attr_reader :context

  # Initializes a new service instance
  #
  # @param context [Hash] Contextual data for service execution
  def initialize(context = {})
    @success = false
    @errors = []
    @result = nil
    @context = context.to_h
    @debug_logs = []
  end

  # Checks if service execution was successful
  #
  # @return [Boolean] true if operation succeeded, false otherwise
  def success?
    @success
  end

  protected

  # Abstract method to be implemented by subclasses
  #
  # @abstract
  # @raise [NotImplementedError] when not implemented by subclass
  def perform
    raise NotImplementedError, "#{self.class} must implement #perform"
  end

  private

  # Handles errors during service execution
  #
  # @param error [StandardError] The error that occurred
  def handle_error(error)
    @success = false
    @errors << build_error_object(error)
    log_error(error) if debug_enabled
  end

  # Builds RFC 7807 compliant error object
  #
  # @param error [StandardError] The error to format
  # @return [Hash] Formatted error object
  def build_error_object(error)
    {
      type: "https://api.example.com/errors/#{error.class.name.underscore}",
      title: error.class.name.titleize,
      detail: error.message,
      status: map_error_to_status(error),
      instance: generate_error_instance_id,
      timestamp: Time.current.iso8601
    }
  end

  # Maps error types to HTTP status codes
  #
  # @param error [StandardError] The error to map
  # @return [Integer] HTTP status code
  def map_error_to_status(error)
    case error
    when ArgumentError, ValidationError
      400
    when AuthenticationError
      401
    when AuthorizationError
      403
    when NotFoundError
      404
    else
      500
    end
  end

  # Generates unique identifier for error instance
  #
  # @return [String] UUID for error instance
  def generate_error_instance_id
    SecureRandom.uuid
  end

  # Logs execution details for debugging
  def log_execution
    @debug_logs << {
      service: self.class.name,
      timestamp: Time.current.iso8601,
      context: @context,
      success: @success,
      result: @result,
      errors: @errors
    }
  end

  # Logs error details for debugging
  #
  # @param error [StandardError] The error to log
  def log_error(error)
    @debug_logs << {
      error_class: error.class.name,
      message: error.message,
      backtrace: error.backtrace&.first(5),
      timestamp: Time.current.iso8601
    }
  end
end