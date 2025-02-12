# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Location, type: :model do
  # Setup shared contexts for testing
  let(:valid_attributes) do
    {
      name: 'Test Location',
      address: '123 Test Street, Test City, 12345',
      latitude: 40.7128,
      longitude: -74.0060,
      active: true
    }
  end

  let(:location) { create(:location, valid_attributes) }

  # Validations
  describe 'validations' do
    it { should validate_presence_of(:name) }
    it { should validate_presence_of(:address) }
    it { should validate_length_of(:name).is_at_most(255) }
    it { should validate_length_of(:address).is_at_most(1000) }
    
    it { should validate_numericality_of(:latitude)
          .is_greater_than_or_equal_to(-90)
          .is_less_than_or_equal_to(90)
          .allow_nil }
    
    it { should validate_numericality_of(:longitude)
          .is_greater_than_or_equal_to(-180)
          .is_less_than_or_equal_to(180)
          .allow_nil }

    it { should validate_inclusion_of(:geocoding_status)
          .in_array(%w[pending processing completed failed]) }
  end

  # Attributes and defaults
  describe 'attributes' do
    it 'has expected attributes with defaults' do
      location = Location.new
      
      expect(location).to have_attributes(
        active: true,
        geocoding_status: 'pending',
        geocoding_metadata: {}
      )
    end
  end

  # Scopes
  describe 'scopes' do
    let!(:geocoded_location) { create(:location, latitude: 40.7128, longitude: -74.0060) }
    let!(:ungeocoded_location) { create(:location, latitude: nil, longitude: nil) }
    let!(:pending_location) { create(:location, geocoding_status: 'pending') }
    let!(:failed_location) { create(:location, geocoding_status: 'failed') }

    describe '.geocoded' do
      it 'returns only locations with coordinates' do
        expect(Location.geocoded).to include(geocoded_location)
        expect(Location.geocoded).not_to include(ungeocoded_location)
      end
    end

    describe '.pending_geocoding' do
      it 'returns locations with pending geocoding status' do
        expect(Location.pending_geocoding).to include(pending_location)
        expect(Location.pending_geocoding).not_to include(failed_location)
      end
    end

    describe '.failed_geocoding' do
      it 'returns locations with failed geocoding status' do
        expect(Location.failed_geocoding).to include(failed_location)
        expect(Location.failed_geocoding).not_to include(pending_location)
      end
    end
  end

  # Geocoding functionality
  describe 'geocoding' do
    describe '#geocode_async' do
      it 'enqueues a geocoding job when address changes' do
        location.address = '456 New Street, New City, 54321'
        
        expect {
          location.save
        }.to have_enqueued_job(LocationGeocodingJob).with(location.id)
      end

      it 'updates geocoding status and metadata' do
        location.address = '456 New Street, New City, 54321'
        location.save

        expect(location.geocoding_status).to eq('processing')
        expect(location.geocoding_metadata['attempts']).to eq(1)
        expect(location.geocoding_metadata['last_attempt']).to be_present
      end

      it 'does not enqueue job if address is blank' do
        location.address = ''
        
        expect {
          location.save
        }.not_to have_enqueued_job(LocationGeocodingJob)
      end
    end

    describe '#update_coordinates' do
      it 'updates coordinates and geocoding status' do
        result = location.update_coordinates(41.8781, -87.6298)

        expect(result).to be true
        expect(location.latitude).to eq(41.8781)
        expect(location.longitude).to eq(-87.6298)
        expect(location.geocoding_status).to eq('completed')
      end

      it 'rejects invalid coordinates' do
        result = location.update_coordinates(91.0, -181.0)

        expect(result).to be false
        expect(location.latitude).not_to eq(91.0)
        expect(location.longitude).not_to eq(-181.0)
      end
    end
  end

  # Caching functionality
  describe 'caching', :redis do
    describe '.nearby' do
      let!(:nearby_location) do
        create(:location,
          latitude: 40.7128,
          longitude: -74.0060,
          active: true
        )
      end

      let!(:far_location) do
        create(:location,
          latitude: 34.0522,
          longitude: -118.2437,
          active: true
        )
      end

      it 'caches nearby location results' do
        cache_key = Location.send(:generate_nearby_cache_key, 40.7128, -74.0060, 10, {})
        
        expect(Rails.cache).to receive(:fetch)
          .with(cache_key, expires_in: 1.hour)
          .and_call_original

        results = Location.nearby(
          latitude: 40.7128,
          longitude: -74.0060,
          radius_km: 10
        )

        expect(results).to include(nearby_location)
        expect(results).not_to include(far_location)
      end

      it 'invalidates cache when coordinates change' do
        expect(Rails.cache).to receive(:delete_matched).with('locations:nearby:*')
        
        nearby_location.update_coordinates(40.7130, -74.0062)
      end
    end
  end

  # Audit logging
  describe 'audit logging' do
    it 'creates audit log on create' do
      expect {
        create(:location)
      }.to change(AuditLog, :count).by(1)
    end

    it 'creates audit log on update' do
      expect {
        location.update(name: 'Updated Location')
      }.to change(AuditLog, :count).by(1)
    end

    it 'creates audit log on destroy' do
      expect {
        location.destroy
      }.to change(AuditLog, :count).by(1)
    end
  end

  # Soft deletion
  describe 'soft deletion' do
    it 'soft deletes the record' do
      expect {
        location.soft_delete
      }.not_to change(Location, :count)

      expect(location.deleted?).to be true
      expect(location.active).to be false
      expect(location.deleted_at).to be_present
    end

    it 'restores soft-deleted record' do
      location.soft_delete
      location.restore

      expect(location.deleted?).to be false
      expect(location.active).to be true
      expect(location.deleted_at).to be_nil
    end

    it 'excludes soft-deleted records from default scope' do
      location.soft_delete
      
      expect(Location.all).not_to include(location)
      expect(Location.with_deleted).to include(location)
    end
  end

  # Performance requirements
  describe 'performance', :performance do
    it 'completes geocoding within 500ms' do
      expect {
        location.geocode_async
      }.to perform_under(500).ms
    end

    it 'maintains cache hit rate above 80%' do
      cache_hits = 0
      total_requests = 100

      total_requests.times do
        Location.nearby(
          latitude: 40.7128,
          longitude: -74.0060,
          radius_km: 10
        )
        cache_hits += 1 if Rails.cache.read("locations:nearby:*").present?
      end

      hit_rate = (cache_hits.to_f / total_requests) * 100
      expect(hit_rate).to be >= 80
    end
  end
end