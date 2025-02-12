# frozen_string_literal: true

# Core testing framework for BDD testing capabilities
require 'rspec' # ~> 6.0.0

# Code coverage analysis tool
require 'simplecov' # ~> 0.22.0

# Configure SimpleCov for code coverage analysis
SimpleCov.start do
  # Set minimum coverage threshold to 100% per requirements
  minimum_coverage 100

  # Set coverage output directory
  coverage_dir 'coverage'

  # Configure formatters for different output formats
  formatters = [
    SimpleCov::Formatter::HTMLFormatter,
    SimpleCov::Formatter::JSONFormatter
  ]
  formatter SimpleCov::Formatter::MultiFormatter.new(formatters)

  # Define groups for better coverage reporting organization
  add_group 'Controllers', 'app/controllers'
  add_group 'Models', 'app/models'
  add_group 'Services', 'app/services'
  add_group 'Jobs', 'app/jobs'
  add_group 'Serializers', 'app/serializers'

  # Exclude test files and configuration from coverage
  add_filter 'spec/'
  add_filter 'config/'
  add_filter 'db/'
end

# Core RSpec configuration
RSpec.configure do |config|
  # Expectations configuration
  config.expect_with :rspec do |expectations|
    # Include chain clauses in custom matcher descriptions for better error messages
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  # Mocking configuration
  config.mock_with :rspec do |mocks|
    # Verify partial doubles to ensure mocked methods exist
    mocks.verify_partial_doubles = true

    # Verify doubled constant names to catch typos and incorrect constants
    mocks.verify_doubled_constant_names = true
  end

  # Ensure shared context metadata is applied consistently
  config.shared_context_metadata_behavior = :apply_to_host_groups

  # Store example status for better failure tracking
  config.example_status_persistence_file_path = 'spec/examples.txt'

  # Enable warnings to catch potential issues
  config.warnings = true

  # Run specs in random order to surface order dependencies
  config.order = :random

  # Profile slow examples
  config.profile_examples = 10

  # Use documentation formatter for readable output
  config.default_formatter = 'doc'

  # Allow focusing on specific examples with focus: true
  config.filter_run_when_matching :focus

  # Disable monkey patching for more explicit tests
  config.disable_monkey_patching!

  # Print the 10 slowest examples
  config.profile_examples = 10

  # Seed global randomization in this process using the `--seed` CLI option
  Kernel.srand config.seed
end