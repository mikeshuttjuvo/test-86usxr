# frozen_string_literal: true

# Factory Bot factory definition for Job model with comprehensive traits and scenarios
# @version 1.0.0
FactoryBot.define do
  factory :job do
    # Required associations
    association :location, factory: :location, strategy: :create

    # Default attributes using Faker for realistic test data
    title { Faker::Job.title }
    description { Faker::Lorem.paragraph(sentence_count: 3) }
    status { 'pending' }
    start_date { 1.day.from_now }
    end_date { 2.days.from_now }
    active { true }

    # Sequences for unique values when needed
    sequence(:title) { |n| "#{Faker::Job.title} #{n}" }
    sequence(:description) { |n| "#{Faker::Lorem.paragraph} - Version #{n}" }

    # Trait for pending jobs (default state)
    trait :pending do
      status { 'pending' }
      start_date { 1.day.from_now }
      end_date { 2.days.from_now }
    end

    # Trait for active jobs
    trait :active do
      status { 'active' }
      start_date { Time.current }
      end_date { 1.day.from_now }
    end

    # Trait for completed jobs
    trait :completed do
      status { 'completed' }
      start_date { 2.days.ago }
      end_date { 1.day.ago }
    end

    # Trait for cancelled jobs
    trait :cancelled do
      status { 'cancelled' }
      start_date { 1.day.ago }
      end_date { nil }
    end

    # Trait for inactive/soft-deleted jobs
    trait :inactive do
      active { false }
      deleted_at { Time.current }
    end

    # Trait for jobs with minimum duration
    trait :minimum_duration do
      start_date { Time.current }
      end_date { Time.current + Job::MIN_DATE_RANGE }
    end

    # Trait for jobs with maximum duration
    trait :maximum_duration do
      start_date { Time.current }
      end_date { Time.current + Job::MAX_DATE_RANGE }
    end

    # Trait for jobs with long descriptions
    trait :long_description do
      description { Faker::Lorem.paragraph(sentence_count: 20) }
    end

    # Trait for jobs with HTML content in description
    trait :html_description do
      description { "<p>#{Faker::Lorem.paragraph}</p><ul><li>#{Faker::Lorem.sentence}</li></ul>" }
    end

    # Callbacks for dynamic attribute generation
    after(:build) do |job|
      # Ensure end_date is always after start_date
      if job.start_date && job.end_date && job.end_date <= job.start_date
        job.end_date = job.start_date + 1.day
      end
    end

    # Transient attributes for flexible factory usage
    transient do
      duration { 24.hours }
    end

    # Dynamic date calculation based on duration
    after(:build) do |job, evaluator|
      if evaluator.duration && job.start_date
        job.end_date = job.start_date + evaluator.duration
      end
    end
  end
end