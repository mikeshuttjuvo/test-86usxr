# frozen_string_literal: true

# Migration to create the audit_logs table for comprehensive security monitoring and compliance
# Version: ~> 7.0.0
class CreateAuditLogs < ActiveRecord::Migration[7.0]
  def change
    create_table :audit_logs do |t|
      # Action performed (e.g., create, update, delete)
      t.string :action, null: false, index: true
      
      # Resource information
      t.string :resource_type, null: false
      t.bigint :resource_id, null: false
      
      # Detailed change tracking using JSONB for flexibility
      t.jsonb :changes, default: {}, null: false
      
      # User attribution
      t.bigint :user_id
      
      # Request metadata
      t.string :ip_address
      
      # Timestamps (updated_at included for ActiveRecord compatibility)
      t.timestamps null: false
      
      # Add foreign key constraint
      t.foreign_key :users, column: :user_id, on_delete: :nullify
      
      # Add composite indexes for efficient querying
      t.index [:resource_type, :resource_id], name: 'index_audit_logs_on_resource'
      t.index [:action, :created_at], name: 'index_audit_logs_on_action_and_created_at'
      t.index :created_at
      t.index :user_id
    end
    
    # Ensure changes column is indexed for JSONB queries
    add_index :audit_logs, :changes, using: :gin
  end
  
  def up
    # Implement the forward migration
    create_table :audit_logs do |t|
      t.string :action, null: false, index: true
      t.string :resource_type, null: false
      t.bigint :resource_id, null: false
      t.jsonb :changes, default: {}, null: false
      t.bigint :user_id
      t.string :ip_address
      t.timestamps null: false
    end
    
    # Add foreign key constraint
    add_foreign_key :audit_logs, :users, column: :user_id, on_delete: :nullify
    
    # Add composite indexes
    add_index :audit_logs, [:resource_type, :resource_id], name: 'index_audit_logs_on_resource'
    add_index :audit_logs, [:action, :created_at], name: 'index_audit_logs_on_action_and_created_at'
    add_index :audit_logs, :created_at
    add_index :audit_logs, :user_id
    add_index :audit_logs, :changes, using: :gin
  end
  
  def down
    # Remove foreign key constraint
    remove_foreign_key :audit_logs, :users
    
    # Remove indexes
    remove_index :audit_logs, name: 'index_audit_logs_on_resource'
    remove_index :audit_logs, name: 'index_audit_logs_on_action_and_created_at'
    remove_index :audit_logs, :created_at
    remove_index :audit_logs, :user_id
    remove_index :audit_logs, :changes
    remove_index :audit_logs, :action
    
    # Drop the table
    drop_table :audit_logs
  end
end