# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CacheCleanupJob, type: :job do
  let(:redis) { instance_double(Redis) }
  let(:job) { described_class.new }
  let(:test_keys) { (1..10).map { |i| "test:key:#{i}" } }
  let(:execution_time) { described_class::MAX_EXECUTION_TIME }
  let(:batch_size) { described_class::BATCH_SIZE }

  before(:each) do
    allow(REDIS_CACHE_POOL).to receive(:with).and_yield(redis)
    allow(NewRelic::Agent).to receive(:record_metric)
    allow(NewRelic::Agent).to receive(:increment_metric)
    allow(NewRelic::Agent).to receive(:notice_error)
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:warn)
    allow(Rails.logger).to receive(:error)
  end

  describe '#perform' do
    it 'performs cleanup of expired keys' do
      # Setup scan results for two batches
      expect(redis).to receive(:scan).with('0', match: '*', count: batch_size)
        .and_return(['1', test_keys[0..4]])
      expect(redis).to receive(:scan).with('1', match: '*', count: batch_size)
        .and_return(['0', test_keys[5..9]])

      # Setup TTL checks for expired and non-expired keys
      allow(redis).to receive(:pipelined).and_yield(redis).twice
      test_keys[0..4].each do |key|
        expect(redis).to receive(:ttl).with(key).and_return(-1)
      end
      test_keys[5..9].each do |key|
        expect(redis).to receive(:ttl).with(key).and_return(100)
      end

      # Expect deletion of expired keys
      expect(redis).to receive(:del).with(*test_keys[0..4])

      stats = job.perform

      expect(stats[:keys_scanned]).to eq(batch_size * 2)
      expect(stats[:keys_expired]).to eq(5)
      expect(stats[:keys_deleted]).to eq(5)
      expect(stats[:errors]).to eq(0)
      expect(stats[:batches_processed]).to eq(2)
    end

    it 'handles Redis connection errors gracefully' do
      allow(redis).to receive(:scan).and_raise(Redis::ConnectionError)

      expect { job.perform }.to raise_error(Redis::ConnectionError)

      expect(NewRelic::Agent).to have_received(:notice_error)
      expect(Rails.logger).to have_received(:error).with(/Cache cleanup job failed/)
      expect(NewRelic::Agent).to have_received(:increment_metric).with('cache_cleanup.job_errors')
    end

    it 'respects maximum execution time' do
      start_time = Time.current
      allow(Time).to receive(:current).and_return(
        start_time,
        start_time + execution_time + 1.second
      )

      expect(redis).to receive(:scan).once.and_return(['1', test_keys])
      
      job.perform

      expect(Rails.logger).to have_received(:info).with(/Cache cleanup completed/)
    end

    it 'processes keys in batches efficiently' do
      large_key_set = (1..batch_size * 2).map { |i| "test:key:#{i}" }
      
      expect(redis).to receive(:scan).with('0', match: '*', count: batch_size)
        .and_return(['1', large_key_set[0...batch_size]])
      expect(redis).to receive(:scan).with('1', match: '*', count: batch_size)
        .and_return(['0', large_key_set[batch_size..-1]])

      # Mock TTL checks and deletions for both batches
      allow(redis).to receive(:pipelined).and_yield(redis).twice
      large_key_set.each do |key|
        allow(redis).to receive(:ttl).with(key).and_return(-1)
        allow(redis).to receive(:del).with(key)
      end

      stats = job.perform

      expect(stats[:batches_processed]).to eq(2)
      expect(stats[:keys_scanned]).to eq(large_key_set.size)
    end

    it 'reports detailed metrics' do
      allow(redis).to receive(:scan).and_return(['0', test_keys])
      allow(redis).to receive(:pipelined).and_yield(redis)
      test_keys.each do |key|
        allow(redis).to receive(:ttl).with(key).and_return(-1)
        allow(redis).to receive(:del).with(key)
      end

      job.perform

      expect(NewRelic::Agent).to have_received(:record_metric)
        .with('cache_cleanup.keys_scanned', anything)
      expect(NewRelic::Agent).to have_received(:record_metric)
        .with('cache_cleanup.keys_expired', anything)
      expect(NewRelic::Agent).to have_received(:record_metric)
        .with('cache_cleanup.keys_deleted', anything)
      expect(NewRelic::Agent).to have_received(:record_metric)
        .with('cache_cleanup.duration', anything)
    end

    it 'handles partial batch failures' do
      expect(redis).to receive(:scan).and_return(['0', test_keys])
      allow(redis).to receive(:pipelined).and_yield(redis)
      test_keys.each do |key|
        allow(redis).to receive(:ttl).with(key).and_return(-1)
      end

      # Simulate failure during deletion
      allow(redis).to receive(:del).and_raise(Redis::CommandError)

      stats = job.perform

      expect(stats[:errors]).to be > 0
      expect(NewRelic::Agent).to have_received(:notice_error)
      expect(Rails.logger).to have_received(:error).with(/Error deleting cache keys/)
    end

    it 'calculates and reports cache efficiency metrics' do
      allow(redis).to receive(:scan).and_return(['0', test_keys])
      allow(redis).to receive(:pipelined).and_yield(redis)
      test_keys.each do |key|
        allow(redis).to receive(:ttl).with(key).and_return(-1)
        allow(redis).to receive(:del).with(key)
      end

      job.perform

      expect(NewRelic::Agent).to have_received(:record_metric)
        .with('cache_cleanup.expiration_rate', 100.0)
      expect(NewRelic::Agent).to have_received(:record_metric)
        .with('cache_cleanup.success_rate', 100.0)
    end
  end
end