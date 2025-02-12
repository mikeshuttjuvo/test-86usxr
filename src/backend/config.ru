# frozen_string_literal: true

# Version: rack ~> 2.2.0
# Version: rack-cors ~> 2.0.0
# Version: newrelic_rpm ~> 8.0.0

# Load Rails application environment
require_relative 'config/environment'

# Initialize performance monitoring
begin
  request_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # Configure security headers middleware
  use Rack::ContentSecurityPolicy do |csp|
    csp.default_src :none
    csp.connect_src :self
    csp.frame_ancestors :none
  end

  # Configure CORS with strict origin policies
  use Rack::Cors do |cors|
    cors.allow do |allow|
      allow.origins ENV.fetch('ALLOWED_ORIGINS', '*').split(',')
      allow.resource '*',
        headers: :any,
        methods: [:get, :post, :put, :patch, :delete, :options, :head],
        credentials: false,
        max_age: 86400
    end
  end

  # Configure NewRelic monitoring middleware for production
  if Rails.env.production? || Rails.env.staging?
    use NewRelic::Agent::Instrumentation::Rack
  end

  # Configure request timing middleware
  use Rack::Runtime

  # Configure efficient file serving
  use Rack::SendFile

  # Support REST API method overrides
  use Rack::MethodOverride

  # Handle HEAD requests efficiently
  use Rack::Head

  # Configure request compression
  use Rack::Deflater

  # Configure custom request logging
  use Rack::CommonLogger, Rails.logger

  # Configure custom health check middleware
  use Rack::Builder do
    map '/health' do
      run lambda { |_env|
        [
          200,
          { 'Content-Type' => 'application/json' },
          [{
            status: 'ok',
            version: ENV['APP_VERSION'],
            timestamp: Time.current.iso8601,
            environment: Rails.env
          }.to_json]
        ]
      }
    end
  end

  # Configure custom request timing middleware
  use Class.new {
    def initialize(app)
      @app = app
    end

    def call(env)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status, headers, body = @app.call(env)
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
      
      # Add custom timing header (in milliseconds)
      headers['X-Runtime'] = format('%.3f', duration * 1000)
      
      # Report to monitoring if in production
      if Rails.env.production? && defined?(NewRelic)
        NewRelic::Agent.record_metric('Custom/RequestTime', duration)
      end
      
      [status, headers, body]
    end
  }

  # Initialize and run the Rails application
  run Rails.application

  # Log successful initialization in production
  if Rails.env.production?
    initialization_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - request_start
    Rails.logger.info(
      {
        event: 'rack_initialization',
        duration_ms: (initialization_time * 1000).round(2),
        environment: Rails.env,
        ruby_version: RUBY_VERSION,
        rack_version: Rack.release
      }.to_json
    )
  end

rescue StandardError => e
  # Log initialization errors
  Rails.logger.error(
    {
      event: 'rack_initialization_error',
      error_class: e.class.name,
      error_message: e.message,
      backtrace: e.backtrace&.first(10),
      environment: Rails.env
    }.to_json
  )
  raise e
end