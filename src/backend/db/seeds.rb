# frozen_string_literal: true

##
# Database seed file implementing secure data initialization with environment-specific
# configuration, transaction safety, and comprehensive error handling.
#
# @version 1.0.0
# @see Technical Specifications/7.1/Authentication and Authorization
# @see Technical Specifications/1.3/Core Features/Location Management
# @see Technical Specifications/1.3/Core Features/Job Management

require 'logger'
require 'securerandom'

# Initialize seeding logger
SEED_LOGGER = Logger.new(Rails.root.join('log', 'seeds.log'))
SEED_LOGGER.level = Rails.env.production? ? Logger::INFO : Logger::DEBUG

# Environment-specific configuration
SEED_CONFIG = {
  development: {
    clean_existing: true,
    sample_data: true,
    admin_email: 'admin@example.com',
    locations_count: 5,
    jobs_per_location: 3
  },
  staging: {
    clean_existing: false,
    sample_data: true,
    admin_email: 'staging.admin@example.com',
    locations_count: 3,
    jobs_per_location: 2
  },
  production: {
    clean_existing: false,
    sample_data: false,
    admin_email: ENV.fetch('ADMIN_EMAIL', 'admin@production.com'),
    locations_count: 0,
    jobs_per_location: 0
  }
}.freeze

# Sample location data with proper geocoding information
SAMPLE_LOCATIONS = [
  {
    name: 'HQ Office',
    address: '123 Main St, New York, NY 10001',
    latitude: 40.7505,
    longitude: -73.9934
  },
  {
    name: 'West Coast Branch',
    address: '456 Market St, San Francisco, CA 94105',
    latitude: 37.7897,
    longitude: -122.3981
  },
  {
    name: 'Chicago Office',
    address: '789 Michigan Ave, Chicago, IL 60601',
    latitude: 41.8781,
    longitude: -87.6298
  }
].freeze

# Job status enumeration
JOB_STATUSES = %w[pending active completed cancelled].freeze

begin
  # Get environment-specific configuration
  env_config = SEED_CONFIG[Rails.env.to_sym]
  
  SEED_LOGGER.info("Starting database seeding for #{Rails.env} environment")
  
  ActiveRecord::Base.transaction do
    # Clean existing data if configured
    if env_config[:clean_existing]
      SEED_LOGGER.info('Cleaning existing data...')
      Job.unscoped.destroy_all
      Location.unscoped.destroy_all
      User.unscoped.destroy_all
    end

    # Create admin user with secure credentials
    SEED_LOGGER.info('Creating admin user...')
    admin_password = Rails.env.production? ? ENV.fetch('ADMIN_PASSWORD') : SecureRandom.hex(12)
    
    admin_user = User.create!(
      email: env_config[:admin_email],
      password: admin_password,
      password_confirmation: admin_password,
      role: 'admin',
      first_name: 'System',
      last_name: 'Administrator',
      active: true
    )

    SEED_LOGGER.info("Admin user created with email: #{admin_user.email}")
    SEED_LOGGER.info("Admin password: #{admin_password}") unless Rails.env.production?

    # Create sample locations if enabled
    if env_config[:sample_data]
      SEED_LOGGER.info('Creating sample locations...')
      
      created_locations = SAMPLE_LOCATIONS.take(env_config[:locations_count]).map do |location_data|
        Location.create!(
          name: location_data[:name],
          address: location_data[:address],
          latitude: location_data[:latitude],
          longitude: location_data[:longitude],
          active: true,
          geocoding_status: 'completed',
          geocoding_metadata: {
            source: 'seed_data',
            created_at: Time.current.iso8601
          }
        ).tap do |location|
          SEED_LOGGER.debug("Created location: #{location.name}")
        end
      end

      # Create sample jobs for each location
      SEED_LOGGER.info('Creating sample jobs...')
      
      created_locations.each do |location|
        env_config[:jobs_per_location].times do |i|
          start_date = Time.current + (i + 1).days
          end_date = start_date + 8.hours
          
          Job.create!(
            location: location,
            title: "Sample Job #{i + 1} at #{location.name}",
            description: "This is a sample job created for testing purposes at #{location.name}",
            status: JOB_STATUSES.sample,
            start_date: start_date,
            end_date: end_date,
            active: true
          ).tap do |job|
            SEED_LOGGER.debug("Created job: #{job.title}")
          end
        end
      end
    end

    # Verify data integrity
    SEED_LOGGER.info('Verifying data integrity...')
    
    admin_count = User.where(role: 'admin').count
    location_count = Location.count
    job_count = Job.count

    SEED_LOGGER.info("Verification complete: #{admin_count} admins, #{location_count} locations, #{job_count} jobs")
  end

  SEED_LOGGER.info('Database seeding completed successfully')
rescue StandardError => e
  SEED_LOGGER.error("Seeding failed: #{e.message}")
  SEED_LOGGER.error(e.backtrace.join("\n"))
  raise e
end