# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'API V1 Locations', type: :request do
  include RequestSpecHelper

  let(:user) { create(:user, :admin) }
  let(:location) { create(:location) }
  let(:inactive_location) { create(:location, :inactive) }
  let(:valid_attributes) do
    {
      name: 'Test Location',
      address: '123 Test St, Test City, TS 12345',
      active: true
    }
  end

  describe 'GET /api/v1/locations' do
    context 'with valid authentication' do
      before do
        create_list(:location, 15)
        create_list(:location, 5, :inactive)
      end

      it 'returns paginated list of active locations' do
        get '/api/v1/locations', params: { page: 2, per_page: 10 }, headers: auth_headers(user)

        expect(response).to have_http_status(:ok)
        expect(json_response[:data].length).to eq(5)
        expect(json_response[:meta]).to include(
          current_page: 2,
          total_pages: 2,
          total_count: 15
        )
        expect(valid_pagination?(json_response)).to be true
        expect(response.headers['Cache-Control']).to include('max-age=3600')
      end

      it 'filters locations by status and search term' do
        create(:location, name: 'Test Store')
        create(:location, name: 'test warehouse', active: false)

        get '/api/v1/locations', params: {
          active: true,
          search: 'test'
        }, headers: auth_headers(user)

        expect(response).to have_http_status(:ok)
        expect(json_response[:data].length).to eq(1)
        expect(json_response[:data].first[:attributes][:name]).to eq('Test Store')
      end

      it 'handles rate limiting' do
        allow_any_instance_of(RequestSpecHelper).to receive(:rate_limited?).and_return(true)

        get '/api/v1/locations', headers: auth_headers(user)

        expect(response).to have_http_status(:too_many_requests)
        expect(response.headers['X-RateLimit-Limit']).to be_present
        expect(response.headers['X-RateLimit-Remaining']).to eq('0')
        expect(valid_error_response?(json_response)).to be true
      end
    end

    context 'without authentication' do
      it 'returns unauthorized error' do
        get '/api/v1/locations'

        expect(response).to have_http_status(:unauthorized)
        expect(valid_error_response?(json_response)).to be true
      end
    end
  end

  describe 'GET /api/v1/locations/:id' do
    context 'with valid authentication' do
      let(:location_with_jobs) { create(:location, :with_coordinates) }

      before do
        create_list(:job, 3, location: location_with_jobs)
      end

      it 'returns location with associated data' do
        get "/api/v1/locations/#{location_with_jobs.id}", headers: auth_headers(user)

        expect(response).to have_http_status(:ok)
        expect(json_response[:data][:attributes]).to include(
          name: location_with_jobs.name,
          address: location_with_jobs.address,
          latitude: location_with_jobs.latitude.to_s,
          longitude: location_with_jobs.longitude.to_s
        )
        expect(json_response[:data][:relationships][:jobs]).to be_present
        expect(response.headers['Cache-Control']).to include('max-age=3600')
      end

      it 'handles soft-deleted locations' do
        location_with_jobs.soft_delete

        get "/api/v1/locations/#{location_with_jobs.id}", headers: auth_headers(user)

        expect(response).to have_http_status(:not_found)
        expect(valid_error_response?(json_response)).to be true
      end
    end
  end

  describe 'POST /api/v1/locations' do
    context 'with valid authentication' do
      before do
        mock_geocoding_service
      end

      it 'creates location with geocoding' do
        expect {
          post '/api/v1/locations',
               params: { location: valid_attributes }.to_json,
               headers: auth_headers(user).merge(json_request_headers)
        }.to change(Location, :count).by(1)
           .and change(AuditLog, :count).by(1)

        expect(response).to have_http_status(:created)
        expect(json_response[:data][:attributes]).to include(
          name: valid_attributes[:name],
          address: valid_attributes[:address]
        )
        expect(json_response[:data][:attributes][:latitude]).to be_present
        expect(json_response[:data][:attributes][:longitude]).to be_present
      end

      it 'validates required fields' do
        post '/api/v1/locations',
             params: { location: { name: '' } }.to_json,
             headers: auth_headers(user).merge(json_request_headers)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(valid_error_response?(json_response)).to be true
        expect(json_response[:errors]).to include(
          hash_including(field: 'name', code: 'blank')
        )
      end
    end
  end

  describe 'PUT /api/v1/locations/:id' do
    context 'with valid authentication' do
      let(:location) { create(:location, :with_coordinates) }
      let(:new_address) { '456 Update St, Update City, UC 67890' }

      before do
        mock_geocoding_service
      end

      it 'updates location with address changes' do
        put "/api/v1/locations/#{location.id}",
            params: { location: { address: new_address } }.to_json,
            headers: auth_headers(user).merge(json_request_headers)

        expect(response).to have_http_status(:ok)
        expect(json_response[:data][:attributes][:address]).to eq(new_address)
        expect(json_response[:data][:attributes][:latitude]).to be_present
        expect(json_response[:data][:attributes][:longitude]).to be_present
        
        audit_log = AuditLog.last
        expect(audit_log.action).to eq('update')
        expect(audit_log.resource_type).to eq('Location')
        expect(audit_log.resource_id).to eq(location.id)
      end
    end
  end

  describe 'DELETE /api/v1/locations/:id' do
    context 'with valid authentication' do
      let(:location_with_jobs) { create(:location) }

      before do
        create_list(:job, 3, location: location_with_jobs)
      end

      it 'performs soft deletion' do
        delete "/api/v1/locations/#{location_with_jobs.id}",
               headers: auth_headers(user)

        expect(response).to have_http_status(:ok)
        expect(Location.find_by(id: location_with_jobs.id)).to be_nil
        expect(Location.with_deleted.find(location_with_jobs.id)).to be_present
        expect(Location.with_deleted.find(location_with_jobs.id).active).to be false
        
        audit_log = AuditLog.last
        expect(audit_log.action).to eq('soft_delete')
        expect(audit_log.resource_type).to eq('Location')
      end
    end
  end

  describe 'GET /api/v1/locations/nearby' do
    context 'with valid authentication' do
      before do
        create_list(:location, 5, :with_coordinates)
      end

      it 'returns locations within radius' do
        get '/api/v1/locations/nearby',
            params: {
              latitude: 40.7128,
              longitude: -74.0060,
              radius_km: 10
            },
            headers: auth_headers(user)

        expect(response).to have_http_status(:ok)
        expect(json_response[:data]).to be_present
        expect(json_response[:data].first[:attributes]).to include(:distance)
        expect(response.headers['Cache-Control']).to include('max-age=3600')
      end

      it 'validates coordinates' do
        get '/api/v1/locations/nearby',
            params: {
              latitude: 200,
              longitude: -74.0060,
              radius_km: 10
            },
            headers: auth_headers(user)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(valid_error_response?(json_response)).to be true
      end
    end
  end
end