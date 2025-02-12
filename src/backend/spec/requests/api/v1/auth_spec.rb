# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Authentication API', type: :request do
  include RequestSpecHelper

  let(:user) { create(:user) }
  let(:valid_credentials) { { email: user.email, password: 'Password1@3456' } }
  let(:invalid_credentials) { { email: user.email, password: 'wrongpassword' } }
  let(:expired_token_user) { create(:user, :with_custom_password) }
  let(:blacklisted_token_user) { create(:user, :with_custom_password) }

  before(:each) do
    # Clear Redis cache and rate limit counters
    REDIS_CACHE_POOL.with { |redis| redis.flushdb }
    REDIS_AUTH_POOL.with { |redis| redis.flushdb }
  end

  shared_examples 'unauthorized_request' do
    it 'returns 401 status code' do
      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns RFC 7807 compliant error response' do
      expect(valid_error_response?(json_response)).to be true
    end

    it 'includes proper error details' do
      error = error_details
      expect(error[:type]).to match(%r{https://api\.example\.com/errors/})
      expect(error[:title]).to be_present
      expect(error[:status]).to eq(401)
      expect(error[:detail]).to be_present
    end

    it 'verifies response time is under 500ms' do
      verify_response_time(500)
    end

    it 'verifies audit log entry creation' do
      expect(AuditLog.last).to have_attributes(
        action: 'authentication_failure',
        resource_type: 'User'
      )
    end
  end

  shared_examples 'rate_limited_request' do
    it 'returns 429 status code' do
      expect(response).to have_http_status(:too_many_requests)
    end

    it 'returns RFC 7807 compliant error response' do
      expect(valid_error_response?(json_response)).to be true
    end

    it 'includes retry-after header' do
      expect(response.headers['Retry-After']).to be_present
    end

    it 'verifies Redis rate limit counter' do
      REDIS_AUTH_POOL.with do |redis|
        key = "rate_limit:auth:#{request.remote_ip}"
        expect(redis.get(key).to_i).to be > 0
      end
    end
  end

  describe 'POST /api/v1/auth/login' do
    context 'with valid credentials' do
      before { post '/api/v1/auth/login', params: valid_credentials.to_json, headers: json_request_headers }

      it 'returns 200 status code' do
        expect(response).to have_http_status(:ok)
      end

      it 'returns JWT token with proper claims' do
        expect(json_response[:token]).to be_present
        decoded_token = JWT.decode(
          json_response[:token],
          ENV['JWT_SECRET'],
          true,
          { algorithm: 'HS256' }
        ).first

        expect(decoded_token).to include(
          'user_id' => user.id,
          'email' => user.email,
          'typ' => 'access'
        )
      end

      it 'verifies token expiration is set to 24 hours' do
        decoded_token = JWT.decode(
          json_response[:token],
          ENV['JWT_SECRET'],
          true,
          { algorithm: 'HS256' }
        ).first

        expect(decoded_token['exp'] - decoded_token['iat']).to eq(24.hours.to_i)
      end

      it 'creates audit log entry for successful login' do
        expect(AuditLog.last).to have_attributes(
          action: 'authentication_success',
          resource_type: 'User',
          resource_id: user.id
        )
      end
    end

    context 'with invalid credentials' do
      before { post '/api/v1/auth/login', params: invalid_credentials.to_json, headers: json_request_headers }

      it_behaves_like 'unauthorized_request'

      it 'increments failed login attempts' do
        user.reload
        expect(user.failed_attempts).to eq(1)
      end
    end

    context 'with rate limiting' do
      it 'blocks after multiple failed attempts' do
        6.times do
          post '/api/v1/auth/login', params: invalid_credentials.to_json, headers: json_request_headers
        end

        expect(response).to have_http_status(:too_many_requests)
      end

      it_behaves_like 'rate_limited_request'
    end

    context 'with SQL injection attempt' do
      let(:malicious_email) { "' OR '1'='1" }
      
      before do
        post '/api/v1/auth/login',
             params: { email: malicious_email, password: 'password' }.to_json,
             headers: json_request_headers
      end

      it 'prevents SQL injection' do
        expect(response).to have_http_status(:unauthorized)
        expect(User.count).to eq(1) # Verifies no unauthorized access
      end
    end
  end

  describe 'DELETE /api/v1/auth/logout' do
    let(:auth_token) { JWTService.new(user_id: user.id).generate_token }

    context 'with valid token' do
      before do
        delete '/api/v1/auth/logout',
               headers: auth_headers(user)
      end

      it 'returns 200 status code' do
        expect(response).to have_http_status(:ok)
      end

      it 'blacklists the token' do
        REDIS_AUTH_POOL.with do |redis|
          expect(TokenBlacklistService.new(auth_token).blacklisted?).to be true
        end
      end

      it 'creates audit log entry for logout' do
        expect(AuditLog.last).to have_attributes(
          action: 'logout',
          resource_type: 'User',
          resource_id: user.id
        )
      end
    end

    context 'with invalid token' do
      before do
        delete '/api/v1/auth/logout',
               headers: json_request_headers.merge('Authorization' => 'Bearer invalid')
      end

      it_behaves_like 'unauthorized_request'
    end

    context 'with blacklisted token' do
      before do
        TokenBlacklistService.new(auth_token).blacklist
        delete '/api/v1/auth/logout',
               headers: auth_headers(user)
      end

      it_behaves_like 'unauthorized_request'
    end
  end

  describe 'POST /api/v1/auth/refresh' do
    let(:auth_token) { JWTService.new(user_id: user.id).generate_token }

    context 'with valid token' do
      before do
        post '/api/v1/auth/refresh',
             headers: auth_headers(user)
      end

      it 'returns 200 status code' do
        expect(response).to have_http_status(:ok)
      end

      it 'returns new JWT token' do
        expect(json_response[:token]).to be_present
        expect(json_response[:token]).not_to eq(auth_token)
      end

      it 'verifies new token claims' do
        decoded_token = JWT.decode(
          json_response[:token],
          ENV['JWT_SECRET'],
          true,
          { algorithm: 'HS256' }
        ).first

        expect(decoded_token).to include(
          'user_id' => user.id,
          'email' => user.email
        )
      end
    end

    context 'with expired token' do
      before do
        expired_token = JWTService.new(
          user_id: expired_token_user.id,
          exp: 1.day.ago.to_i
        ).generate_token

        post '/api/v1/auth/refresh',
             headers: json_request_headers.merge('Authorization' => "Bearer #{expired_token}")
      end

      it_behaves_like 'unauthorized_request'
    end

    context 'with blacklisted token' do
      before do
        TokenBlacklistService.new(auth_token).blacklist
        post '/api/v1/auth/refresh',
             headers: auth_headers(user)
      end

      it_behaves_like 'unauthorized_request'
    end
  end

  describe 'GET /api/v1/auth/validate' do
    context 'with valid token' do
      before do
        get '/api/v1/auth/validate',
            headers: auth_headers(user)
      end

      it 'returns 200 status code' do
        expect(response).to have_http_status(:ok)
      end

      it 'returns user information' do
        expect(json_response[:user]).to include(
          id: user.id,
          email: user.email,
          role: user.role
        )
      end

      it 'verifies response time' do
        verify_response_time(500)
      end
    end

    context 'with invalid token signature' do
      before do
        get '/api/v1/auth/validate',
            headers: json_request_headers.merge('Authorization' => 'Bearer invalid.token.signature')
      end

      it_behaves_like 'unauthorized_request'
    end

    context 'with expired token' do
      before do
        expired_token = JWTService.new(
          user_id: expired_token_user.id,
          exp: 1.day.ago.to_i
        ).generate_token

        get '/api/v1/auth/validate',
            headers: json_request_headers.merge('Authorization' => "Bearer #{expired_token}")
      end

      it_behaves_like 'unauthorized_request'
    end
  end
end