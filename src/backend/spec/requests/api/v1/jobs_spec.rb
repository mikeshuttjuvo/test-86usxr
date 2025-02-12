# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Jobs API V1', type: :request do
  include RequestSpecHelper

  let(:user) { create(:user, :manager) }
  let(:location) { create(:location, created_by: user) }
  let(:job) { create(:job, location: location, created_by: user) }
  let(:headers) { auth_headers(user) }

  let(:valid_attributes) do
    {
      title: 'Senior Software Engineer',
      description: 'Experienced Ruby developer needed',
      location_id: location.id,
      status: 'open',
      start_date: Time.current,
      end_date: 30.days.from_now,
      active: true
    }
  end

  let(:invalid_attributes) do
    {
      title: '',
      description: nil,
      location_id: nil,
      status: 'invalid_status'
    }
  end

  describe 'GET /api/v1/jobs' do
    before do
      create_list(:job, 3, location: location)
    end

    context 'with valid authentication' do
      it 'returns paginated list of jobs' do
        get '/api/v1/jobs', headers: headers

        expect(response).to have_http_status(:ok)
        expect(json_response[:data]).to be_present
        expect(valid_pagination?(json_response)).to be true
      end

      it 'filters jobs by status' do
        create(:job, status: 'closed', location: location)
        get '/api/v1/jobs', params: { status: 'closed' }, headers: headers

        expect(response).to have_http_status(:ok)
        expect(json_response[:data].first[:attributes][:status]).to eq('closed')
      end

      it 'filters jobs by location' do
        get '/api/v1/jobs', params: { location_id: location.id }, headers: headers

        expect(response).to have_http_status(:ok)
        expect(json_response[:data].all? { |job| job[:relationships][:location][:data][:id].to_i == location.id }).to be true
      end

      it 'filters jobs by date range' do
        get '/api/v1/jobs',
            params: {
              start_date: Time.current.iso8601,
              end_date: 30.days.from_now.iso8601
            },
            headers: headers

        expect(response).to have_http_status(:ok)
        expect(json_response[:data]).to be_present
      end
    end

    context 'with invalid authentication' do
      it 'returns unauthorized without token' do
        get '/api/v1/jobs'
        expect(response).to have_http_status(:unauthorized)
        expect(error_details[:title]).to eq('Unauthorized')
      end

      it 'returns unauthorized with invalid token' do
        get '/api/v1/jobs', headers: { 'Authorization': 'Bearer invalid_token' }
        expect(response).to have_http_status(:unauthorized)
        expect(error_details[:title]).to eq('Unauthorized')
      end
    end

    context 'with rate limiting' do
      it 'enforces rate limits' do
        allow(Rails.cache).to receive(:read).and_return(1000)
        get '/api/v1/jobs', headers: headers
        expect(response).to have_http_status(:too_many_requests)
        expect(error_details[:title]).to eq('Rate Limit Exceeded')
      end
    end
  end

  describe 'GET /api/v1/jobs/:id' do
    context 'with valid authentication' do
      it 'returns the requested job' do
        get "/api/v1/jobs/#{job.id}", headers: headers

        expect(response).to have_http_status(:ok)
        expect(json_response[:data][:id].to_i).to eq(job.id)
        expect(json_response[:data][:type]).to eq('jobs')
      end

      it 'includes location relationship' do
        get "/api/v1/jobs/#{job.id}", headers: headers

        expect(json_response[:data][:relationships][:location]).to be_present
        expect(json_response[:included]).to be_present
      end

      it 'returns not found for non-existent job' do
        get '/api/v1/jobs/0', headers: headers

        expect(response).to have_http_status(:not_found)
        expect(error_details[:title]).to eq('Not Found')
      end
    end
  end

  describe 'POST /api/v1/jobs' do
    context 'with valid attributes' do
      it 'creates a new job' do
        expect {
          post '/api/v1/jobs',
               params: { job: valid_attributes }.to_json,
               headers: headers
        }.to change(Job, :count).by(1)

        expect(response).to have_http_status(:created)
        expect(json_response[:data][:attributes][:title]).to eq(valid_attributes[:title])
      end

      it 'associates job with location' do
        post '/api/v1/jobs',
             params: { job: valid_attributes }.to_json,
             headers: headers

        expect(json_response[:data][:relationships][:location][:data][:id].to_i).to eq(location.id)
      end
    end

    context 'with invalid attributes' do
      it 'returns validation errors' do
        post '/api/v1/jobs',
             params: { job: invalid_attributes }.to_json,
             headers: headers

        expect(response).to have_http_status(:unprocessable_entity)
        expect(error_details[:detail]).to include('Title can\'t be blank')
      end
    end
  end

  describe 'PUT /api/v1/jobs/:id' do
    context 'with valid attributes' do
      let(:update_attributes) { { title: 'Updated Job Title' } }

      it 'updates the job' do
        put "/api/v1/jobs/#{job.id}",
            params: { job: update_attributes }.to_json,
            headers: headers

        expect(response).to have_http_status(:ok)
        expect(json_response[:data][:attributes][:title]).to eq('Updated Job Title')
      end
    end

    context 'with invalid attributes' do
      it 'returns validation errors' do
        put "/api/v1/jobs/#{job.id}",
            params: { job: invalid_attributes }.to_json,
            headers: headers

        expect(response).to have_http_status(:unprocessable_entity)
        expect(error_details[:detail]).to include('Title can\'t be blank')
      end
    end

    context 'with non-existent job' do
      it 'returns not found' do
        put '/api/v1/jobs/0',
            params: { job: valid_attributes }.to_json,
            headers: headers

        expect(response).to have_http_status(:not_found)
        expect(error_details[:title]).to eq('Not Found')
      end
    end
  end

  describe 'DELETE /api/v1/jobs/:id' do
    it 'soft deletes the job' do
      delete "/api/v1/jobs/#{job.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(Job.unscoped.find(job.id).active).to be false
    end

    it 'returns not found for non-existent job' do
      delete '/api/v1/jobs/0', headers: headers

      expect(response).to have_http_status(:not_found)
      expect(error_details[:title]).to eq('Not Found')
    end
  end

  describe 'PUT /api/v1/jobs/:id/status' do
    let(:status_update) { { status: 'closed' } }

    context 'with valid status transition' do
      it 'updates job status' do
        put "/api/v1/jobs/#{job.id}/status",
            params: status_update.to_json,
            headers: headers

        expect(response).to have_http_status(:ok)
        expect(json_response[:data][:attributes][:status]).to eq('closed')
      end
    end

    context 'with invalid status' do
      it 'returns validation error' do
        put "/api/v1/jobs/#{job.id}/status",
            params: { status: 'invalid' }.to_json,
            headers: headers

        expect(response).to have_http_status(:unprocessable_entity)
        expect(error_details[:detail]).to include('Status is not included in the list')
      end
    end
  end
end