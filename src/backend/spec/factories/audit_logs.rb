# frozen_string_literal: true

# Factory definition for AuditLog model
# Supports testing of audit logging functionality with enhanced compliance and security monitoring
#
# @version 1.0.0
# @see Technical Specifications/7.3.3/Security Monitoring
# @see Technical Specifications/7.3.4/Compliance Requirements
FactoryBot.define do
  factory :audit_log do
    # Basic attributes for audit log entries
    action { AuditLog::VALID_ACTIONS.sample }
    resource_type { AuditLog::AUDITABLE_TYPES.sample }
    sequence(:resource_id) { |n| n }
    changes { {} }
    sequence(:user_id) { |n| n }
    ip_address { Faker::Internet.ip_v4_address }
    created_at { Time.current }

    # Trait for comprehensive change tracking
    trait :with_changes do
      changes do
        {
          'name' => ['Old Name', 'New Name'],
          'status' => ['inactive', 'active'],
          'address' => ['123 Old St', '456 New Ave'],
          'updated_at' => [1.day.ago.iso8601, Time.current.iso8601]
        }
      end
    end

    # Trait for location-specific audits
    trait :for_location do
      resource_type { 'Location' }
      changes do
        {
          'name' => ['Previous Location', 'Updated Location'],
          'address' => ['123 Previous St', '456 Current Ave'],
          'latitude' => ['40.7128', '40.7129'],
          'longitude' => ['-74.0060', '-74.0061'],
          'active' => [true, false]
        }
      end
    end

    # Trait for job-specific audits
    trait :for_job do
      resource_type { 'Job' }
      changes do
        {
          'title' => ['Previous Title', 'Updated Title'],
          'description' => ['Old description', 'New description'],
          'status' => ['pending', 'active'],
          'start_date' => [1.day.ago.iso8601, Time.current.iso8601],
          'end_date' => [1.week.from_now.iso8601, 2.weeks.from_now.iso8601]
        }
      end
    end

    # Trait for creation audits
    trait :create_action do
      action { 'create' }
      changes do
        {
          'id' => [nil, 1],
          'created_at' => [nil, Time.current.iso8601],
          'updated_at' => [nil, Time.current.iso8601]
        }
      end
    end

    # Trait for update audits
    trait :update_action do
      action { 'update' }
    end

    # Trait for delete audits
    trait :delete_action do
      action { 'delete' }
      changes { { 'active' => [true, false], 'deleted_at' => [nil, Time.current.iso8601] } }
    end

    # Trait for soft delete audits
    trait :soft_delete_action do
      action { 'soft_delete' }
      changes { { 'active' => [true, false], 'deleted_at' => [nil, Time.current.iso8601] } }
    end

    # Trait for restore audits
    trait :restore_action do
      action { 'restore' }
      changes { { 'active' => [false, true], 'deleted_at' => [Time.current.iso8601, nil] } }
    end

    # Trait for permanent delete audits
    trait :permanent_delete_action do
      action { 'permanent_delete' }
      changes { { 'active' => [false, nil], 'deleted_at' => [Time.current.iso8601, nil] } }
    end

    # Trait for compliance-related audits with sensitive data handling
    trait :with_sensitive_data do
      changes do
        {
          'password' => ['[REDACTED]', '[REDACTED]'],
          'token' => ['[REDACTED]', '[REDACTED]'],
          'credit_card' => ['[REDACTED]', '[REDACTED]'],
          'ssn' => ['[REDACTED]', '[REDACTED]'],
          'tax_id' => ['[REDACTED]', '[REDACTED]']
        }
      end
    end

    # Trait for suspicious activity audits
    trait :suspicious_activity do
      ip_address { '192.168.1.1' }
      changes do
        {
          'login_attempts' => [3, 4],
          'last_failed_login' => [1.hour.ago.iso8601, Time.current.iso8601],
          'account_locked' => [false, true]
        }
      end
    end
  end
end