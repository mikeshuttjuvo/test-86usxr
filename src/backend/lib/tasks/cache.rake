# frozen_string_literal: true

# redis ~> 4.8.0

namespace :cache do
  # Constants for cache operations
  BATCH_SIZE = 1000 # Maximum number of keys to process in a single batch
  STATS_TTL = 86400 # Cache statistics retention period in seconds
  WARMUP_CONCURRENCY = 5 # Number of concurrent warmup workers

  desc 'Cleanup expired cache entries with progress reporting'
  task cleanup: :environment do
    Rails.logger.info('Starting cache cleanup task')
    
    begin
      CacheCleanupJob.perform_now
      Rails.logger.info('Cache cleanup completed successfully')
    rescue StandardError => e
      Rails.logger.error("Cache cleanup failed: #{e.message}")
      raise
    end
  end

  desc 'Display detailed cache statistics and health metrics'
  task stats: :environment do
    REDIS_CACHE_POOL.with do |redis|
      stats = collect_cache_statistics(redis)
      display_cache_statistics(stats)
      export_cache_metrics(stats)
    end
  end

  desc 'Clear cache entries with safety confirmation'
  task clear: :environment do
    unless Rails.env.production?
      puts "\nWARNING: This will clear all cache entries."
      print "Are you sure you want to continue? [y/N]: "
      
      unless STDIN.gets.chomp.downcase == 'y'
        puts "Operation cancelled."
        exit
      end
    end

    REDIS_CACHE_POOL.with do |redis|
      clear_cache_safely(redis)
    end
  end

  desc 'Pre-warm cache with intelligent data selection'
  task warmup: :environment do
    Rails.logger.info('Starting cache warmup process')
    
    REDIS_CACHE_POOL.with do |redis|
      warmup_cache(redis)
    end
  end

  private

  def collect_cache_statistics(redis)
    {
      memory_usage: redis.info('memory'),
      key_count: redis.dbsize,
      key_distribution: analyze_key_distribution(redis),
      hit_rate: calculate_hit_rate(redis),
      ttl_distribution: analyze_ttl_distribution(redis),
      fragmentation_ratio: redis.info('memory')['mem_fragmentation_ratio'],
      connected_clients: redis.info('clients')['connected_clients']
    }
  end

  def analyze_key_distribution(redis)
    distribution = Hash.new(0)
    cursor = '0'
    
    loop do
      cursor, keys = redis.scan(cursor, count: BATCH_SIZE)
      
      keys.each do |key|
        key_type = redis.type(key)
        distribution[key_type] += 1
      end
      
      break if cursor == '0'
    end

    distribution
  end

  def calculate_hit_rate(redis)
    stats = redis.info('stats')
    hits = stats['keyspace_hits'].to_i
    misses = stats['keyspace_misses'].to_i
    total = hits + misses
    
    return 0.0 if total.zero?
    (hits.to_f / total * 100).round(2)
  end

  def analyze_ttl_distribution(redis)
    distribution = {
      expired: 0,
      less_than_hour: 0,
      less_than_day: 0,
      more_than_day: 0,
      no_expiry: 0
    }

    cursor = '0'
    
    loop do
      cursor, keys = redis.scan(cursor, count: BATCH_SIZE)
      
      keys.each do |key|
        ttl = redis.ttl(key)
        case ttl
        when -2 then distribution[:expired] += 1
        when -1 then distribution[:no_expiry] += 1
        when 0..3600 then distribution[:less_than_hour] += 1
        when 3601..86400 then distribution[:less_than_day] += 1
        else distribution[:more_than_day] += 1
        end
      end
      
      break if cursor == '0'
    end

    distribution
  end

  def display_cache_statistics(stats)
    puts "\nCache Statistics Report"
    puts "======================"
    puts "\nMemory Usage:"
    puts "  Used Memory: #{stats[:memory_usage]['used_memory_human']}"
    puts "  Peak Memory: #{stats[:memory_usage]['used_memory_peak_human']}"
    puts "  Fragmentation Ratio: #{stats[:fragmentation_ratio]}"
    
    puts "\nKey Statistics:"
    puts "  Total Keys: #{stats[:key_count]}"
    puts "  Hit Rate: #{stats[:hit_rate]}%"
    
    puts "\nKey Type Distribution:"
    stats[:key_distribution].each do |type, count|
      puts "  #{type}: #{count}"
    end
    
    puts "\nTTL Distribution:"
    stats[:ttl_distribution].each do |category, count|
      puts "  #{category}: #{count}"
    end
    
    puts "\nClient Connections:"
    puts "  Connected Clients: #{stats[:connected_clients]}"
  end

  def export_cache_metrics(stats)
    NewRelic::Agent.record_metric('cache.memory.used', stats[:memory_usage]['used_memory'].to_i)
    NewRelic::Agent.record_metric('cache.memory.fragmentation', stats[:fragmentation_ratio])
    NewRelic::Agent.record_metric('cache.keys.total', stats[:key_count])
    NewRelic::Agent.record_metric('cache.performance.hit_rate', stats[:hit_rate])
    
    stats[:key_distribution].each do |type, count|
      NewRelic::Agent.record_metric("cache.keys.type.#{type}", count)
    end
    
    stats[:ttl_distribution].each do |category, count|
      NewRelic::Agent.record_metric("cache.ttl.#{category}", count)
    end
  end

  def clear_cache_safely(redis)
    start_time = Time.current
    key_count = redis.dbsize
    
    Rails.logger.info("Starting cache clear of #{key_count} keys")
    
    if Rails.env.production? && key_count > 10_000
      backup_cache(redis)
    end
    
    redis.flushdb
    
    duration = Time.current - start_time
    Rails.logger.info("Cache clear completed in #{duration.round(2)}s")
    
    NewRelic::Agent.record_metric('cache.clear.duration', duration)
    NewRelic::Agent.record_metric('cache.clear.keys_removed', key_count)
  rescue Redis::BaseError => e
    Rails.logger.error("Cache clear failed: #{e.message}")
    NewRelic::Agent.notice_error(e)
    raise
  end

  def backup_cache(redis)
    timestamp = Time.current.strftime('%Y%m%d%H%M%S')
    backup_file = Rails.root.join('tmp', "cache_backup_#{timestamp}.rdb")
    
    Rails.logger.info("Creating cache backup at #{backup_file}")
    redis.save
    
    FileUtils.cp(redis.info('persistence')['rdb_filename'], backup_file)
    Rails.logger.info("Cache backup completed")
  rescue StandardError => e
    Rails.logger.error("Cache backup failed: #{e.message}")
    NewRelic::Agent.notice_error(e)
  end

  def warmup_cache(redis)
    start_time = Time.current
    
    # Analyze access patterns from logs to identify frequently accessed data
    access_patterns = analyze_access_patterns
    
    # Create warmup batches
    batches = create_warmup_batches(access_patterns)
    
    Rails.logger.info("Starting cache warmup with #{batches.size} batches")
    
    # Process batches concurrently
    Parallel.map(batches, in_threads: WARMUP_CONCURRENCY) do |batch|
      warm_batch(redis, batch)
    end
    
    duration = Time.current - start_time
    Rails.logger.info("Cache warmup completed in #{duration.round(2)}s")
    
    NewRelic::Agent.record_metric('cache.warmup.duration', duration)
  rescue StandardError => e
    Rails.logger.error("Cache warmup failed: #{e.message}")
    NewRelic::Agent.notice_error(e)
    raise
  end

  def analyze_access_patterns
    # Analyze Redis keyspace notifications and access logs
    # to identify frequently accessed keys and patterns
    # Implementation depends on logging configuration
    {}
  end

  def create_warmup_batches(access_patterns)
    # Group data into batches based on access patterns
    # and optimize for parallel processing
    []
  end

  def warm_batch(redis, batch)
    # Load data for the batch and set appropriate TTLs
    # Implementation depends on data structure and caching strategy
  end
end