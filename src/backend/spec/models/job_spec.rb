# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Job, type: :model do
  # Setup test data
  let(:location) { create(:location) }
  let(:job) { create(:job, location: location) }
  let(:pending_job) { create(:job, :pending) }
  let(:active_job) { create(:job, :active) }
  let(:completed_job) { create(:job, :completed) }

  # Clean Redis between tests
  before(:each) do
    Redis.new.flushdb
  end

  describe 'validations' do
    it { should validate_presence_of(:title) }
    it { should validate_presence_of(:description) }
    it { should validate_presence_of(:status) }
    it { should validate_presence_of(:start_date) }
    it { should validate_presence_of(:end_date) }

    it { should validate_length_of(:title).is_at_most(Job::MAX_TITLE_LENGTH) }
    it { should validate_length_of(:description).is_at_most(Job::MAX_DESCRIPTION_LENGTH) }
    
    it { should validate_inclusion_of(:status).in_array(Job::VALID_STATUSES) }

    context 'date validations' do
      it 'validates start_date is not in the past' do
        job = build(:job, start_date: 1.day.ago)
        expect(job).not_to be_valid
        expect(job.errors[:start_date]).to include('cannot be in the past')
      end

      it 'validates end_date is after start_date' do
        job = build(:job, start_date: Time.current, end_date: 1.hour.ago)
        expect(job).not_to be_valid
        expect(job.errors[:end_date]).to include('must be after start date')
      end

      it 'validates minimum job duration' do
        job = build(:job, start_date: Time.current, end_date: Time.current + 30.minutes)
        expect(job).not_to be_valid
        expect(job.errors[:base]).to include('Job duration must be at least 1 hour')
      end

      it 'validates maximum job duration' do
        job = build(:job, start_date: Time.current, end_date: Time.current + 2.years)
        expect(job).not_to be_valid
        expect(job.errors[:base]).to include('Job duration cannot exceed 1 year')
      end
    end
  end

  describe 'associations' do
    it { should belong_to(:location).required }
  end

  describe 'status management' do
    context 'status transitions' do
      it 'allows transition from pending to active' do
        expect(pending_job.update_status('active')).to be true
      end

      it 'allows transition from active to completed' do
        expect(active_job.update_status('completed')).to be true
      end

      it 'allows transition from pending to cancelled' do
        expect(pending_job.update_status('cancelled')).to be true
      end

      it 'prevents transition from completed to active' do
        expect(completed_job.update_status('active')).to be false
      end

      it 'prevents invalid status transitions' do
        job = create(:job, status: 'cancelled')
        expect(job.update_status('active')).to be false
      end
    end

    context 'callbacks' do
      it 'sets default status to pending on create' do
        job = create(:job, status: nil)
        expect(job.status).to eq('pending')
      end
    end
  end

  describe 'audit logging' do
    it 'creates audit log on creation' do
      expect { create(:job) }.to change(AuditLog, :count).by(1)
    end

    it 'creates audit log on update' do
      expect { job.update(title: 'Updated Title') }.to change(AuditLog, :count).by(1)
    end

    it 'creates audit log on deletion' do
      expect { job.destroy }.to change(AuditLog, :count).by(1)
    end

    it 'includes changes in audit log' do
      job.update(title: 'New Title')
      audit_log = AuditLog.last
      expect(audit_log.changes).to include('title')
    end
  end

  describe 'caching' do
    it 'generates correct cache key' do
      expected_key = [
        job.cache_key,
        job.status,
        job.start_date.to_i,
        job.end_date.to_i,
        job.location_id
      ].join(':')
      expect(job.cache_key).to eq(expected_key)
    end

    it 'invalidates cache on update' do
      Rails.cache.write(job.cache_key, job.attributes)
      job.update(title: 'Updated Title')
      expect(Rails.cache.read(job.cache_key)).to be_nil
    end

    it 'invalidates associated location cache' do
      location_key = job.location.cache_key
      Rails.cache.write(location_key, job.location.attributes)
      job.update(title: 'Updated Title')
      expect(Rails.cache.read(location_key)).to be_nil
    end
  end

  describe 'soft deletion' do
    it 'performs soft delete' do
      expect { job.soft_delete }.to change { job.deleted_at }.from(nil)
      expect(job.active).to be false
    end

    it 'excludes soft deleted records from default scope' do
      job.soft_delete
      expect(Job.all).not_to include(job)
    end

    it 'includes soft deleted records in with_deleted scope' do
      job.soft_delete
      expect(Job.with_deleted).to include(job)
    end

    it 'allows restoration of soft deleted records' do
      job.soft_delete
      expect { job.restore }.to change { job.deleted_at }.to(nil)
      expect(job.active).to be true
    end

    it 'creates audit log entry for soft deletion' do
      expect { job.soft_delete }.to change(AuditLog, :count).by(1)
      expect(AuditLog.last.action).to eq('soft_delete')
    end
  end

  describe 'scopes' do
    it 'returns active jobs' do
      active_job = create(:job, :active)
      completed_job = create(:job, :completed)
      expect(Job.active_jobs).to include(active_job)
      expect(Job.active_jobs).not_to include(completed_job)
    end

    it 'returns completed jobs' do
      active_job = create(:job, :active)
      completed_job = create(:job, :completed)
      expect(Job.completed_jobs).to include(completed_job)
      expect(Job.completed_jobs).not_to include(active_job)
    end

    it 'returns upcoming jobs' do
      future_job = create(:job, start_date: 1.day.from_now)
      past_job = create(:job, start_date: 1.day.ago, end_date: Time.current)
      expect(Job.upcoming_jobs).to include(future_job)
      expect(Job.upcoming_jobs).not_to include(past_job)
    end

    it 'filters by location' do
      location1 = create(:location)
      location2 = create(:location)
      job1 = create(:job, location: location1)
      job2 = create(:job, location: location2)
      expect(Job.by_location(location1.id)).to include(job1)
      expect(Job.by_location(location1.id)).not_to include(job2)
    end

    it 'filters by date range' do
      start_date = 1.day.from_now
      end_date = 2.days.from_now
      job_in_range = create(:job, start_date: start_date, end_date: end_date)
      job_out_of_range = create(:job, start_date: 3.days.from_now, end_date: 4.days.from_now)
      expect(Job.date_range(start_date, end_date)).to include(job_in_range)
      expect(Job.date_range(start_date, end_date)).not_to include(job_out_of_range)
    end
  end
end