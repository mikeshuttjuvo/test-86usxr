# frozen_string_literal: true

require 'sidekiq'
require 'datadog/statsd' # ~> 5.5.0
require 'newrelic_rpm'   # ~> 8.15.0

# Configure default job options for all Sidekiq jobs
Sidekiq.default_job_options = {
  retry: 10,                # Number of retry attempts
  backtrace: 20,           # Number of backtrace lines to store
  queue: 'default',        # Default queue for jobs
  dead: true,              # Enable dead job tracking
  failures: true           # Track job failures
}

# Configure Sidekiq server-side settings
Sidekiq.configure_server do |config|
  # Initialize Redis connection pool with circuit breaker
  config.redis = REDIS_SIDEKIQ_POOL

  # Set environment-specific concurrency
  config.concurrency = case Rails.env
                      when 'development' then 5
                      when 'test' then 3
                      when 'production' then 25
                      end

  # Configure queue weights for priority processing
  config.queues = [
    ['critical', 5],      # Highest priority
    ['default', 3],       # Standard priority
    ['low', 1],          # Low priority
    ['audit', 2],        # Audit logging
    ['maintenance', 1]    # System maintenance
  ]

  # Configure server middleware
  config.server_middleware do |chain|
    # Add NewRelic transaction tracking
    chain.add NewRelic::SidekiqInstrumentation

    # Add custom error tracking middleware
    chain.add(Class.new do
      def call(worker, job, queue)
        start_time = Time.now
        yield
      rescue => error
        report_error(worker, job, error)
        raise
      ensure
        duration = Time.now - start_time
        report_metrics(worker, queue, duration)
      end

      private

      def report_error(worker, job, error)
        NewRelic::Agent.notice_error(error)
        statsd.increment('sidekiq.job.error', tags: ["worker:#{worker.class}", "queue:#{job['queue']}"])
      end

      def report_metrics(worker, queue, duration)
        statsd.timing('sidekiq.job.duration', duration * 1000, tags: ["worker:#{worker.class}", "queue:#{queue}"])
        statsd.increment('sidekiq.job.processed', tags: ["worker:#{worker.class}", "queue:#{queue}"])
      end

      def statsd
        @statsd ||= Datadog::Statsd.new('localhost', 8125, namespace: 'app.sidekiq')
      end
    end)
  end

  # Configure dead job retention
  config.death_handlers << ->(job, ex) do
    NewRelic::Agent.notice_error(ex)
    statsd = Datadog::Statsd.new('localhost', 8125, namespace: 'app.sidekiq')
    statsd.increment('sidekiq.job.dead', tags: ["queue:#{job['queue']}", "error:#{ex.class}"])
  end

  # Set up periodic health checks
  config.on(:startup) do
    Thread.new do
      loop do
        check_sidekiq_health
        sleep 60 # Check every minute
      end
    end
  end

  # Configure error handlers
  config.error_handlers << ->(ex, ctx_hash) do
    NewRelic::Agent.notice_error(ex)
    Rails.logger.error("Sidekiq error: #{ex.message}\nContext: #{ctx_hash}")
  end
end

# Configure Sidekiq client-side settings
Sidekiq.configure_client do |config|
  # Initialize Redis connection pool
  config.redis = REDIS_SIDEKIQ_POOL

  # Configure client middleware
  config.client_middleware do |chain|
    chain.add(Class.new do
      def call(worker_class, job, queue, redis_pool)
        statsd.increment('sidekiq.job.enqueued', tags: ["worker:#{worker_class}", "queue:#{queue}"])
        yield
      end

      private

      def statsd
        @statsd ||= Datadog::Statsd.new('localhost', 8125, namespace: 'app.sidekiq')
      end
    end)
  end
end

# Health check implementation
def check_sidekiq_health
  statsd = Datadog::Statsd.new('localhost', 8125, namespace: 'app.sidekiq')
  
  # Check Redis connection
  REDIS_SIDEKIQ_POOL.with do |redis|
    raise 'Redis connection failed' unless redis.ping == 'PONG'
  end

  # Check queue sizes
  Sidekiq::Queue.all.each do |queue|
    statsd.gauge('sidekiq.queue.size', queue.size, tags: ["queue:#{queue.name}"])
    statsd.gauge('sidekiq.queue.latency', queue.latency, tags: ["queue:#{queue.name}"])
  end

  # Check process metrics
  statsd.gauge('sidekiq.processes', Sidekiq::ProcessSet.new.size)
  statsd.gauge('sidekiq.workers', Sidekiq::Workers.new.size)

  # Check memory usage
  memory = GetProcessMem.new.mb
  statsd.gauge('sidekiq.memory_usage_mb', memory)

  true
rescue => e
  NewRelic::Agent.notice_error(e)
  Rails.logger.error("Sidekiq health check failed: #{e.message}")
  false
end

# Register Sidekiq shutdown hooks
at_exit do
  Sidekiq.redis_pool.shutdown { |redis| redis.quit }
end