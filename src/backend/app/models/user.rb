# frozen_string_literal: true

# User model implementing secure authentication, role-based access control,
# audit logging, caching, and data retention with comprehensive security measures.
#
# @version 1.0.0
# @see Technical Specifications/7.1/Authentication and Authorization
class User < ApplicationRecord
  # Include core modules
  include Devise::JWT::RevocationStrategies::JTIMatcher
  include Auditable
  include Cacheable
  include SoftDeletable

  # Devise modules with secure configuration
  devise :database_authenticatable, :jwt_authenticatable,
         :recoverable, :trackable, :lockable,
         :timeoutable, timeout_in: 30.minutes,
         maximum_attempts: MAX_LOGIN_ATTEMPTS,
         unlock_in: LOGIN_LOCKOUT_DURATION

  # Constants
  ROLES = %w[admin manager user].freeze
  TOKEN_LIFETIME = 24.hours
  CACHE_TTL = 1.hour
  MAX_LOGIN_ATTEMPTS = 5
  LOGIN_LOCKOUT_DURATION = 30.minutes
  SOFT_DELETE_RETENTION = 90.days

  # Attributes
  attribute :email, :string
  attribute :encrypted_password, :string
  attribute :role, :string
  attribute :first_name, :string
  attribute :last_name, :string
  attribute :jti, :string
  attribute :active, :boolean, default: true
  attribute :failed_attempts, :integer, default: 0
  attribute :locked_at, :datetime
  attribute :created_at, :datetime
  attribute :updated_at, :datetime
  attribute :deleted_at, :datetime

  # Validations
  validates :email, presence: true, 
                   uniqueness: { case_sensitive: false },
                   format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :role, presence: true, inclusion: { in: ROLES }
  validates :first_name, :last_name, presence: true,
                                   length: { maximum: 50 }
  validates :password, presence: true,
                      length: { minimum: 12 },
                      format: { with: /\A(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[@$!%*?&])[A-Za-z\d@$!%*?&]+\z/ },
                      if: :password_required?

  # Callbacks
  before_save :ensure_jti
  after_commit :invalidate_auth_cache, on: [:update, :destroy]

  # Scopes
  scope :active_users, -> { where(active: true) }
  scope :by_role, ->(role) { where(role: role) if role.present? }

  # Configure caching
  caches_with ttl: CACHE_TTL

  # Role-based authorization methods
  ROLES.each do |role_name|
    define_method "#{role_name}?" do
      cache_fetch("#{cache_key}:role:#{role_name}", ttl: CACHE_TTL) do
        role == role_name
      end
    end
  end

  # JWT token generation with secure claims
  def generate_jwt
    JWT.encode(
      {
        user_id: id,
        role: role,
        jti: jti,
        iat: Time.current.to_i,
        exp: TOKEN_LIFETIME.from_now.to_i,
        iss: Rails.application.config.jwt_issuer
      },
      Rails.application.credentials.jwt_secret_key,
      'HS256'
    )
  end

  # Cached full name retrieval
  def full_name
    cache_fetch("#{cache_key}:full_name", ttl: CACHE_TTL) do
      "#{first_name} #{last_name}".strip
    end
  end

  # Secure password validation with rate limiting
  def valid_password?(password)
    result = super
    if result
      self.failed_attempts = 0
      save(validate: false)
    else
      increment_failed_attempts
    end
    result
  end

  # Track failed login attempts with rate limiting
  def increment_failed_attempts
    self.class.transaction_with_retry do
      increment!(:failed_attempts)
      
      if failed_attempts >= MAX_LOGIN_ATTEMPTS
        lock_access!
        create_audit_entry('account_locked', 'Maximum login attempts exceeded')
        return true
      end
    end
    false
  end

  private

  def ensure_jti
    self.jti ||= SecureRandom.uuid
  end

  def password_required?
    new_record? || password.present?
  end

  def invalidate_auth_cache
    Rails.cache.delete_matched("#{cache_key}:*")
    REDIS_AUTH_POOL.with do |redis|
      redis.del("user:#{id}:sessions")
    end
  end

  def create_audit_entry(action, reason)
    AuditLogJob.perform_later(
      action: action,
      resource_type: self.class.name,
      resource_id: id,
      changes: changes,
      user_id: id,
      reason: reason
    )
  end
end