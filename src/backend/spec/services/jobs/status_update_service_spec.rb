# frozen_string_literal: true

require 'rails_helper'
require 'benchmark-ips'

RSpec.describe StatusUpdateService do
  # Test setup
  let(:location) { create(:location) }
  let(:job) { create(:job, location: location, status: 'pending') }
  let(:user_id) { 1 }
  let(:context) do
    {
      user_id: user_id,
      reason: 'Status update test',
      source: 'api',
      ip_address: '127.0.0.1',
      correlation_id: SecureRandom.uuid,
      metadata: { test: true }
    }
  end

  describe '#perform' do
    context 'with valid status transition' do
      let(:new_status) { 'active' }
      let(:service) { described_class.new(job: job, new_status: new_status, context: context) }

      it 'successfully updates job status' do
        expect(service.send(:perform)).to be true
        expect(job.reload.status).to eq(new_status)
      end

      it 'creates an audit log entry' do
        expect(AuditLogJob).to receive(:perform_later).with(
          hash_including(
            action: 'status_update',
            resource_type: 'Job',
            resource_id: job.id,
            changes: hash_including(
              status: {
                from: 'pending',
                to: 'active'
              }
            ),
            user_id: user_id
          )
        )

        service.send(:perform)
      end

      it 'invalidates related caches' do
        expect_any_instance_of(Job).to receive(:invalidate_cache)
        expect_any_instance_of(Location).to receive(:invalidate_cache)
        
        service.send(:perform)
      end

      it 'meets performance requirements' do
        benchmark = Benchmark.measure { service.send(:perform) }
        expect(benchmark.real).to be < 0.5 # 500ms requirement
      end
    end

    context 'with invalid status transition' do
      let(:new_status) { 'completed' }
      let(:service) { described_class.new(job: job, new_status: new_status, context: context) }

      it 'fails to update job status' do
        expect(service.send(:perform)).to be false
        expect(job.reload.status).to eq('pending')
      end

      it 'adds appropriate error message' do
        service.send(:perform)
        expect(service.errors).to include(
          hash_including(
            type: 'status_update_error',
            message: 'Cannot transition from pending to completed'
          )
        )
      end

      it 'does not create audit log' do
        expect(AuditLogJob).not_to receive(:perform_later)
        service.send(:perform)
      end

      it 'does not invalidate caches' do
        expect_any_instance_of(Job).not_to receive(:invalidate_cache)
        expect_any_instance_of(Location).not_to receive(:invalidate_cache)
        
        service.send(:perform)
      end
    end

    context 'with missing job' do
      let(:service) { described_class.new(job: nil, new_status: 'active', context: context) }

      it 'fails gracefully' do
        expect(service.send(:perform)).to be false
      end

      it 'adds appropriate error message' do
        service.send(:perform)
        expect(service.errors).to include(
          hash_including(
            type: 'status_update_error',
            message: 'Job not found'
          )
        )
      end
    end

    context 'with transaction safety' do
      let(:new_status) { 'active' }
      let(:service) { described_class.new(job: job, new_status: new_status, context: context) }

      it 'rolls back changes on error' do
        allow(job).to receive(:update_status).and_raise(ActiveRecord::RecordInvalid)
        
        expect {
          service.send(:perform)
        }.not_to change { job.reload.status }
      end

      it 'maintains data consistency on error' do
        allow(AuditLogJob).to receive(:perform_later).and_raise(StandardError)
        
        expect {
          service.send(:perform)
        }.not_to change { job.reload.status }
      end
    end

    context 'with authorization' do
      let(:new_status) { 'active' }

      context 'with valid user' do
        let(:service) { described_class.new(job: job, new_status: new_status, context: context) }

        it 'allows status update' do
          expect(service.send(:perform)).to be true
        end
      end

      context 'without user' do
        let(:service) { described_class.new(job: job, new_status: new_status, context: {}) }

        it 'prevents status update' do
          expect(service.send(:perform)).to be false
        end

        it 'adds authorization error' do
          service.send(:perform)
          expect(service.errors).to include(
            hash_including(
              type: 'status_update_error',
              message: 'Unauthorized access'
            )
          )
        end
      end
    end

    context 'with cache operations' do
      let(:new_status) { 'active' }
      let(:service) { described_class.new(job: job, new_status: new_status, context: context) }

      it 'invalidates job status caches' do
        expect_any_instance_of(Redis).to receive(:del).with("jobs:status:pending")
        expect_any_instance_of(Redis).to receive(:del).with("jobs:status:active")
        
        service.send(:perform)
      end

      it 'invalidates location-based caches' do
        expect_any_instance_of(Redis).to receive(:del).with("jobs:location:#{job.location_id}")
        
        service.send(:perform)
      end
    end

    context 'with performance benchmarking' do
      let(:new_status) { 'active' }
      let(:service) { described_class.new(job: job, new_status: new_status, context: context) }

      it 'completes status update within time limit' do
        report = Benchmark.ips do |x|
          x.config(time: 1, warmup: 0)
          x.report('status_update') { service.send(:perform) }
        end

        expect(report.entries.first.stats.central_tendency).to be < 0.5
      end
    end
  end
end