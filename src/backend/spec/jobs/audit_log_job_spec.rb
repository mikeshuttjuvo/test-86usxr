# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AuditLogJob, type: :job do
  let(:valid_params) do
    {
      action: 'create',
      resource_type: 'Location',
      resource_id: 1,
      changes: { 'name' => ['Old Name', 'New Name'] },
      user_id: 1,
      ip_address: '127.0.0.1'
    }
  end

  let(:invalid_params) do
    {
      action: nil,
      resource_type: nil,
      resource_id: nil,
      changes: nil,
      user_id: nil,
      ip_address: nil
    }
  end

  describe '#perform' do
    context 'with valid parameters' do
      it 'creates an audit log entry' do
        expect {
          described_class.perform_now(**valid_params)
        }.to change(AuditLog, :count).by(1)
      end

      it 'creates audit log with correct attributes' do
        described_class.perform_now(**valid_params)
        audit_log = AuditLog.last

        expect(audit_log).to have_attributes(
          action: valid_params[:action],
          resource_type: valid_params[:resource_type],
          resource_id: valid_params[:resource_id],
          user_id: valid_params[:user_id],
          ip_address: valid_params[:ip_address]
        )
        expect(JSON.parse(audit_log.changes)).to eq(valid_params[:changes])
      end

      it 'uses read committed transaction isolation' do
        expect(ActiveRecord::Base.connection).to receive(:transaction)
          .with(isolation: :read_committed)
          .and_call_original

        described_class.perform_now(**valid_params)
      end

      it 'sanitizes input parameters' do
        params_with_sql = valid_params.merge(
          action: "create'; DROP TABLE audit_logs; --"
        )
        
        expect {
          described_class.perform_now(**params_with_sql)
        }.not_to raise_error

        audit_log = AuditLog.last
        expect(audit_log.action).to eq('create\'\; DROP TABLE audit_logs\; \-\-')
      end
    end

    context 'with invalid parameters' do
      it 'raises ArgumentError for missing action' do
        expect {
          described_class.perform_now(**invalid_params)
        }.to raise_error(ArgumentError, 'Action must be present')
      end

      it 'raises ArgumentError for missing resource type' do
        expect {
          described_class.perform_now(**invalid_params.merge(action: 'create'))
        }.to raise_error(ArgumentError, 'Resource type must be present')
      end

      it 'raises ArgumentError for missing resource ID' do
        expect {
          described_class.perform_now(**invalid_params.merge(
            action: 'create',
            resource_type: 'Location'
          ))
        }.to raise_error(ArgumentError, 'Resource ID must be present')
      end

      it 'raises ArgumentError for invalid changes format' do
        expect {
          described_class.perform_now(**valid_params.merge(changes: 'invalid'))
        }.to raise_error(ArgumentError, 'Changes must be a hash')
      end
    end

    context 'with database errors' do
      before do
        allow(ActiveRecord::Base.connection).to receive(:execute)
          .and_raise(ActiveRecord::ConnectionError)
      end

      it 'retries on connection error' do
        expect(described_class).to receive(:retry_job).once
        
        expect {
          described_class.perform_now(**valid_params)
        }.to raise_error(ActiveRecord::ConnectionError)
      end

      it 'respects retry configuration' do
        expect(described_class.retry_on_handler)
          .to include(ActiveRecord::ConnectionError)
        expect(described_class.retry_on_handler)
          .to include(ActiveRecord::DeadlockVictimError)
      end

      it 'logs error details' do
        expect(Rails.logger).to receive(:error).with(/Audit log creation failed/)
        
        begin
          described_class.perform_now(**valid_params)
        rescue ActiveRecord::ConnectionError
          nil
        end
      end
    end

    context 'compliance requirements' do
      it 'ensures audit log immutability' do
        described_class.perform_now(**valid_params)
        audit_log = AuditLog.last

        expect {
          audit_log.update(action: 'update')
        }.not_to change { audit_log.reload.action }
      end

      it 'includes all required audit fields' do
        described_class.perform_now(**valid_params)
        audit_log = AuditLog.last

        expect(audit_log.attributes.keys).to include(
          'action',
          'resource_type',
          'resource_id',
          'changes',
          'user_id',
          'ip_address',
          'created_at'
        )
      end

      it 'stores timestamps in UTC' do
        described_class.perform_now(**valid_params)
        audit_log = AuditLog.last

        expect(audit_log.created_at.zone).to eq('UTC')
      end
    end

    context 'performance requirements' do
      it 'completes within acceptable time' do
        expect {
          Timeout.timeout(0.5) do
            described_class.perform_now(**valid_params)
          end
        }.not_to raise_error
      end

      it 'uses optimized SQL insertion' do
        expect(ActiveRecord::Base.connection).to receive(:execute)
          .with(/INSERT INTO audit_logs/)
          .once

        described_class.perform_now(**valid_params)
      end
    end
  end
end