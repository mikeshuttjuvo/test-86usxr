# frozen_string_literal: true

# Migration to add optimized indexes to locations table for improved query performance
# Includes B-tree indexes for name and status filtering and GiST index for geospatial queries
# @version Rails 7.0.0
class AddIndexesToLocations < ActiveRecord::Migration[7.0]
  # Disable transactions to allow concurrent index creation
  disable_ddl_transaction!

  def change
    # Add B-tree index on name column for fast name-based lookups
    # Using concurrent creation for zero-downtime deployment
    add_index :locations, :name,
              name: 'index_locations_on_name',
              algorithm: :concurrently,
              if_not_exists: true,
              comment: 'Optimizes name-based location lookups'

    # Add GiST index for efficient geospatial queries on latitude/longitude
    add_index :locations, [:latitude, :longitude],
              name: 'index_locations_on_coordinates',
              using: :gist,
              algorithm: :concurrently,
              comment: 'Enables efficient geospatial queries using PostGIS'

    # Add composite B-tree index for filtered queries combining name and active status
    add_index :locations, [:name, :active],
              name: 'index_locations_on_name_and_active',
              algorithm: :concurrently,
              comment: 'Optimizes filtered queries by name and active status'

    # Add B-tree index on active column for status-based filtering
    add_index :locations, :active,
              name: 'index_locations_on_active',
              algorithm: :concurrently,
              if_not_exists: true,
              comment: 'Supports efficient filtering of active/inactive locations'
  end
end