# frozen_string_literal: true

module Api
  module V1
    # Handles job-related API endpoints with comprehensive security, caching,
    # and monitoring features for production-grade job management operations.
    #
    # @version 1.0.0
    # @see Technical Specifications/1.3/Core Features/Job Management
    class JobsController < Api::V1::ApplicationController
      include NewRelic::Agent::Instrumentation::ControllerInstrumentation

      # Configure before actions
      before_action :require_authentication
      before_action :set_job, only: [:show, :update, :destroy, :update_status]
      before_action :validate_request_format, only: [:create, :update, :update_status]
      before_action :check_version_deprecation

      # Configure caching
      caches_action :index, :show,
                   cache_path: :cache_key_for_action,
                   expires_in: 1.hour,
                   unless: :request_uncacheable?

      # Lists jobs with pagination, filtering and caching
      #
      # @return [JSON] Paginated list of jobs
      def index
        @jobs = Job.includes(:location)
                   .where(filter_params)
                   .order(created_at: :desc)
                   .page(params[:page])
                   .per(params[:per_page] || 25)

        render json: @jobs,
               each_serializer: JobSerializer,
               meta: pagination_meta(@jobs),
               status: :ok
      end

      # Shows detailed job information with caching
      #
      # @return [JSON] Job details
      def show
        render json: @job,
               serializer: JobSerializer,
               include: ['location'],
               status: :ok
      end

      # Creates a new job with validation
      #
      # @return [JSON] Created job or errors
      def create
        @job = Job.new(job_params)

        if @job.save
          invalidate_cache
          render json: @job,
                 serializer: JobSerializer,
                 status: :created,
                 location: api_v1_job_url(@job)
        else
          render_validation_error(@job)
        end
      end

      # Updates existing job with validation
      #
      # @return [JSON] Updated job or errors
      def update
        if @job.update(job_params)
          invalidate_cache
          render json: @job,
                 serializer: JobSerializer,
                 status: :ok
        else
          render_validation_error(@job)
        end
      end

      # Soft deletes job with audit logging
      #
      # @return [JSON] Success status
      def destroy
        if @job.soft_delete(reason: params[:reason])
          invalidate_cache
          head :no_content
        else
          render_error('Failed to delete job', :unprocessable_entity)
        end
      end

      # Updates job status with validation
      #
      # @return [JSON] Updated status or errors
      def update_status
        service = StatusUpdateService.new(
          job: @job,
          new_status: params[:status],
          context: status_update_context
        )

        if service.call.success?
          invalidate_cache
          render json: @job,
                 serializer: JobSerializer,
                 status: :ok
        else
          render_error(service.errors.first[:message], :unprocessable_entity)
        end
      end

      private

      # Sets job instance with proper error handling
      def set_job
        @job = Job.find(params[:id])
      rescue ActiveRecord::RecordNotFound => e
        render_not_found("Job not found: #{e.message}")
      end

      # Generates cache key for actions
      def cache_key_for_action
        case action_name
        when 'index'
          "jobs/index/#{filter_params_cache_key}/page#{params[:page]}"
        when 'show'
          "jobs/#{@job.cache_key}"
        end
      end

      # Strong parameters for job creation/update
      def job_params
        params.require(:job).permit(
          :title,
          :description,
          :location_id,
          :start_date,
          :end_date,
          :status
        )
      end

      # Filter parameters for job listing
      def filter_params
        filters = {}
        filters[:location_id] = params[:location_id] if params[:location_id].present?
        filters[:status] = params[:status] if params[:status].present?
        filters[:active] = true
        filters
      end

      # Cache key for filter parameters
      def filter_params_cache_key
        Digest::SHA256.hexdigest(filter_params.to_json)
      end

      # Context for status updates
      def status_update_context
        {
          user_id: current_user.id,
          ip_address: request.remote_ip,
          reason: params[:reason],
          correlation_id: @correlation_id,
          source: 'api'
        }
      end

      # Invalidates related caches
      def invalidate_cache
        Rails.cache.delete_matched("jobs/*")
        REDIS_CACHE_POOL.with do |redis|
          redis.del("jobs:status:*")
          redis.del("jobs:location:#{@job.location_id}")
        end
      end

      # Pagination metadata
      def pagination_meta(jobs)
        {
          current_page: jobs.current_page,
          total_pages: jobs.total_pages,
          total_count: jobs.total_count,
          per_page: jobs.limit_value
        }
      end

      # Determines if request should bypass cache
      def request_uncacheable?
        request.headers['Cache-Control'] == 'no-cache'
      end

      # Renders validation error response
      def render_validation_error(record)
        render json: {
          error: 'validation_error',
          message: 'Validation failed',
          details: record.errors.full_messages
        }, status: :unprocessable_entity
      end

      # Add NewRelic transaction tracing
      add_transaction_tracer :index, category: :controller
      add_transaction_tracer :show, category: :controller
      add_transaction_tracer :create, category: :controller
      add_transaction_tracer :update, category: :controller
      add_transaction_tracer :destroy, category: :controller
      add_transaction_tracer :update_status, category: :controller
    end
  end
end