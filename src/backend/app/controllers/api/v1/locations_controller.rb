# frozen_string_literal: true

module Api
  module V1
    # Handles location resource endpoints with caching, rate limiting, and RFC 7807 error handling
    # @version 1.0.0
    # @see Technical Specifications/3.1.2/Interface Specifications
    class LocationsController < Api::V1::ApplicationController
      include RateLimitable
      include ApiErrorHandler

      # Configure before actions
      before_action :set_location, only: [:show, :update, :destroy]
      before_action :validate_coordinates, only: [:nearby]

      # Default cache TTL of 1 hour
      CACHE_TTL = 1.hour
      # Default pagination size
      PER_PAGE = 25
      # Maximum radius for nearby search in kilometers
      MAX_RADIUS = 100

      # GET /api/v1/locations
      # Lists locations with filtering, pagination and caching
      def index
        locations = Location.where(filter_params)
                          .paginate(page: params[:page], per_page: PER_PAGE)

        cache_key = "locations/index/#{filter_params_cache_key}/#{params[:page]}"

        @locations = Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
          LocationSerializer.new(locations, include_timestamps: true).serializable_hash
        end

        render json: @locations, status: :ok
      rescue StandardError => e
        handle_error(e)
      end

      # GET /api/v1/locations/:id
      # Retrieves a specific location with caching
      def show
        cache_key = "locations/#{@location.id}/#{@location.cache_key}"

        @serialized_location = Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
          LocationSerializer.new(@location, include: [:jobs]).serializable_hash
        end

        render json: @serialized_location, status: :ok
      rescue StandardError => e
        handle_error(e)
      end

      # POST /api/v1/locations
      # Creates a new location with geocoding
      def create
        @location = Location.new(location_params)

        if @location.save
          invalidate_cache
          render json: LocationSerializer.new(@location).serializable_hash,
                 status: :created,
                 location: api_v1_location_url(@location)
        else
          render_validation_error(@location.errors)
        end
      rescue StandardError => e
        handle_error(e)
      end

      # PUT /api/v1/locations/:id
      # Updates location with cache invalidation
      def update
        if @location.update(location_params)
          invalidate_cache
          render json: LocationSerializer.new(@location).serializable_hash, status: :ok
        else
          render_validation_error(@location.errors)
        end
      rescue StandardError => e
        handle_error(e)
      end

      # DELETE /api/v1/locations/:id
      # Soft deletes location with cache cleanup
      def destroy
        if @location.soft_delete
          invalidate_cache
          head :no_content
        else
          render_error('Failed to delete location', :unprocessable_entity)
        end
      rescue StandardError => e
        handle_error(e)
      end

      # GET /api/v1/locations/nearby
      # Finds locations within radius with caching
      def nearby
        cache_key = "locations/nearby/#{nearby_cache_key}"

        @nearby_locations = Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
          locations = Location.nearby(
            latitude: params[:latitude],
            longitude: params[:longitude],
            radius_km: [params[:radius].to_f, MAX_RADIUS].min,
            options: nearby_options
          )
          LocationSerializer.new(locations).serializable_hash
        end

        render json: @nearby_locations, status: :ok
      rescue StandardError => e
        handle_error(e)
      end

      private

      def set_location
        @location = Location.find(params[:id])
      rescue ActiveRecord::RecordNotFound => e
        render_not_found_error('Location not found')
      end

      def location_params
        params.require(:location).permit(
          :name,
          :address,
          :latitude,
          :longitude,
          :active
        )
      end

      def filter_params
        params.permit(
          :name,
          :active,
          :created_at_from,
          :created_at_to
        ).to_h
      end

      def filter_params_cache_key
        Digest::SHA256.hexdigest(filter_params.to_json)
      end

      def nearby_options
        {
          limit: params[:limit] || PER_PAGE,
          order: params[:order] || 'distance ASC'
        }
      end

      def nearby_cache_key
        components = [
          params[:latitude].to_f.round(6),
          params[:longitude].to_f.round(6),
          params[:radius].to_f.round(2),
          nearby_options.to_s
        ]
        Digest::SHA256.hexdigest(components.join(':'))
      end

      def validate_coordinates
        unless valid_coordinates?(params[:latitude], params[:longitude])
          render_error('Invalid coordinates', :unprocessable_entity)
        end
      end

      def valid_coordinates?(lat, lng)
        lat.present? && lng.present? &&
          lat.to_f.between?(-90, 90) &&
          lng.to_f.between?(-180, 180)
      end

      def invalidate_cache
        Rails.cache.delete_matched("locations/*")
      end

      def render_validation_error(errors)
        render json: {
          error: 'validation_error',
          message: 'Validation failed',
          details: errors
        }, status: :unprocessable_entity
      end

      def render_not_found_error(message)
        render json: {
          error: 'not_found',
          message: message
        }, status: :not_found
      end

      def render_error(message, status)
        render json: {
          error: status.to_s,
          message: message
        }, status: status
      end
    end
  end
end