# frozen_string_literal: true

# Factory definition for Location model with comprehensive test data generation support
# @version 1.0.0
# @see Technical Specifications/3.2.1/Schema Design
FactoryBot.define do
  # Sequences for generating unique location data
  sequence :location_name do |n|
    "#{['Store', 'Office', 'Warehouse', 'Factory', 'Shop'].sample} #{n}"
  end

  sequence :location_address do |n|
    "#{n} #{['Main', 'Oak', 'Maple', 'Cedar', 'Pine'].sample} #{['Street', 'Avenue', 'Boulevard', 'Road'].sample}, #{['New York', 'Los Angeles', 'Chicago', 'Houston'].sample}, #{['NY', 'CA', 'IL', 'TX'].sample} #{10000 + n}"
  end

  factory :location do
    name { generate(:location_name) }
    address { generate(:location_address) }
    latitude { nil }
    longitude { nil }
    active { true }
    geocoding_status { 'pending' }
    geocoding_metadata { {} }
    created_at { Time.current }
    updated_at { Time.current }

    # Trait for inactive locations
    trait :inactive do
      active { false }
    end

    # Trait for locations with valid coordinates
    trait :with_coordinates do
      latitude { 40.7128 } # New York coordinates
      longitude { -74.0060 }
      geocoding_status { 'completed' }
      geocoding_metadata do
        {
          last_updated: Time.current.iso8601,
          source: 'factory_bot',
          accuracy: 'high'
        }
      end
    end

    # Trait for locations with invalid coordinates
    trait :with_invalid_coordinates do
      latitude { 200.0 }
      longitude { -200.0 }
      geocoding_status { 'failed' }
      geocoding_metadata do
        {
          last_updated: Time.current.iso8601,
          source: 'factory_bot',
          error: 'Invalid coordinates'
        }
      end
    end

    # Trait for soft-deleted locations
    trait :soft_deleted do
      deleted_at { Time.current }
      active { false }
    end

    # Trait for locations with audit trail
    trait :with_audit_trail do
      transient do
        created_by { 'system_user' }
        updated_by { 'system_user' }
        audit_comment { 'Test audit trail' }
      end

      after(:create) do |location, evaluator|
        AuditLogJob.perform_later(
          action: 'create',
          resource_type: 'Location',
          resource_id: location.id,
          changes: location.attributes,
          user_id: evaluator.created_by,
          ip_address: '127.0.0.1'
        )
      end
    end

    # Trait for locations with cache configuration
    trait :cacheable do
      transient do
        cache_version { 1 }
        cache_key { "location_#{Time.current.to_i}" }
      end

      after(:create) do |location, evaluator|
        Rails.cache.write(
          location.cache_key(namespace: 'test'),
          location.attributes,
          expires_in: 1.hour,
          version: evaluator.cache_version
        )
      end
    end

    # Trait for locations pending geocoding
    trait :pending_geocoding do
      geocoding_status { 'pending' }
      geocoding_metadata do
        {
          last_attempt: nil,
          attempts: 0
        }
      end
    end

    # Trait for locations with failed geocoding
    trait :failed_geocoding do
      geocoding_status { 'failed' }
      geocoding_metadata do
        {
          last_attempt: Time.current.iso8601,
          attempts: 3,
          error: 'Geocoding service unavailable'
        }
      end
    end

    # Factory for creating a location with complete data
    factory :complete_location do
      with_coordinates
      with_audit_trail
      cacheable

      after(:create) do |location|
        location.update_coordinates(location.latitude, location.longitude)
      end
    end
  end
end