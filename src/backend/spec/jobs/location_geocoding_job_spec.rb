# frozen_string_literal: true

require 'rails_helper'

RSpec.describe LocationGeocodingJob, type: :job do
  # Configure Sidekiq test mode
  include Sidekiq::Testing
  Sidekiq::Testing.fake!

  # Test setup
  let(:location) { create(:location, address: '123 Test St', latitude: nil, longitude: nil) }
  let(:geocoding_service) { class_double(GeocodingService) }
  let(:coordinates) { { latitude: 40.7128, longitude: -74.0060 } }
  let(:job) { described_class.new }

  before do
    # Reset Sidekiq queues before each test
    Sidekiq::Worker.clear_all
    # Allow GeocodingService to receive calls
    allow(GeocodingService).to receive(:new).and_return(geocoding_service)
  end

  describe 'configuration' do
    it 'uses the correct queue' do
      expect(described_class.queue_name).to eq('geocoding')
    end

    it 'has the correct retry settings' do
      expect(described_class.sidekiq_options['retry']).to eq(5)
    end

    it 'has dead job handling disabled' do
      expect(described_class.sidekiq_options['dead']).to be false
    end

    it 'includes proper tags' do
      expect(described_class.sidekiq_options['tags']).to match_array(['geocoding', 'location'])
    end
  end

  describe '#perform' do
    context 'with valid location' do
      before do
        allow(geocoding_service).to receive(:call).and_return(
          double('Result', success?: true, coordinates: coordinates)
        )
      end

      it 'processes geocoding successfully' do
        expect {
          job.perform(location.id)
        }.to change { location.reload.geocoding_status }.from('pending').to('completed')
      end

      it 'updates location coordinates' do
        job.perform(location.id)
        location.reload
        
        expect(location.latitude).to eq(coordinates[:latitude])
        expect(location.longitude).to eq(coordinates[:longitude])
      end

      it 'updates geocoding metadata' do
        job.perform(location.id)
        location.reload
        
        expect(location.geocoding_metadata).to include(
          'completed_at',
          'attempts'
        )
      end

      it 'records performance metrics' do
        expect(REDIS_CACHE_POOL).to receive(:with)
        job.perform(location.id)
      end
    end

    context 'with invalid location ID' do
      it 'handles non-existent location' do
        expect {
          job.perform(-1)
        }.to raise_error(ActiveRecord::RecordNotFound)
      end

      it 'logs error for invalid location' do
        expect(Rails.logger).to receive(:error).with(/Location not found/)
        
        begin
          job.perform(-1)
        rescue ActiveRecord::RecordNotFound
          # Expected error
        end
      end
    end

    context 'with geocoding service errors' do
      shared_examples 'retryable error' do |error_class|
        before do
          allow(geocoding_service).to receive(:call).and_raise(error_class)
        end

        it "retries on #{error_class}" do
          expect {
            job.perform(location.id)
          }.to raise_error(error_class)

          expect(job.executions).to be > 0
        end
      end

      it_behaves_like 'retryable error', GeocodingService::GeocodingError
      it_behaves_like 'retryable error', GeocodingService::RateLimitError

      it 'implements exponential backoff for retries' do
        allow(geocoding_service).to receive(:call).and_raise(GeocodingService::GeocodingError)
        
        retry_count = 0
        expect(job).to receive(:retry_job).exactly(5).times do |args|
          expect(args[:wait]).to be >= (30 * (2 ** retry_count))
          retry_count += 1
        end

        begin
          job.perform(location.id)
        rescue GeocodingService::GeocodingError
          # Expected error
        end
      end
    end

    context 'with database transaction errors' do
      before do
        allow(geocoding_service).to receive(:call).and_return(
          double('Result', success?: true, coordinates: coordinates)
        )
      end

      it 'handles deadlock errors' do
        allow(location).to receive(:update!).and_raise(ActiveRecord::DeadlockVictimError)
        
        expect {
          job.perform(location.id)
        }.to raise_error(ActiveRecord::DeadlockVictimError)
      end

      it 'handles lock timeout errors' do
        allow(location).to receive(:with_lock).and_raise(ActiveRecord::LockWaitTimeout)
        
        expect {
          job.perform(location.id)
        }.to raise_error(ActiveRecord::LockWaitTimeout)
      end
    end

    context 'with monitoring integration' do
      before do
        allow(geocoding_service).to receive(:call).and_return(
          double('Result', success?: true, coordinates: coordinates)
        )
      end

      it 'reports errors to monitoring service' do
        error = StandardError.new('Test error')
        allow(geocoding_service).to receive(:call).and_raise(error)
        
        expect(Rails.error).to receive(:report).with(
          error,
          hash_including(
            component: 'LocationGeocodingJob',
            operation: 'perform',
            severity: 'error'
          )
        )

        begin
          job.perform(location.id)
        rescue StandardError
          # Expected error
        end
      end

      it 'tracks job duration metrics' do
        expect(REDIS_CACHE_POOL).to receive(:with) do |&block|
          redis = double('Redis')
          expect(redis).to receive(:pipelined)
          block.call(redis)
        end

        job.perform(location.id)
      end
    end
  end
end