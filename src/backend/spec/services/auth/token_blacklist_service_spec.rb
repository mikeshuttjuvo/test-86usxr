# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TokenBlacklistService do
  let(:jwt_secret) { 'test_secret_key' }
  let(:valid_payload) do
    {
      user_id: 1,
      email: 'test@example.com',
      jti: SecureRandom.uuid,
      iat: Time.current.to_i,
      exp: 24.hours.from_now.to_i
    }
  end
  let(:valid_token) { JWT.encode(valid_payload, jwt_secret, 'HS256') }
  let(:expired_payload) { valid_payload.merge(exp: 1.hour.ago.to_i) }
  let(:expired_token) { JWT.encode(expired_payload, jwt_secret, 'HS256') }
  let(:invalid_token) { 'invalid.jwt.token' }
  let(:redis_pool_size) { 5 }
  let(:redis_timeout) { 5 }
  let(:batch_size) { 100 }
  let(:cache_ttl) { 300 }

  let(:service_options) do
    {
      pool_size: redis_pool_size,
      timeout: redis_timeout,
      batch_size: batch_size,
      cache_ttl: cache_ttl
    }
  end

  before(:each) do
    allow(ENV).to receive(:[]).with('JWT_SECRET').and_return(jwt_secret)
    allow(ENV).to receive(:[]).with('REDIS_URL').and_return('redis://localhost:6379/1')
    Redis.new(url: ENV['REDIS_URL']).flushdb
    Rails.cache.clear
  end

  describe '#initialize' do
    it 'initializes with valid token and default options' do
      service = described_class.new(valid_token)
      expect(service).to be_a(described_class)
      expect(service.token).to eq(valid_token)
    end

    it 'initializes with custom options' do
      service = described_class.new(valid_token, service_options)
      expect(service).to be_a(described_class)
    end

    it 'sets up NewRelic monitoring' do
      expect(NewRelic::Agent).to receive(:add_custom_attributes).with(
        hash_including(
          service: described_class.name,
          redis_pool_size: redis_pool_size
        )
      )
      described_class.new(valid_token, service_options)
    end
  end

  describe '#blacklist' do
    let(:service) { described_class.new(valid_token, service_options) }

    it 'successfully blacklists a valid token' do
      expect(service.blacklist).to be true
      expect(service.success?).to be true
    end

    it 'stores token with correct expiration' do
      service.blacklist
      redis = Redis.new(url: ENV['REDIS_URL'])
      ttl = redis.ttl(service.send(:blacklist_key))
      expect(ttl).to be_between(0, 24.hours.to_i)
    end

    it 'handles Redis connection errors with retries' do
      allow_any_instance_of(Redis).to receive(:multi).and_raise(Redis::CannotConnectError)
      expect(service).to receive(:sleep).exactly(3).times
      expect(service.blacklist).to be false
    end

    it 'reports metrics to NewRelic' do
      expect(NewRelic::Agent).to receive(:record_metric)
        .with('Custom/TokenBlacklist/blacklist_operation', 1)
      service.blacklist
    end

    it 'logs blacklist operations' do
      expect(Rails.logger).to receive(:info).with(/\[TokenBlacklist\] Token blacklisted/)
      service.blacklist
    end

    it 'returns false for invalid tokens' do
      invalid_service = described_class.new(invalid_token, service_options)
      expect(invalid_service.blacklist).to be false
    end

    it 'maintains performance under 500ms' do
      start_time = Time.current
      service.blacklist
      execution_time = Time.current - start_time
      expect(execution_time).to be < 0.5
    end
  end

  describe '#blacklisted?' do
    let(:service) { described_class.new(valid_token, service_options) }

    before { service.blacklist }

    it 'returns true for blacklisted tokens' do
      expect(service.blacklisted?).to be true
    end

    it 'returns false for non-blacklisted tokens' do
      new_token = JWT.encode(valid_payload.merge(jti: SecureRandom.uuid), jwt_secret, 'HS256')
      new_service = described_class.new(new_token, service_options)
      expect(new_service.blacklisted?).to be false
    end

    it 'utilizes cache for repeated checks' do
      expect(Rails.cache).to receive(:read).with(/#{TokenBlacklistService::REDIS_NAMESPACE}/).once
      expect(Rails.cache).to receive(:write).with(/#{TokenBlacklistService::REDIS_NAMESPACE}/, true, expires_in: cache_ttl).once
      2.times { service.blacklisted? }
    end

    it 'handles Redis connection errors gracefully' do
      allow_any_instance_of(Redis).to receive(:hexists).and_raise(Redis::CannotConnectError)
      expect(service.blacklisted?).to be false
    end

    it 'maintains performance under 500ms' do
      start_time = Time.current
      service.blacklisted?
      execution_time = Time.current - start_time
      expect(execution_time).to be < 0.5
    end
  end

  describe '#cleanup_expired' do
    let(:service) { described_class.new(valid_token, service_options) }

    before do
      # Add some expired and valid tokens
      5.times do
        token = JWT.encode(expired_payload.merge(jti: SecureRandom.uuid), jwt_secret, 'HS256')
        described_class.new(token, service_options).blacklist
      end
      3.times do
        token = JWT.encode(valid_payload.merge(jti: SecureRandom.uuid), jwt_secret, 'HS256')
        described_class.new(token, service_options).blacklist
      end
    end

    it 'removes expired tokens' do
      removed_count = service.cleanup_expired
      expect(removed_count).to eq(5)
      expect(service.success?).to be true
    end

    it 'processes tokens in batches' do
      allow_any_instance_of(Redis).to receive(:hscan).and_call_original
      service.cleanup_expired
      expect(service.success?).to be true
    end

    it 'reports cleanup metrics to NewRelic' do
      expect(NewRelic::Agent).to receive(:record_metric)
        .with('Custom/TokenBlacklist/cleanup_operation', kind_of(Integer))
      service.cleanup_expired
    end

    it 'handles Redis connection errors gracefully' do
      allow_any_instance_of(Redis).to receive(:hscan).and_raise(Redis::CannotConnectError)
      expect(service.cleanup_expired).to eq(0)
    end

    it 'maintains performance under 500ms for small batches' do
      start_time = Time.current
      service.cleanup_expired
      execution_time = Time.current - start_time
      expect(execution_time).to be < 0.5
    end
  end

  context 'error handling' do
    let(:service) { described_class.new(valid_token, service_options) }

    it 'handles JWT decode errors' do
      invalid_service = described_class.new('invalid.token', service_options)
      expect(invalid_service.blacklist).to be false
      expect(invalid_service.errors).not_to be_empty
    end

    it 'notifies NewRelic of Redis errors' do
      allow_any_instance_of(Redis).to receive(:multi).and_raise(Redis::CannotConnectError)
      expect(NewRelic::Agent).to receive(:notice_error).with(
        kind_of(Redis::CannotConnectError),
        hash_including(:custom_params)
      )
      service.blacklist
    end
  end
end