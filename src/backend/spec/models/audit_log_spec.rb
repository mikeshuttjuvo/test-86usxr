# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AuditLog, type: :model do
  # Configure DatabaseCleaner strategy
  before(:each) do
    DatabaseCleaner.strategy = :transaction
    DatabaseCleaner.start
  end

  after(:each) do
    DatabaseCleaner.clean
  end

  # Shared test data
  let(:valid_attributes) do
    {
      action: 'create',
      resource_type: 'Location',
      resource_id: 1,
      changes: { 'name' => ['old', 'new'] },
      user_id: 1,
      ip_address: '127.0.0.1'
    }
  end

  let(:sensitive_changes) do
    {
      'password' => ['old_pass', 'new_pass'],
      'credit_card' => ['4111111111111111', '4222222222222222'],
      'name' => ['old_name', 'new_name']
    }
  end

  describe 'validations' do
    it { should validate_presence_of(:action) }
    it { should validate_presence_of(:resource_type) }
    it { should validate_presence_of(:resource_id) }
    it { should validate_presence_of(:changes) }
    it { should validate_presence_of(:user_id) }
    it { should validate_presence_of(:ip_address) }

    it { should validate_inclusion_of(:action).in_array(AuditLog::VALID_ACTIONS) }

    it 'validates changes is a hash' do
      audit_log = AuditLog.new(valid_attributes.merge(changes: 'not a hash'))
      expect(audit_log).not_to be_valid
      expect(audit_log.errors[:changes]).to include('must be a hash')
    end
  end

  describe 'immutability' do
    let(:audit_log) { AuditLog.create!(valid_attributes) }

    it 'becomes readonly after creation' do
      expect(audit_log.readonly?).to be true
    end

    it 'prevents updates after creation' do
      expect {
        audit_log.update(action: 'update')
      }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it 'prevents deletion after creation' do
      expect {
        audit_log.destroy
      }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end
  end

  describe '.log_action' do
    context 'with valid parameters' do
      it 'creates a new audit log entry' do
        expect {
          AuditLog.log_action(**valid_attributes)
        }.to change(AuditLog, :count).by(1)
      end

      it 'sets created_at to UTC time' do
        Timecop.freeze do
          audit_log = AuditLog.log_action(**valid_attributes)
          expect(audit_log.created_at).to eq(Time.current.utc)
        end
      end

      it 'sanitizes sensitive data in changes' do
        audit_log = AuditLog.log_action(**valid_attributes.merge(changes: sensitive_changes))
        expect(audit_log.changes['password']).to eq('[REDACTED]')
        expect(audit_log.changes['credit_card']).to eq('[REDACTED]')
        expect(audit_log.changes['name']).to eq(['old_name', 'new_name'])
      end
    end

    context 'with invalid parameters' do
      it 'raises ArgumentError for missing required parameters' do
        expect {
          AuditLog.log_action(action: 'create')
        }.to raise_error(ArgumentError)
      end

      it 'raises validation error for invalid action' do
        expect {
          AuditLog.log_action(**valid_attributes.merge(action: 'invalid'))
        }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end

    context 'with database errors' do
      before do
        allow(ActiveRecord::Base.connection).to receive(:execute).and_raise(ActiveRecord::StatementInvalid)
      end

      it 'handles database errors gracefully' do
        expect(Rails.logger).to receive(:error).with(/Failed to create audit log/)
        expect {
          AuditLog.log_action(**valid_attributes)
        }.to raise_error(ActiveRecord::StatementInvalid)
      end
    end
  end

  describe '.for_resource' do
    let!(:location_logs) do
      3.times.map do |i|
        AuditLog.create!(valid_attributes.merge(
          resource_id: 1,
          created_at: i.hours.ago
        ))
      end
    end

    let!(:other_logs) do
      2.times.map do
        AuditLog.create!(valid_attributes.merge(
          resource_id: 2,
          created_at: 1.hour.ago
        ))
      end
    end

    it 'returns logs for specific resource' do
      logs = AuditLog.for_resource('Location', 1)
      expect(logs.length).to eq(3)
      expect(logs.map(&:resource_id).uniq).to eq([1])
    end

    it 'orders logs by created_at desc' do
      logs = AuditLog.for_resource('Location', 1)
      expect(logs.map(&:created_at)).to eq(logs.map(&:created_at).sort.reverse)
    end

    it 'utilizes caching' do
      expect(REDIS_CACHE_POOL).to receive(:with).and_call_original
      AuditLog.for_resource('Location', 1)
    end

    it 'handles cache misses gracefully' do
      allow(REDIS_CACHE_POOL).to receive(:with).and_raise(Redis::CannotConnectError)
      expect {
        AuditLog.for_resource('Location', 1)
      }.not_to raise_error
    end
  end

  describe '.within_period' do
    before do
      Timecop.freeze(Time.current) do
        3.times do |i|
          AuditLog.create!(valid_attributes.merge(created_at: i.days.ago))
        end
      end
    end

    it 'returns logs within date range' do
      start_date = 2.days.ago
      end_date = Time.current

      logs = AuditLog.within_period(start_date, end_date)
      expect(logs.count).to eq(2)
    end

    it 'raises error for invalid date range' do
      expect {
        AuditLog.within_period(1.day.ago, 2.days.ago)
      }.to raise_error(ArgumentError, 'Invalid date range')
    end

    it 'handles timezone conversions correctly' do
      Timecop.freeze(Time.current) do
        start_date = 1.day.ago.in_time_zone('Pacific/Auckland')
        end_date = Time.current.in_time_zone('Pacific/Auckland')
        
        logs = AuditLog.within_period(start_date, end_date)
        expect(logs.map(&:created_at)).to all(be_between(start_date, end_date))
      end
    end
  end

  describe '.cleanup_old_records' do
    before do
      Timecop.freeze(Time.current) do
        3.times do |i|
          AuditLog.create!(valid_attributes.merge(created_at: (i * 30).days.ago))
        end
      end
    end

    it 'removes records older than retention period' do
      expect {
        AuditLog.cleanup_old_records
      }.to change(AuditLog, :count).by(-1)
    end

    it 'processes records in batches' do
      expect(AuditLog).to receive(:in_batches).with(of: AuditLog::BATCH_SIZE)
      AuditLog.cleanup_old_records
    end

    it 'maintains data integrity during cleanup' do
      recent_log = AuditLog.create!(valid_attributes.merge(created_at: 1.day.ago))
      AuditLog.cleanup_old_records
      expect(AuditLog.find_by(id: recent_log.id)).to be_present
    end
  end

  describe 'scopes' do
    before do
      3.times { AuditLog.create!(valid_attributes) }
    end

    describe '.recent' do
      it 'returns latest 100 records' do
        expect(AuditLog.recent.count).to be <= 100
        expect(AuditLog.recent.to_sql).to include('LIMIT 100')
      end

      it 'orders by created_at desc' do
        logs = AuditLog.recent
        expect(logs.map(&:created_at)).to eq(logs.map(&:created_at).sort.reverse)
      end
    end

    describe '.by_action' do
      it 'filters by action type' do
        update_log = AuditLog.create!(valid_attributes.merge(action: 'update'))
        logs = AuditLog.by_action('update')
        expect(logs).to include(update_log)
        expect(logs.count).to eq(1)
      end
    end

    describe '.by_user' do
      it 'filters by user_id' do
        other_user_log = AuditLog.create!(valid_attributes.merge(user_id: 999))
        logs = AuditLog.by_user(999)
        expect(logs).to include(other_user_log)
        expect(logs.count).to eq(1)
      end
    end
  end
end