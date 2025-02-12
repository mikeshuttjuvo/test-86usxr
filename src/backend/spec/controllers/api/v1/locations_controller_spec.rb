# frozen_string_literal: true

require 'rails_helper'
require 'support/request_spec_helper'

RSpec.describe Api::V1::LocationsController, type: :request do
  include RequestSpecHelper

  let(:user) { create(:user, :admin) }
  let(:location) { create(:location) }
  let(:valid_attributes) do
    {
      name: 'Test Location',
      address: '123 Test St, Test City, TS 12345',
      latitude: 40.7128,
      longitude: -74.0060,
      active: true
    }
  end

  # Shared contexts for different test scenarios
  shared_context 'with valid authentication' do
    let(:headers) { auth_headers(user) }
  end

  shared_context 'with invalid authentication' do
    let(:headers) { auth_headers(user).merge('Authorization' => 'Bearer invalid') }
  end

  shared_context 'with rate limit exceeded' do
    before do
      allow_any_instance_of(RateLimiter).to receive(:allowed?).and_return(false)
      allow_any_instance_of(RateLimiter).to receive(:remaining).and_return(0)
      allow_any_instance_of(RateLimiter).to receive(:reset_at).and_return(1.hour.from_now)
    end
  end

  describe 'GET /api/v1/locations' do
    context 'with valid authentication' do
      include_context 'with valid authentication'

      it 'returns a paginated list of locations' do
        create_list(:location, 3)
        
        get '/api/v1/locations', headers: headers
        
        expect(response).to have_http_status(:ok)
        expect(json_response[:data]).to be_present
        expect(valid_pagination?(json_response)).to be true
        expect(response).to match_json_schema('locations/index')
      end

      it 'respects pagination parameters' do
        create_list(:location, 5)
        
        get '/api/v1/locations', params: { page: 2, per_page: 2 }, headers: headers
        
        expect(json_response[:meta][:current_page]).to eq(2)
        expect(json_response[:data].length).to eq(2)
      end

      it 'filters by active status' do
        active = create(:location, active: true)
        inactive = create(:location, active: false)
        
        get '/api/v1/locations', params: { active: true }, headers: headers
        
        expect(json_response[:data].map { |l| l[:id] }).to include(active.id.to_s)
        expect(json_response[:data].map { |l| l[:id] }).not_to include(inactive.id.to_s)
      end

      it 'uses cache for subsequent requests', :caching do
        create_list(:location, 2)
        
        expect(Rails.cache).to receive(:fetch).and_call_original
        
        get '/api/v1/locations', headers: headers
        first_response = response.body
        
        get '/api/v1/locations', headers: headers
        expect(response.body).to eq(first_response)
      end
    end

    context 'with invalid authentication' do
      include_context 'with invalid authentication'

      it 'returns unauthorized error' do
        get '/api/v1/locations', headers: headers
        
        expect(response).to have_http_status(:unauthorized)
        expect(response).to be_a_valid_error_response
      end
    end

    context 'with rate limit exceeded' do
      include_context 'with valid authentication'
      include_context 'with rate limit exceeded'

      it 'returns rate limit exceeded error' do
        get '/api/v1/locations', headers: headers
        
        expect(response).to have_http_status(:too_many_requests)
        expect(response).to be_a_valid_error_response
        expect(response.headers['X-RateLimit-Remaining']).to eq('0')
      end
    end
  end

  describe 'GET /api/v1/locations/:id' do
    context 'with valid authentication' do
      include_context 'with valid authentication'

      it 'returns the requested location' do
        get "/api/v1/locations/#{location.id}", headers: headers
        
        expect(response).to have_http_status(:ok)
        expect(json_response[:data][:id]).to eq(location.id.to_s)
        expect(response).to match_json_schema('locations/show')
      end

      it 'returns not found for non-existent location' do
        get '/api/v1/locations/0', headers: headers
        
        expect(response).to have_http_status(:not_found)
        expect(response).to be_a_valid_error_response
      end

      it 'uses cache for subsequent requests', :caching do
        expect(Rails.cache).to receive(:fetch).and_call_original
        
        get "/api/v1/locations/#{location.id}", headers: headers
        first_response = response.body
        
        get "/api/v1/locations/#{location.id}", headers: headers
        expect(response.body).to eq(first_response)
      end
    end
  end

  describe 'POST /api/v1/locations' do
    context 'with valid authentication' do
      include_context 'with valid authentication'

      it 'creates a new location' do
        expect {
          post '/api/v1/locations',
               params: { location: valid_attributes }.to_json,
               headers: headers
        }.to change(Location, :count).by(1)

        expect(response).to have_http_status(:created)
        expect(response).to match_json_schema('locations/show')
        expect(json_response[:data][:attributes][:name]).to eq(valid_attributes[:name])
      end

      it 'validates required attributes' do
        post '/api/v1/locations',
             params: { location: { name: '' } }.to_json,
             headers: headers

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response).to be_a_valid_error_response
        expect(json_response[:errors]).to include(hash_including(detail: /Name can't be blank/))
      end

      it 'handles geocoding errors gracefully' do
        allow_any_instance_of(Location).to receive(:geocode).and_raise(Geocoder::Error)

        post '/api/v1/locations',
             params: { location: valid_attributes }.to_json,
             headers: headers

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response).to be_a_valid_error_response
      end

      it 'invalidates index cache after creation' do
        expect(Rails.cache).to receive(:delete_matched).with(/locations\/index/)
        
        post '/api/v1/locations',
             params: { location: valid_attributes }.to_json,
             headers: headers
      end
    end
  end

  describe 'PUT /api/v1/locations/:id' do
    context 'with valid authentication' do
      include_context 'with valid authentication'

      it 'updates the requested location' do
        new_name = 'Updated Location'
        
        put "/api/v1/locations/#{location.id}",
            params: { location: { name: new_name } }.to_json,
            headers: headers

        expect(response).to have_http_status(:ok)
        expect(json_response[:data][:attributes][:name]).to eq(new_name)
        expect(response).to match_json_schema('locations/show')
      end

      it 'validates update attributes' do
        put "/api/v1/locations/#{location.id}",
            params: { location: { name: '' } }.to_json,
            headers: headers

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response).to be_a_valid_error_response
      end

      it 'invalidates both show and index caches after update' do
        expect(Rails.cache).to receive(:delete_matched).with(/locations\/(#{location.id}|index)/)
        
        put "/api/v1/locations/#{location.id}",
            params: { location: { name: 'Updated' } }.to_json,
            headers: headers
      end
    end
  end

  describe 'DELETE /api/v1/locations/:id' do
    context 'with valid authentication' do
      include_context 'with valid authentication'

      it 'soft deletes the location' do
        delete "/api/v1/locations/#{location.id}", headers: headers

        expect(response).to have_http_status(:no_content)
        expect(Location.find_by(id: location.id).active).to be false
      end

      it 'handles dependent records appropriately' do
        job = create(:job, location: location)
        
        delete "/api/v1/locations/#{location.id}", headers: headers

        expect(response).to have_http_status(:no_content)
        expect(Job.find(job.id).active).to be false
      end

      it 'invalidates all related caches after deletion' do
        expect(Rails.cache).to receive(:delete_matched).with(/locations\/(#{location.id}|index)/)
        
        delete "/api/v1/locations/#{location.id}", headers: headers
      end
    end
  end

  # Test helper methods
  def create_test_location(attributes = {})
    create(:location, attributes)
  end

  def stub_geocoding_service(address, response)
    allow(Geocoder).to receive(:search)
      .with(address)
      .and_return([double(coordinates: response)])
  end

  def verify_rate_limit(endpoint, options = {})
    headers = options.fetch(:headers, auth_headers(user))
    
    (RateLimiter::MAX_REQUESTS + 1).times do
      get endpoint, headers: headers
    end
    
    expect(response).to have_http_status(:too_many_requests)
    expect(response.headers['X-RateLimit-Remaining']).to eq('0')
  end
end