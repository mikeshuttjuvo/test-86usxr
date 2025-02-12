# frozen_string_literal: true

# factory_bot_rails ~> 6.2 - Test data generation framework
require 'factory_bot'
# rspec-rails ~> 6.0.0 - Testing framework integration
require 'rspec'

# Configure FactoryBot for test data generation
RSpec.configure do |config|
  # Include FactoryBot methods in RSpec tests
  config.include FactoryBot::Syntax::Methods

  # Configure FactoryBot settings before tests run
  config.before(:suite) do
    # Set factory definition paths
    FactoryBot.definition_file_paths = ['spec/factories']
    
    # Enable parent strategy for factory inheritance
    FactoryBot.use_parent_strategy = true
    
    # Disable verbose download output
    FactoryBot.verbose_download = false
    
    # Find and load all factory definitions
    FactoryBot.find_definitions
    
    # Lint factories to ensure they are valid and can create objects
    begin
      DatabaseCleaner.start
      FactoryBot.lint traits: true
    ensure
      DatabaseCleaner.clean
    end
  end

  # Reset factory sequences between tests
  config.before(:each) do
    FactoryBot.reload
  end
end

# Configure FactoryBot directly
FactoryBot.configure do |config|
  # Set the default directory for factories
  config.factory_paths = ['spec/factories']
  
  # Enable generation of dynamic attributes
  config.generator_strategy = :dynamic
  
  # Use create strategy by default
  config.use_parent_strategy = true
  
  # Disable verbose download messages
  config.verbose_download = false
end