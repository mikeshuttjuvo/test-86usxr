# frozen_string_literal: true

class AddIndexesToJobs < ActiveRecord::Migration[7.0]
  def change
    # Add composite index for efficient location-based job filtering with status
    # This supports queries that filter jobs by location and status together
    add_index :jobs, [:location_id, :status], 
      name: 'index_jobs_on_location_id_and_status',
      comment: 'Optimizes location-based job filtering with status'

    # Add composite index for date range queries with status
    # This supports queries that search jobs within date ranges and status
    add_index :jobs, [:status, :start_date, :end_date],
      name: 'index_jobs_on_status_and_dates',
      comment: 'Optimizes date range queries with status filtering'

    # Add single-column index for job search by title
    # This supports fast job lookup and search functionality
    add_index :jobs, :title,
      name: 'index_jobs_on_title',
      comment: 'Optimizes job search by title'

    # Add single-column index for active job filtering
    # This supports quick filtering of active/inactive jobs
    add_index :jobs, :active,
      name: 'index_jobs_on_active',
      comment: 'Optimizes active job filtering'

    # Add composite index for soft deletion queries
    # This supports efficient filtering of active records considering soft deletion
    add_index :jobs, [:active, :deleted_at],
      name: 'index_jobs_on_active_and_deleted_at',
      comment: 'Optimizes soft deletion queries'
  end
end