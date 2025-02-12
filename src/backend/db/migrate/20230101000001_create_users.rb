# frozen_string_literal: true

class CreateUsers < ActiveRecord::Migration[7.0]
  def change
    create_table :users do |t|
      # Authentication fields
      t.string :email, null: false, comment: "User's email address for authentication"
      t.string :encrypted_password, null: false, comment: 'Bcrypt encrypted password hash'
      t.string :jti, null: false, comment: 'JWT token identifier for tracking valid tokens'

      # Authorization fields
      t.string :role, null: false, default: 'user', 
        comment: 'User role for authorization (admin, manager, user)'

      # Personal information fields (PII)
      t.string :first_name, null: false, comment: "User's first name"
      t.string :last_name, null: false, comment: "User's last name"

      # Account status fields
      t.boolean :active, null: false, default: true, comment: 'Account status flag'
      t.datetime :deleted_at, comment: 'Soft deletion timestamp'

      # Audit trail timestamps
      t.timestamps null: false
    end

    # Primary authentication index
    add_index :users, :email, unique: true, 
      name: 'index_users_on_email'

    # JWT token tracking index
    add_index :users, :jti, 
      name: 'index_users_on_jti'

    # Authorization and status indexes
    add_index :users, :role, 
      name: 'index_users_on_role'
    add_index :users, :active, 
      name: 'index_users_on_active'

    # Composite index for common authorization queries
    add_index :users, [:role, :active], 
      name: 'index_users_on_role_and_active'

    # Soft deletion index
    add_index :users, :deleted_at, 
      name: 'index_users_on_deleted_at'

    # Audit trail index
    add_index :users, :created_at, 
      name: 'index_users_on_created_at'
  end
end