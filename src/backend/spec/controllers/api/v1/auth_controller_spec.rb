# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::AuthController, type: :controller do
  # Include request spec helper for JSON parsing and header utilities
  include RequestSpecHelper

  # Set up test data
  let(:user) { create(:user) }
  let(:valid_credentials) { { email: user.email, password: 'Password1@3456' } }
  let(:invalid_credentials) { { email: user.email, password: 'wrong' } }
  let(:jwt_service) { JWTService.new({ user_id: user.id }) }
  let(:valid_token) { jwt_service.generate_token }

  describe '#login' do
    context 'with valid credentials' do
      before { post :login, params: valid_credentials, format: :json }

      it 'returns 200 status code' do
        expect(response).to have_http_status(:ok)
      end

      it 'returns a valid JWT token' do
        expect(json_response[:token]).to be_present
        expect(valid_jwt_format?(json_response[:token])).to be true
      end

      it 'sets token expiry to 24 hours' do
        token_payload = JWT.decode(json_response[:token], nil, false).first
        expect(token_payload['exp'] - token_payload['iat']).to eq(24.hours.to_i)
      end

      it 'includes required security headers' do
        expect(response.headers['X-Frame-Options']).to eq('DENY')
        expect(response.headers['X-Content-Type-Options']).to eq('nosniff')
        expect(response.headers['X-XSS-Protection']).to eq('1; mode=block')
      end

      it 'tracks successful login metrics' do
        expect(NewRelic::Agent).to receive(:record_metric)
          .with('Custom/Auth/login_success', 1)
      end
    end

    context 'with invalid credentials' do
      before { post :login, params: invalid_credentials, format: :json }

      it 'returns 401 status code' do
        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns RFC 7807 compliant error response' do
        expect(response.content_type).to eq('application/problem+json; charset=utf-8')
        expect(error_details).to include(
          title: 'Authentication Failed',
          status: 401,
          detail: 'Invalid email or password'
        )
      end

      it 'increments failed login attempts' do
        user.reload
        expect(user.failed_attempts).to eq(1)
      end

      it 'tracks failed login metrics' do
        expect(NewRelic::Agent).to receive(:record_metric)
          .with('Custom/Auth/login_failure', 1)
      end
    end

    context 'when rate limited' do
      before do
        allow_any_instance_of(RateLimiter).to receive(:exceeded?)
          .and_return(true)
        post :login, params: valid_credentials, format: :json
      end

      it 'returns 429 status code' do
        expect(response).to have_http_status(:too_many_requests)
      end

      it 'includes rate limit headers' do
        expect(response.headers['X-RateLimit-Limit']).to eq('1000')
        expect(response.headers['X-RateLimit-Remaining']).to eq('0')
        expect(response.headers['X-RateLimit-Reset']).to be_present
      end
    end
  end

  describe '#logout' do
    context 'with valid token' do
      before do
        request.headers['Authorization'] = "Bearer #{valid_token}"
        post :logout, format: :json
      end

      it 'returns 204 status code' do
        expect(response).to have_http_status(:no_content)
      end

      it 'adds token to blacklist' do
        token_blacklist = TokenBlacklistService.new(valid_token)
        expect(token_blacklist.blacklisted?).to be true
      end

      it 'tracks logout metrics' do
        expect(NewRelic::Agent).to receive(:record_metric)
          .with('Custom/Auth/logout', 1)
      end
    end

    context 'with invalid token' do
      before do
        request.headers['Authorization'] = 'Bearer invalid_token'
        post :logout, format: :json
      end

      it 'returns 401 status code' do
        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns RFC 7807 error response' do
        expect(error_details[:title]).to eq('Invalid Token')
        expect(error_details[:status]).to eq(401)
      end
    end
  end

  describe '#refresh' do
    context 'with valid token' do
      before do
        request.headers['Authorization'] = "Bearer #{valid_token}"
        post :refresh, format: :json
      end

      it 'returns 200 status code' do
        expect(response).to have_http_status(:ok)
      end

      it 'returns a new valid token' do
        expect(json_response[:token]).to be_present
        expect(json_response[:token]).not_to eq(valid_token)
      end

      it 'blacklists old token' do
        token_blacklist = TokenBlacklistService.new(valid_token)
        expect(token_blacklist.blacklisted?).to be true
      end

      it 'extends token expiry by 24 hours' do
        new_token_payload = JWT.decode(json_response[:token], nil, false).first
        expect(new_token_payload['exp'] - Time.current.to_i).to be_within(5).of(24.hours.to_i)
      end
    end

    context 'with expired token' do
      let(:expired_token) do
        JWT.encode(
          { 
            user_id: user.id,
            exp: 1.day.ago.to_i,
            jti: SecureRandom.uuid
          },
          Rails.application.credentials.jwt_secret_key,
          'HS256'
        )
      end

      before do
        request.headers['Authorization'] = "Bearer #{expired_token}"
        post :refresh, format: :json
      end

      it 'returns 401 status code' do
        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns token expired error' do
        expect(error_details[:detail]).to eq('Token has expired')
      end
    end
  end

  describe '#validate' do
    context 'with valid token' do
      before do
        request.headers['Authorization'] = "Bearer #{valid_token}"
        get :validate, format: :json
      end

      it 'returns 200 status code' do
        expect(response).to have_http_status(:ok)
      end

      it 'returns token validity status' do
        expect(json_response[:valid]).to be true
        expect(json_response[:expires_at]).to be_present
      end
    end

    context 'with blacklisted token' do
      before do
        TokenBlacklistService.new(valid_token).blacklist
        request.headers['Authorization'] = "Bearer #{valid_token}"
        get :validate, format: :json
      end

      it 'returns 401 status code' do
        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns blacklisted token error' do
        expect(error_details[:detail]).to eq('Token has been revoked')
      end
    end

    context 'with missing token' do
      before { get :validate, format: :json }

      it 'returns 401 status code' do
        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns missing token error' do
        expect(error_details[:detail]).to eq('No token provided')
      end
    end
  end
end