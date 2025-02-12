# frozen_string_literal: true

# Shoulda Matchers configuration file for RSpec test framework
# Version: shoulda-matchers ~> 5.0
#
# This configuration enables enhanced matchers for:
# - ActiveRecord model validations and associations
# - ActiveModel validations
# - ActionController tests
#
# These matchers help maintain comprehensive test coverage and quality standards

require 'shoulda-matchers'

# Configure Shoulda Matchers with RSpec test framework and Rails components
Shoulda::Matchers.configure do |config|
  # Specify the test framework as RSpec
  config.integrate do |with|
    with.test_framework :rspec

    # Enable Rails library components for comprehensive testing
    with.library :rails do |library|
      library.enable :active_record  # For model associations and database operations
      library.enable :active_model   # For model validations
      library.enable :action_controller # For controller tests
    end
  end
end

# Include Shoulda Matchers in RSpec configuration
RSpec.configure do |config|
  # Make Shoulda Matchers' matchers available in RSpec examples
  config.include Shoulda::Matchers::ActiveRecord
  config.include Shoulda::Matchers::ActiveModel
  config.include Shoulda::Matchers::ActionController
end