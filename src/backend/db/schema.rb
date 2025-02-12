# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.0].define(version: 2023_12_14_000000) do
  # Enable PostGIS and other PostgreSQL extensions
  enable_extension "plpgsql"
  enable_extension "postgis"

  create_table "users", force: :cascade do |t|
    t.string "email", null: false
    t.string "encrypted_password", null: false
    t.string "role", null: false, default: "user"
    t.string "first_name", null: false
    t.string "last_name", null: false
    t.string "jti", null: false
    t.boolean "active", null: false, default: true
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true, using: :btree
    t.index ["role"], name: "index_users_on_role", using: :btree
    t.index ["jti"], name: "index_users_on_jti", using: :btree
    t.index ["active"], name: "index_users_on_active", using: :btree
    t.index ["deleted_at"], name: "index_users_on_deleted_at", using: :btree
  end

  create_table "locations", force: :cascade do |t|
    t.string "name", null: false
    t.string "address", null: false
    t.decimal "latitude", precision: 10, scale: 6
    t.decimal "longitude", precision: 10, scale: 6
    t.boolean "active", null: false, default: true
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_locations_on_name", using: :btree
    t.index ["latitude", "longitude"], name: "index_locations_on_latitude_longitude", using: :gist
    t.index ["active"], name: "index_locations_on_active", using: :btree
    t.index ["deleted_at"], name: "index_locations_on_deleted_at", using: :btree
  end

  create_table "jobs", force: :cascade do |t|
    t.bigint "location_id", null: false
    t.string "title", null: false
    t.text "description", null: false
    t.string "status", null: false, default: "pending"
    t.datetime "start_date", null: false
    t.datetime "end_date", null: false
    t.boolean "active", null: false, default: true
    t.datetime "deleted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["location_id"], name: "index_jobs_on_location_id", using: :btree
    t.index ["status"], name: "index_jobs_on_status", using: :btree
    t.index ["start_date", "end_date"], name: "index_jobs_on_start_date_end_date", using: :btree
    t.index ["active"], name: "index_jobs_on_active", using: :btree
    t.index ["deleted_at"], name: "index_jobs_on_deleted_at", using: :btree
    t.foreign_key "locations", on_delete: :restrict
  end

  create_table "audit_logs", force: :cascade do |t|
    t.string "action", null: false
    t.string "resource_type", null: false
    t.bigint "resource_id", null: false
    t.jsonb "changes", default: {}
    t.bigint "user_id"
    t.string "ip_address"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["action"], name: "index_audit_logs_on_action", using: :btree
    t.index ["resource_type", "resource_id"], name: "index_audit_logs_on_resource_type_and_resource_id", using: :btree
    t.index ["action", "created_at"], name: "index_audit_logs_on_action_and_created_at", using: :btree
    t.index ["user_id"], name: "index_audit_logs_on_user_id", using: :btree
    t.foreign_key "users", on_delete: :nullify
  end
end