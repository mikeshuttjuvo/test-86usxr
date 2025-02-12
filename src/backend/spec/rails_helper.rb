# frozen_string_literal: true

# Configure Rails Environment
ENV['RAILS_ENV'] ||= 'test'

# Load Rails and testing frameworks
require File.expand_path('../config/environment', __dir__)
require 'spec_helper'
require 'rspec/rails'
require 'database_cleaner/active_record'
require 'webmock/rspec'
require 'shoulda/matchers'
require 'factory_bot_rails'

# Prevent database truncation if the environment is production
abort('The Rails environment is running in production mode!') if Rails.env.production?

# Load support files
Dir[Rails.root.join('spec/support/**/*.rb')].sort.each { |f| require f }

# Configure RSpec Rails
RSpec.configure do |config|
  # Enable support for ActiveRecord fixtures
  config.fixture_path = Rails.root.join('spec/fixtures')

  # Use transactions for faster test database cleanup
  config.use_transactional_fixtures = true

  # Infer spec type from file location
  config.infer_spec_type_from_file_location!

  # Filter lines from Rails gems in backtraces
  config.filter_rails_from_backtrace!

  # Include request spec helpers
  config.include RequestSpecHelper, type: :request

  # Configure DatabaseCleaner
  config.before(:suite) do
    DatabaseCleaner.strategy = :transaction
    DatabaseCleaner.clean_with(:truncation)
  end

  config.around(:each) do |example|
    DatabaseCleaner.cleaning do
      example.run
    end
  end

  # Configure FactoryBot
  config.include FactoryBot::Syntax::Methods

  # Configure time helpers
  config.include ActiveSupport::Testing::TimeHelpers

  # Configure custom error tracking
  config.after(:each) do |example|
    if example.exception
      NewRelic::Agent.notice_error(
        example.exception,
        custom_params: {
          spec_location: example.metadata[:location],
          spec_description: example.metadata[:full_description]
        }
      )
    end
  end

  # Configure performance monitoring
  config.after(:suite) do
    performance_report = File.join(Rails.root, 'tmp/test_performance.log')
    File.write(
      performance_report,
      RSpec.configuration.reporter.examples
        .select { |e| e.execution_result.run_time > 1.0 }
        .map { |e| "#{e.full_description}: #{e.execution_result.run_time}s" }
        .join("\n")
    )
  end
end

# Configure Shoulda Matchers
Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :rspec
    with.library :rails
  end
end

# Configure WebMock
WebMock.disable_net_connect!(
  allow_localhost: true,
  allow: [
    'chromedriver.storage.googleapis.com',
    'api.newrelic.com'
  ]
)

# Configure test coverage thresholds
SimpleCov.minimum_coverage 100
SimpleCov.minimum_coverage_by_file 100
SimpleCov.refuse_coverage_drop

# Configure custom matchers for API testing
RSpec::Matchers.define :match_json_schema do |schema|
  match do |response|
    schema_directory = "#{Dir.pwd}/spec/support/schemas"
    schema_path = "#{schema_directory}/#{schema}.json"
    JSON::Validator.validate!(schema_path, response.body, strict: true)
  end
end

# Configure custom matchers for error responses
RSpec::Matchers.define :be_a_valid_error_response do
  match do |response|
    response.content_type == 'application/problem+json' &&
      JSON.parse(response.body).keys.sort == %w[detail status title type].sort
  end
end

# Configure RSpec retry for flaky tests
require 'rspec/retry'
RSpec.configure do |config|
  config.verbose_retry = true
  config.display_try_failure_messages = true
  config.around :each, :retry do |example|
    example.run_with_retry retry: 3
  end
end

# Configure time zone for tests
Time.zone = 'UTC'