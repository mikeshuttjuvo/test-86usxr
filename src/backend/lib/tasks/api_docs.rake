# frozen_string_literal: true

require 'yaml'
require 'json-schema'
require 'openapi_validator'

namespace :api do
  namespace :docs do
    desc 'Generate comprehensive OpenAPI documentation'
    task generate: :environment do |_t, args|
      force_refresh = args.extras.include?('--force')
      generator = ApiDocsGenerator.new(force_refresh)
      generator.generate
    end

    desc 'Validate OpenAPI documentation'
    task validate: :environment do
      validator = ApiDocsValidator.new
      exit 1 unless validator.validate
    end

    class ApiDocsGenerator
      API_VERSION = 'v1'
      DOCS_PATH = Rails.root.join('openapi', API_VERSION, 'api_docs.yml')
      CACHE_TTL = 3600 # 1 hour

      def initialize(force_refresh = false)
        @force_refresh = force_refresh
        @base_docs = load_base_docs
        @controllers_path = Rails.root.join('app', 'controllers', 'api', API_VERSION)
        @models_path = Rails.root.join('app', 'models')
      end

      def generate
        return if documentation_fresh? && !@force_refresh

        begin
          merge_controller_docs
          merge_model_schemas
          add_security_schemes
          add_error_responses
          add_rate_limiting
          
          validate_and_save
          update_cache
          
          log_generation_success
        rescue StandardError => e
          log_generation_error(e)
          raise
        end
      end

      private

      def load_base_docs
        YAML.safe_load(File.read(DOCS_PATH), aliases: true)
      end

      def documentation_fresh?
        return false if @force_refresh
        
        REDIS_CACHE_POOL.with do |redis|
          cached = redis.get(cache_key)
          return false unless cached
          
          last_generated = Time.parse(cached)
          Time.current - last_generated < CACHE_TTL
        end
      end

      def merge_controller_docs
        Dir.glob("#{@controllers_path}/*_controller.rb").each do |file|
          controller_name = File.basename(file, '.rb')
          next if controller_name == 'application_controller'

          docs = extract_controller_docs(file)
          merge_path_docs(docs)
        end
      end

      def extract_controller_docs(file)
        controller = File.read(file)
        paths = {}
        
        # Extract route definitions
        controller.scan(/^\s*#\s*@route.*$/).each do |route_comment|
          route_info = parse_route_comment(route_comment)
          paths[route_info[:path]] ||= {}
          paths[route_info[:path]][route_info[:method]] = route_info[:spec]
        end

        paths
      end

      def merge_model_schemas
        Dir.glob("#{@models_path}/*.rb").each do |file|
          next if File.basename(file) == 'application_record.rb'
          
          model_name = File.basename(file, '.rb').classify
          schema = extract_model_schema(file, model_name)
          
          @base_docs['components']['schemas'][model_name] = schema
        end
      end

      def add_security_schemes
        @base_docs['components']['securitySchemes'] = {
          'bearerAuth' => {
            'type' => 'http',
            'scheme' => 'bearer',
            'bearerFormat' => 'JWT'
          }
        }

        @base_docs['security'] = [{ 'bearerAuth' => [] }]
      end

      def add_error_responses
        standard_errors = {
          'UnauthorizedError' => {
            'description' => 'Authentication failed or token invalid',
            'content' => {
              'application/json' => {
                'schema' => { '$ref' => '#/components/schemas/Error' }
              }
            }
          },
          'ValidationError' => {
            'description' => 'Invalid request parameters',
            'content' => {
              'application/json' => {
                'schema' => { '$ref' => '#/components/schemas/Error' }
              }
            }
          }
        }

        @base_docs['components']['responses'].merge!(standard_errors)
      end

      def add_rate_limiting
        @base_docs['components']['parameters']['RateLimit'] = {
          'in' => 'header',
          'name' => 'X-RateLimit-Limit',
          'schema' => { 'type' => 'integer' },
          'required' => false,
          'description' => 'Rate limit quota per hour'
        }

        @base_docs['components']['headers']['X-RateLimit-Remaining'] = {
          'schema' => { 'type' => 'integer' },
          'description' => 'Remaining requests in the current time window'
        }
      end

      def validate_and_save
        validator = OpenAPIValidator.new(@base_docs)
        raise 'Invalid OpenAPI specification' unless validator.valid?

        File.write(DOCS_PATH, @base_docs.to_yaml)
      end

      def update_cache
        REDIS_CACHE_POOL.with do |redis|
          redis.setex(cache_key, CACHE_TTL, Time.current.iso8601)
        end
      end

      def cache_key
        "api_docs:#{API_VERSION}:last_generated"
      end

      def log_generation_success
        Rails.logger.info(
          "API documentation generated successfully: #{DOCS_PATH}"
        )
      end

      def log_generation_error(error)
        Rails.logger.error(
          "Failed to generate API documentation: #{error.message}"
        )
      end
    end

    class ApiDocsValidator
      def validate
        docs = YAML.safe_load(File.read(ApiDocsGenerator::DOCS_PATH))
        
        validate_schema(docs) &&
          validate_security(docs) &&
          validate_endpoints(docs) &&
          validate_models(docs)
      end

      private

      def validate_schema(docs)
        schema = JSON::Schema.new(docs, validate_schema: true)
        schema.validate
        true
      rescue JSON::Schema::ValidationError => e
        puts "Schema validation failed: #{e.message}"
        false
      end

      def validate_security(docs)
        security_schemes = docs.dig('components', 'securitySchemes')
        return validation_error('Missing security schemes') unless security_schemes
        return validation_error('Missing JWT authentication') unless security_schemes['bearerAuth']
        true
      end

      def validate_endpoints(docs)
        paths = docs['paths']
        return validation_error('No endpoints documented') if paths.empty?

        paths.each do |path, operations|
          operations.each do |method, spec|
            return false unless validate_endpoint(path, method, spec)
          end
        end
        true
      end

      def validate_models(docs)
        schemas = docs.dig('components', 'schemas')
        return validation_error('Missing schema definitions') unless schemas
        
        schemas.each do |name, schema|
          return false unless validate_model_schema(name, schema)
        end
        true
      end

      def validate_endpoint(path, method, spec)
        return validation_error("Missing operation ID for #{method.upcase} #{path}") unless spec['operationId']
        return validation_error("Missing responses for #{method.upcase} #{path}") unless spec['responses']
        true
      end

      def validate_model_schema(name, schema)
        return validation_error("Invalid schema for #{name}") unless schema['type']
        return validation_error("Missing properties for #{name}") if schema['type'] == 'object' && !schema['properties']
        true
      end

      def validation_error(message)
        puts "Validation Error: #{message}"
        false
      end
    end
  end
end