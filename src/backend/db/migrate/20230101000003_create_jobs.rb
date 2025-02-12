# frozen_string_literal: true

class CreateJobs < ActiveRecord::Migration[7.0]
  def change
    create_table :jobs do |t|
      # Foreign key reference to locations table
      t.references :location, null: false, foreign_key: { on_delete: :restrict }

      # Core job attributes
      t.string :title, null: false
      t.text :description, null: false
      t.string :status, null: false, default: 'pending'
      t.datetime :start_date, null: false
      t.datetime :end_date, null: false
      t.boolean :active, null: false, default: true

      # Timestamps for record tracking
      t.timestamps null: false
      
      # Soft deletion support
      t.datetime :deleted_at, null: true
    end

    # Performance optimization indexes based on common query patterns
    add_index :jobs, :status, using: :btree
    add_index :jobs, [:start_date, :end_date], using: :btree
    add_index :jobs, :deleted_at, using: :btree
    add_index :jobs, [:location_id, :status], using: :btree
    add_index :jobs, [:location_id, :active], using: :btree
    add_index :jobs, [:active, :deleted_at], using: :btree

    # Add database-level check constraints
    reversible do |dir|
      dir.up do
        # Ensure end_date is after start_date
        execute <<-SQL
          ALTER TABLE jobs
          ADD CONSTRAINT check_job_dates
          CHECK (end_date > start_date)
        SQL

        # Ensure status is a valid value
        execute <<-SQL
          ALTER TABLE jobs
          ADD CONSTRAINT check_job_status
          CHECK (status IN ('pending', 'in_progress', 'completed', 'cancelled'))
        SQL
      end
    end
  end
end