# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GeocodingService do
  # Configure test environment
  before(:all) do
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  after(:all) do
    WebMock.allow_net_connect!
  end

  let(:redis_client) { REDIS_CACHE_POOL }
  let(:valid_address) { '123 Main St, New York, NY 10001' }
  let(:invalid_address) { ' ' }
  let(:valid_coordinates) { { latitude: 40.7505, longitude: -73.9965 } }

  describe '#call' do
    context 'with valid address' do
      let(:location) { create(:location, address: valid_address) }
      let(:service) { described_class.new(location) }

      before do
        stub_request(:get, /maps.googleapis.com/)
          .with(query: hash_including({ address: valid_address }))
          .to_return(
            status: 200,
            body: {
              results: [{
                geometry: {
                  location: {
                    lat: valid_coordinates[:latitude],
                    lng: valid_coordinates[:longitude]
                  }
                }
              }]
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          )
      end

      it 'successfully geocodes the address' do
        result = service.call
        expect(result).to be true
        expect(service.success?).to be true
      end

      it 'updates location coordinates' do
        service.call
        location.reload
        expect(location.latitude).to eq(valid_coordinates[:latitude])
        expect(location.longitude).to eq(valid_coordinates[:longitude])
      end

      it 'completes within performance requirements' do
        time = Benchmark.measure { service.call }
        expect(time.real).to be < 0.5 # 500ms requirement
      end

      it 'records geocoding metrics' do
        expect(redis_client).to receive(:hincrby)
          .with(/geocoding:metrics:daily/, anything, 1)
        expect(redis_client).to receive(:hset)
          .with(/geocoding:metrics:latency/, anything, anything)
        service.call
      end
    end

    context 'with invalid address' do
      let(:location) { create(:location, address: invalid_address) }
      let(:service) { described_class.new(location) }

      it 'returns false and sets error' do
        result = service.call
        expect(result).to be false
        expect(service.success?).to be false
      end

      it 'includes RFC 7807 compliant error details' do
        service.call
        error = service.errors.first
        expect(error).to include(
          type: 'validation_error',
          title: 'Invalid Address',
          detail: GeocodingService::ERRORS[:invalid_address],
          status: 400
        )
      end

      it 'does not update coordinates' do
        original_coordinates = [location.latitude, location.longitude]
        service.call
        location.reload
        expect([location.latitude, location.longitude]).to eq(original_coordinates)
      end
    end

    context 'when rate limited' do
      let(:location) { create(:location, address: valid_address) }
      let(:service) { described_class.new(location) }
      let(:rate_limit_key) { "#{GeocodingService::RATE_LIMIT_PREFIX}:#{Time.current.to_i / 3600}" }

      before do
        redis_client.set(rate_limit_key, 1001) # Exceed 1000/hour limit
      end

      after do
        redis_client.del(rate_limit_key)
      end

      it 'returns false and sets rate limit error' do
        result = service.call
        expect(result).to be false
        expect(service.errors.first).to include(
          type: 'rate_limit_error',
          title: 'Rate Limit Exceeded',
          status: 429
        )
      end

      it 'maintains rate limit counter' do
        service.call
        expect(redis_client.get(rate_limit_key).to_i).to be > 1000
      end
    end

    context 'when external service fails' do
      let(:location) { create(:location, address: valid_address) }
      let(:service) { described_class.new(location) }

      context 'with timeout error' do
        before do
          stub_request(:get, /maps.googleapis.com/)
            .to_timeout
        end

        it 'handles timeout gracefully' do
          result = service.call
          expect(result).to be false
          expect(service.errors.first).to include(
            type: 'service_error',
            status: 500
          )
        end

        it 'attempts configured number of retries' do
          expect(Geocoder).to receive(:search).exactly(4).times.and_raise(Timeout::Error)
          service.call
        end
      end

      context 'with API error' do
        before do
          stub_request(:get, /maps.googleapis.com/)
            .to_return(status: 503)
        end

        it 'handles service unavailability' do
          result = service.call
          expect(result).to be false
          expect(service.errors.first).to include(
            type: 'service_error',
            detail: GeocodingService::ERRORS[:service_unavailable],
            status: 500
          )
        end
      end

      context 'with invalid API key' do
        before do
          stub_request(:get, /maps.googleapis.com/)
            .to_return(
              status: 403,
              body: { error: 'Invalid API key' }.to_json,
              headers: { 'Content-Type' => 'application/json' }
            )
        end

        it 'handles authentication errors' do
          result = service.call
          expect(result).to be false
          expect(service.errors.first).to include(
            type: 'configuration_error',
            status: 500
          )
        end
      end
    end
  end

  describe 'configuration' do
    let(:service) { described_class.new(build(:location)) }

    it 'uses configured retry attempts' do
      expect(service.send(:instance_variable_get, :@retry_attempts))
        .to eq(GeocodingService::DEFAULTS[:retry_attempts])
    end

    it 'uses configured rate limit threshold' do
      expect(service.send(:instance_variable_get, :@rate_limit_threshold))
        .to eq(GeocodingService::DEFAULTS[:rate_limit_threshold])
    end
  end
end