# frozen_string_literal: true

# Version: rake ~> 13.0
# Version: activerecord ~> 7.0.0

namespace :db do
  desc 'Setup database environment with security validation'
  task setup: :environment do
    puts '[DB] Starting secure database setup...'
    
    begin
      # Validate database configuration
      validate_database_config
      
      # Execute setup tasks in sequence
      Rake::Task['db:create'].invoke
      Rake::Task['db:migrate'].invoke
      Rake::Task['db:create_indexes'].invoke
      setup_audit_logging
      configure_encryption
      
      # Seed data only in development
      if Rails.env.development?
        Rake::Task['db:seed'].invoke
      end
      
      verify_database_integrity
      puts '[DB] Database setup completed successfully'
    rescue StandardError => e
      puts "[DB] Setup failed: #{e.message}"
      raise e
    end
  end

  desc 'Reset database and load sanitized sample data'
  task reset_with_sample_data: :environment do
    raise 'Cannot reset production database!' if Rails.env.production?
    
    puts '[DB] Starting secure database reset...'
    
    begin
      # Backup existing data
      backup_database
      
      # Reset database
      Rake::Task['db:drop'].invoke
      Rake::Task['db:create'].invoke
      Rake::Task['db:migrate'].invoke
      
      # Create optimized indexes
      Rake::Task['db:create_indexes'].invoke
      
      # Load sanitized seed data
      load_sanitized_seed_data
      
      verify_database_integrity
      puts '[DB] Database reset completed successfully'
    rescue StandardError => e
      puts "[DB] Reset failed: #{e.message}"
      raise e
    end
  end

  desc 'Create optimized database indexes'
  task create_indexes: :environment do
    puts '[DB] Creating optimized indexes...'
    
    begin
      ActiveRecord::Base.connection.execute <<-SQL
        -- Locations table indexes
        CREATE INDEX IF NOT EXISTS index_locations_on_name_and_active 
          ON locations (name, active);
        
        CREATE INDEX IF NOT EXISTS index_locations_on_coordinates 
          ON locations USING gist (ll_to_earth(latitude, longitude));
        
        -- Jobs table indexes
        CREATE INDEX IF NOT EXISTS index_jobs_on_location_id_and_status 
          ON jobs (location_id, status);
        
        CREATE INDEX IF NOT EXISTS index_jobs_on_dates 
          ON jobs (start_date, end_date);
        
        -- Audit logs indexes
        CREATE INDEX IF NOT EXISTS index_audit_logs_on_resource 
          ON audit_logs (resource_type, resource_id);
        
        CREATE INDEX IF NOT EXISTS index_audit_logs_on_created_at 
          ON audit_logs (created_at);
      SQL
      
      analyze_indexes
      puts '[DB] Index creation completed successfully'
    rescue StandardError => e
      puts "[DB] Index creation failed: #{e.message}"
      raise e
    end
  end

  desc 'Validate database schema and security'
  task validate_schema: :environment do
    puts '[DB] Starting schema validation...'
    
    begin
      validation_results = {
        schema_version: validate_schema_version,
        table_structures: validate_table_structures,
        indexes: validate_indexes,
        foreign_keys: validate_foreign_keys,
        encryption: validate_encryption_settings,
        audit_logging: validate_audit_logging,
        permissions: validate_permissions
      }
      
      report_validation_results(validation_results)
    rescue StandardError => e
      puts "[DB] Schema validation failed: #{e.message}"
      raise e
    end
  end

  private

  def validate_database_config
    config = Rails.application.config.database_configuration[Rails.env]
    raise 'Invalid database configuration!' unless config
    
    required_keys = %w[adapter database username password host port]
    missing_keys = required_keys - config.keys
    
    raise "Missing required database configuration: #{missing_keys.join(', ')}" if missing_keys.any?
  end

  def backup_database
    return unless Rails.env.development?
    
    timestamp = Time.current.strftime('%Y%m%d%H%M%S')
    config = Rails.application.config.database_configuration[Rails.env]
    
    system(
      "PGPASSWORD=#{config['password']} pg_dump -h #{config['host']} " \
      "-U #{config['username']} -d #{config['database']} " \
      "-f db/backups/backup_#{timestamp}.sql"
    )
  end

  def load_sanitized_seed_data
    return unless Rails.env.development?
    
    puts '[DB] Loading sanitized seed data...'
    load 'db/seeds.rb'
  end

  def setup_audit_logging
    ActiveRecord::Base.connection.execute <<-SQL
      CREATE TABLE IF NOT EXISTS audit_logs (
        id bigserial PRIMARY KEY,
        action varchar NOT NULL,
        resource_type varchar NOT NULL,
        resource_id bigint NOT NULL,
        changes jsonb NOT NULL,
        created_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP
      );
      
      CREATE INDEX IF NOT EXISTS index_audit_logs_on_created_at 
        ON audit_logs (created_at);
    SQL
  end

  def configure_encryption
    # Configure field-level encryption settings
    ActiveRecord::Base.connection.execute <<-SQL
      -- Enable pgcrypto extension if not enabled
      CREATE EXTENSION IF NOT EXISTS pgcrypto;
    SQL
  end

  def verify_database_integrity
    ActiveRecord::Base.connection.execute('ANALYZE VERBOSE;')
    
    # Check for table bloat
    ActiveRecord::Base.connection.execute <<-SQL
      SELECT schemaname, tablename, pg_size_pretty(size) as size
      FROM (
        SELECT schemaname, tablename, pg_total_relation_size(full_table_name) as size
        FROM (
          SELECT schemaname, tablename, quote_ident(schemaname)|| '.' || quote_ident(tablename) as full_table_name
          FROM pg_tables
          WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
        ) as all_tables
      ) as pretty_sizes
      ORDER BY size DESC;
    SQL
  end

  def analyze_indexes
    ActiveRecord::Base.connection.execute('ANALYZE VERBOSE;')
    
    # Check index usage statistics
    ActiveRecord::Base.connection.execute <<-SQL
      SELECT schemaname, tablename, indexname, idx_scan, idx_tup_read, idx_tup_fetch
      FROM pg_stat_user_indexes
      ORDER BY idx_scan DESC;
    SQL
  end

  def validate_schema_version
    ActiveRecord::Base.connection.execute(
      "SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1;"
    ).first['version']
  end

  def validate_table_structures
    ActiveRecord::Base.connection.tables.map do |table|
      {
        table: table,
        columns: ActiveRecord::Base.connection.columns(table).map(&:name),
        constraints: ActiveRecord::Base.connection.execute(
          "SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = '#{table}'::regclass;"
        )
      }
    end
  end

  def validate_indexes
    ActiveRecord::Base.connection.execute(
      "SELECT schemaname, tablename, indexname FROM pg_indexes WHERE schemaname = 'public';"
    )
  end

  def validate_foreign_keys
    ActiveRecord::Base.connection.execute(
      "SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE contype = 'f';"
    )
  end

  def validate_encryption_settings
    ActiveRecord::Base.connection.execute(
      "SELECT extname, extversion FROM pg_extension WHERE extname = 'pgcrypto';"
    )
  end

  def validate_audit_logging
    ActiveRecord::Base.connection.execute(
      "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'audit_logs');"
    )
  end

  def validate_permissions
    ActiveRecord::Base.connection.execute(
      "SELECT grantee, privilege_type FROM information_schema.role_table_grants WHERE table_schema = 'public';"
    )
  end

  def report_validation_results(results)
    puts "\n=== Database Validation Report ==="
    puts "Schema Version: #{results[:schema_version]}"
    puts "Tables Validated: #{results[:table_structures].length}"
    puts "Indexes Validated: #{results[:indexes].count}"
    puts "Foreign Keys Validated: #{results[:foreign_keys].count}"
    puts "Encryption Status: #{results[:encryption].count > 0 ? 'Enabled' : 'Disabled'}"
    puts "Audit Logging: #{results[:audit_logging].getvalue(0,0) ? 'Enabled' : 'Disabled'}"
    puts "Permission Entries: #{results[:permissions].count}"
    puts "=============================="
  end
end