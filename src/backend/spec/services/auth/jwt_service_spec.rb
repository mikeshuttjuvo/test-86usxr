# frozen_string_literal: true

require 'rails_helper'
require 'timecop'
require 'benchmark'

RSpec.describe JWTService, type: :service do
  let(:user_id) { 1 }
  let(:valid_payload) { { user_id: user_id, scope: 'api:access' } }
  let(:jwt_secret) { 'test_secret_key' }
  let(:blacklist_service) { instance_double(TokenBlacklistService) }
  let(:service) { described_class.new(valid_payload) }

  before do
    allow(ENV).to receive(:[]).with('JWT_SECRET').and_return(jwt_secret)
    allow(TokenBlacklistService).to receive(:new).and_return(blacklist_service)
    allow(blacklist_service).to receive(:blacklisted?).and_return(false)
  end

  after do
    Timecop.return
  end

  describe '#generate_token' do
    context 'with valid payload' do
      it 'generates a valid JWT token' do
        token = service.generate_token
        expect(token).to be_a(String)
        expect(service).to be_success
      end

      it 'includes all required security claims' do
        token = service.generate_token
        decoded_payload = JWT.decode(token, jwt_secret, true, algorithm: 'HS256').first

        expect(decoded_payload).to include(
          'jti',
          'iat',
          'exp',
          'typ'
        )
      end

      it 'sets correct token type' do
        token = service.generate_token
        decoded_payload = JWT.decode(token, jwt_secret, true, algorithm: 'HS256').first
        
        expect(decoded_payload['typ']).to eq('access')
      end

      it 'sets expiration to 24 hours from now' do
        current_time = Time.current
        Timecop.freeze(current_time) do
          token = service.generate_token
          decoded_payload = JWT.decode(token, jwt_secret, true, algorithm: 'HS256').first
          
          expect(decoded_payload['exp']).to eq((current_time + 24.hours).to_i)
        end
      end

      it 'generates unique JTI for each token' do
        token1 = service.generate_token
        token2 = described_class.new(valid_payload).generate_token
        
        payload1 = JWT.decode(token1, jwt_secret, true, algorithm: 'HS256').first
        payload2 = JWT.decode(token2, jwt_secret, true, algorithm: 'HS256').first
        
        expect(payload1['jti']).not_to eq(payload2['jti'])
      end
    end

    context 'with invalid payload' do
      it 'raises error for non-hash payload' do
        service = described_class.new('invalid')
        service.generate_token
        
        expect(service).not_to be_success
        expect(service.errors.first[:title]).to eq('Argument Error')
      end

      it 'raises error when JWT_SECRET is not set' do
        allow(ENV).to receive(:[]).with('JWT_SECRET').and_return(nil)
        service.generate_token
        
        expect(service).not_to be_success
        expect(service.errors.first[:detail]).to include('JWT_SECRET')
      end
    end

    context 'performance' do
      it 'generates tokens within acceptable time' do
        time = Benchmark.realtime do
          100.times { service.generate_token }
        end
        
        expect(time).to be < 1.0 # Should complete 100 generations within 1 second
      end
    end
  end

  describe '#validate_token' do
    let(:valid_token) { service.generate_token }
    let(:validator) { described_class.new(valid_token) }

    context 'with valid token' do
      it 'successfully validates token' do
        result = validator.validate_token
        
        expect(result).to be_success
        expect(result.payload).to include('user_id' => user_id)
      end

      it 'accepts tokens within leeway period' do
        Timecop.travel(Time.current + described_class::LEEWAY - 1.second) do
          result = validator.validate_token
          expect(result).to be_success
        end
      end
    end

    context 'with invalid token' do
      it 'fails for expired token' do
        Timecop.travel(Time.current + 25.hours) do
          result = validator.validate_token
          
          expect(result).not_to be_success
          expect(result.errors.first[:detail]).to include('expired')
        end
      end

      it 'fails for token with invalid signature' do
        tampered_token = valid_token[0..-2] + (valid_token[-1].ord ^ 1).chr
        result = described_class.new(tampered_token).validate_token
        
        expect(result).not_to be_success
        expect(result.errors.first[:detail]).to include('signature')
      end

      it 'fails for malformed token' do
        result = described_class.new('invalid.token.format').validate_token
        
        expect(result).not_to be_success
        expect(result.errors.first[:detail]).to include('Invalid token')
      end

      it 'fails for empty token' do
        result = described_class.new('').validate_token
        
        expect(result).not_to be_success
        expect(result.errors.first[:detail]).to include('missing or empty')
      end

      it 'fails for blacklisted token' do
        allow(blacklist_service).to receive(:blacklisted?).and_return(true)
        result = validator.validate_token
        
        expect(result).not_to be_success
      end
    end

    context 'security claims' do
      it 'validates all required claims' do
        result = validator.validate_token
        
        expect(result.payload).to include(
          'jti',
          'iat',
          'exp',
          'typ'
        )
      end

      it 'validates token type' do
        result = validator.validate_token
        expect(result.payload['typ']).to eq('access')
      end

      it 'validates issued at timestamp' do
        result = validator.validate_token
        expect(result.payload['iat']).to be_within(1).of(Time.current.to_i)
      end
    end

    context 'performance' do
      it 'validates tokens within acceptable time' do
        time = Benchmark.realtime do
          100.times { validator.validate_token }
        end
        
        expect(time).to be < 1.0 # Should complete 100 validations within 1 second
      end

      it 'handles concurrent validations efficiently' do
        tokens = 10.times.map { service.generate_token }
        
        time = Benchmark.realtime do
          threads = tokens.map do |token|
            Thread.new { described_class.new(token).validate_token }
          end
          threads.each(&:join)
        end
        
        expect(time).to be < 0.5 # Should handle concurrent validations efficiently
      end
    end
  end
end