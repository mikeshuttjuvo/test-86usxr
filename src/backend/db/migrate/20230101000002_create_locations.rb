# frozen_string_literal: true

# Migration to create the locations table with comprehensive support for
# geocoding, soft deletion, audit logging, and optimized query performance
# @version 7.0.0
class CreateLocations < ActiveRecord::Migration[7.0]
  def change
    create_table :locations do |t|
      # Basic information
      t.string :name, null: false
      t.string :address, null: false

      # Geographical coordinates with high precision
      t.decimal :latitude, precision: 10, scale: 6
      t.decimal :longitude, precision: 10, scale: 6

      # Status tracking
      t.boolean :active, default: true, null: false
      t.timestamp :deleted_at

      # Audit timestamps
      t.timestamps
    end

    # Optimized indexes for various query patterns
    add_index :locations, :name, using: :btree
    add_index :locations, [:latitude, :longitude], using: :gist
    add_index :locations, :active, where: "active = true"
    add_index :locations, :deleted_at, where: "deleted_at IS NULL"
    add_index :locations, [:name, :active], where: "active = true AND deleted_at IS NULL"
    add_index :locations, :updated_at
  end
end