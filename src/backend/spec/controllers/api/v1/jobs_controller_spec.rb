# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::JobsController, type: :request do
  let(:user) { create(:user) }
  let(:admin) { create(:admin) }
  let(:location) { create(:location) }
  let(:valid_token) { JWTService.new(user_id: user.id).generate_token }
  let(:admin_token) { JWTService.new(user_id: admin.id).generate_token }
  let(:headers) { { 'Authorization' => "Bearer #{valid_token}", 'Content-Type' => 'application/json' } }
  let(:admin_headers) { { 'Authorization' => "Bearer #{admin_token}", 'Content-Type' => 'application/json' } }

  let(:valid_attributes) do
    {
      title: 'Software Engineer',
      description: 'Full-stack developer position',
      location_id: location.id,
      status: 'open',
      start_date: Time.current,
      end_date: 30.days.from_now
    }
  end

  before(:each) do
    Redis.current.flushdb
    Rails.cache.clear
  end

  describe 'GET #index' do
    before do
      create_list(:job, 5, location: location)
    end

    context 'with valid authentication' do
      it 'returns paginated list of jobs' do
        get '/api/v1/jobs', headers: headers
        
        expect(response).to have_http_status(:ok)
        expect(json_response[:data]).to be_present
        expect(json_response[:meta]).to include(:current_page, :total_pages, :total_count)
      end

      it 'respects pagination parameters' do
        get '/api/v1/jobs', params: { page: 1, per_page: 2 }, headers: headers
        
        expect(json_response[:data].length).to eq(2)
        expect(json_response[:meta][:current_page]).to eq(1)
      end

      it 'filters by status' do
        create(:job, status: 'closed', location: location)
        get '/api/v1/jobs', params: { status: 'closed' }, headers: headers
        
        expect(json_response[:data].all? { |job| job[:attributes][:status] == 'closed' }).to be true
      end

      it 'filters by location' do
        get '/api/v1/jobs', params: { location_id: location.id }, headers: headers
        
        expect(json_response[:data].all? { |job| job[:attributes][:location_id] == location.id }).to be true
      end

      it 'filters by date range' do
        get '/api/v1/jobs', params: { 
          start_date: Time.current.iso8601,
          end_date: 30.days.from_now.iso8601
        }, headers: headers
        
        expect(response).to have_http_status(:ok)
      end

      it 'returns cached response when available' do
        get '/api/v1/jobs', headers: headers
        etag = response.headers['ETag']
        
        get '/api/v1/jobs', headers: headers.merge('If-None-Match' => etag)
        expect(response).to have_http_status(:not_modified)
      end
    end

    context 'with invalid authentication' do
      it 'returns unauthorized for missing token' do
        get '/api/v1/jobs'
        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns unauthorized for invalid token' do
        get '/api/v1/jobs', headers: { 'Authorization' => 'Bearer invalid' }
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'with rate limiting' do
      it 'enforces rate limits' do
        allow(Rails.cache).to receive(:read).and_return(1001)
        get '/api/v1/jobs', headers: headers
        expect(response).to have_http_status(:too_many_requests)
      end
    end
  end

  describe 'GET #show' do
    let(:job) { create(:job, location: location) }

    context 'with valid authentication' do
      it 'returns the requested job' do
        get "/api/v1/jobs/#{job.id}", headers: headers
        
        expect(response).to have_http_status(:ok)
        expect(json_response[:data][:id].to_i).to eq(job.id)
      end

      it 'includes associated location data' do
        get "/api/v1/jobs/#{job.id}", headers: headers, params: { include: 'location' }
        
        expect(json_response[:included]).to be_present
        expect(json_response[:included].first[:type]).to eq('locations')
      end

      it 'returns cached response when available' do
        get "/api/v1/jobs/#{job.id}", headers: headers
        etag = response.headers['ETag']
        
        get "/api/v1/jobs/#{job.id}", headers: headers.merge('If-None-Match' => etag)
        expect(response).to have_http_status(:not_modified)
      end

      it 'returns not found for non-existent job' do
        get '/api/v1/jobs/0', headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe 'POST #create' do
    context 'with valid authentication' do
      it 'creates a new job' do
        expect {
          post '/api/v1/jobs', params: { job: valid_attributes }.to_json, headers: headers
        }.to change(Job, :count).by(1)
        
        expect(response).to have_http_status(:created)
        expect(json_response[:data][:attributes][:title]).to eq(valid_attributes[:title])
      end

      it 'validates required attributes' do
        post '/api/v1/jobs', params: { job: valid_attributes.except(:title) }.to_json, headers: headers
        
        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_response[:errors]).to be_present
      end

      it 'validates date ranges' do
        post '/api/v1/jobs', 
          params: { job: valid_attributes.merge(end_date: 1.day.ago) }.to_json,
          headers: headers
        
        expect(response).to have_http_status(:unprocessable_entity)
      end

      it 'invalidates cache after creation' do
        Rails.cache.write("jobs/list", "cached_data")
        post '/api/v1/jobs', params: { job: valid_attributes }.to_json, headers: headers
        
        expect(Rails.cache.read("jobs/list")).to be_nil
      end
    end
  end

  describe 'PUT #update' do
    let(:job) { create(:job, location: location) }

    context 'with valid authentication' do
      it 'updates the requested job' do
        put "/api/v1/jobs/#{job.id}",
          params: { job: { title: 'Updated Title' } }.to_json,
          headers: headers
        
        expect(response).to have_http_status(:ok)
        expect(job.reload.title).to eq('Updated Title')
      end

      it 'validates updates' do
        put "/api/v1/jobs/#{job.id}",
          params: { job: { status: 'invalid' } }.to_json,
          headers: headers
        
        expect(response).to have_http_status(:unprocessable_entity)
      end

      it 'handles concurrent updates' do
        job.update_column(:updated_at, Time.current)
        
        put "/api/v1/jobs/#{job.id}",
          params: { job: { title: 'New Title' }, if_unmodified_since: 1.hour.ago.httpdate }.to_json,
          headers: headers
        
        expect(response).to have_http_status(:precondition_failed)
      end

      it 'invalidates cache after update' do
        Rails.cache.write("jobs/#{job.id}", "cached_data")
        put "/api/v1/jobs/#{job.id}",
          params: { job: { title: 'New Title' } }.to_json,
          headers: headers
        
        expect(Rails.cache.read("jobs/#{job.id}")).to be_nil
      end
    end
  end

  describe 'PATCH #update_status' do
    let(:job) { create(:job, location: location, status: 'open') }

    context 'with valid authentication' do
      it 'updates job status' do
        patch "/api/v1/jobs/#{job.id}/status",
          params: { status: 'closed' }.to_json,
          headers: headers
        
        expect(response).to have_http_status(:ok)
        expect(job.reload.status).to eq('closed')
      end

      it 'validates status transitions' do
        patch "/api/v1/jobs/#{job.id}/status",
          params: { status: 'invalid' }.to_json,
          headers: headers
        
        expect(response).to have_http_status(:unprocessable_entity)
      end

      it 'logs status changes' do
        expect {
          patch "/api/v1/jobs/#{job.id}/status",
            params: { status: 'closed' }.to_json,
            headers: headers
        }.to change(AuditLog, :count).by(1)
      end
    end
  end

  describe 'DELETE #destroy' do
    let!(:job) { create(:job, location: location) }

    context 'with admin authentication' do
      it 'soft deletes the job' do
        expect {
          delete "/api/v1/jobs/#{job.id}", headers: admin_headers
        }.to change { Job.active.count }.by(-1)
        
        expect(response).to have_http_status(:no_content)
        expect(Job.unscoped.find(job.id)).to be_present
      end

      it 'invalidates cache after deletion' do
        Rails.cache.write("jobs/#{job.id}", "cached_data")
        delete "/api/v1/jobs/#{job.id}", headers: admin_headers
        
        expect(Rails.cache.read("jobs/#{job.id}")).to be_nil
      end
    end

    context 'with non-admin authentication' do
      it 'returns forbidden' do
        delete "/api/v1/jobs/#{job.id}", headers: headers
        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end