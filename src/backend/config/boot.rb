# frozen_string_literal: true

# Version: bundler ~> 2.0
# Purpose: Core Rails application boot configuration optimized for cloud-native deployment

# Set the default path to the Gemfile
ENV['BUNDLE_GEMFILE'] ||= File.expand_path('../Gemfile', __dir__)

# Define immutable application path constant
APP_PATH = File.expand_path('../config/application', __dir__).freeze

# Validate and normalize Rails environment
def validate_environment
  # Set default Rails environment if not specified
  ENV['RAILS_ENV'] ||= 'development'
  
  # Normalize Rails environment value
  ENV['RAILS_ENV'] = ENV['RAILS_ENV'].downcase.strip
  
  # Validate environment value
  unless %w[development test staging production].include?(ENV['RAILS_ENV'])
    raise "Invalid RAILS_ENV value: #{ENV['RAILS_ENV']}"
  end
  
  # Configure container-specific settings for cloud deployment
  if ENV['CONTAINER_DEPLOYMENT'] == 'true'
    # Optimize for containerized environments
    ENV['BUNDLE_DEPLOYMENT'] = 'true'
    ENV['BUNDLE_PATH'] = '/usr/local/bundle'
    ENV['BUNDLE_WITHOUT'] = 'development:test' if ENV['RAILS_ENV'] == 'production'
  end
end

begin
  # Initialize boot-time performance monitoring
  boot_start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  
  # Validate deployment environment
  validate_environment
  
  # Configure Bundler for optimal performance in cloud environments
  if ENV['RAILS_ENV'] == 'production'
    # Production optimizations
    ENV['BUNDLE_JOBS'] = ENV['BUNDLE_JOBS'] || '4'
    ENV['BUNDLE_RETRY'] = ENV['BUNDLE_RETRY'] || '3'
    ENV['BUNDLE_CACHE_ALL'] = 'true'
  end
  
  # Configure gem load paths without loading all gems
  require 'bundler/setup'
  
  # Log boot completion time in production for monitoring
  if ENV['RAILS_ENV'] == 'production'
    boot_duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - boot_start_time
    warn "[BOOT] Rails boot.rb completed in #{boot_duration.round(4)}s"
  end
rescue Exception => e
  # Provide detailed error information for boot failures
  warn "[BOOT] Failed to boot Rails application: #{e.message}"
  warn e.backtrace.join("\n")
  raise e
end