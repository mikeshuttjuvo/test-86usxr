# frozen_string_literal: true

# Factory definitions for User model testing with comprehensive scenarios for
# authentication, authorization, and security features.
#
# @version 1.0.0
# @see Technical Specifications/7.1/Authentication and Authorization
FactoryBot.define do
  factory :user do
    # Basic user attributes with secure defaults
    email { Faker::Internet.unique.email }
    password { 'Password1@3456' }
    password_confirmation { 'Password1@3456' }
    first_name { Faker::Name.first_name }
    last_name { Faker::Name.last_name }
    role { 'user' }
    active { true }
    jti { SecureRandom.uuid }
    failed_attempts { 0 }

    # Ensure password meets security requirements
    after(:build) do |user|
      user.encrypted_password = BCrypt::Password.create(user.password) if user.password.present?
    end

    # Trait for admin users
    trait :admin do
      role { 'admin' }
      after(:create) do |user|
        user.create_audit_entry('role_assignment', 'Admin role assigned during factory creation')
      end
    end

    # Trait for manager users
    trait :manager do
      role { 'manager' }
      after(:create) do |user|
        user.create_audit_entry('role_assignment', 'Manager role assigned during factory creation')
      end
    end

    # Trait for inactive users
    trait :inactive do
      active { false }
      after(:create) do |user|
        user.create_audit_entry('status_change', 'User marked as inactive during factory creation')
      end
    end

    # Trait for locked users (exceeded login attempts)
    trait :locked do
      failed_attempts { User::MAX_LOGIN_ATTEMPTS }
      locked_at { Time.current }
      after(:create) do |user|
        user.create_audit_entry('account_locked', 'Account locked due to exceeded login attempts')
      end
    end

    # Trait for soft-deleted users
    trait :soft_deleted do
      deleted_at { Time.current }
      active { false }
      after(:create) do |user|
        user.create_audit_entry('soft_delete', 'User soft deleted during factory creation')
      end
    end

    # Trait for users with custom password
    trait :with_custom_password do
      transient do
        custom_password { 'CustomPass1@3456' }
      end

      password { custom_password }
      password_confirmation { custom_password }

      after(:build) do |user, evaluator|
        user.encrypted_password = BCrypt::Password.create(evaluator.custom_password)
      end
    end

    # Factory for testing password validation
    factory :user_with_invalid_password do
      password { 'weak' }
      password_confirmation { 'weak' }
    end

    # Factory for testing email validation
    factory :user_with_invalid_email do
      email { 'invalid_email' }
    end

    # Sequences for generating unique test data
    sequence(:unique_email) { |n| "user#{n}@example.com" }
    sequence(:unique_jti) { SecureRandom.uuid }

    # Callbacks for all user factories
    after(:build) do |user|
      # Ensure JTI is always present
      user.jti ||= generate(:unique_jti)
    end

    after(:create) do |user|
      # Create initial audit log entry
      user.create_audit_entry('user_created', 'User created via factory')
      
      # Cache user data
      Rails.cache.write("user:#{user.id}:role", user.role, expires_in: User::CACHE_TTL)
    end
  end

  # Named factories for common testing scenarios
  factory :admin_user, parent: :user do
    role { 'admin' }
  end

  factory :manager_user, parent: :user do
    role { 'manager' }
  end

  factory :inactive_user, parent: :user do
    active { false }
  end
end