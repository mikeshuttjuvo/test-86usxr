# frozen_string_literal: true

# Devise configuration initializer for secure authentication
# Version: 4.9.0
# Dependencies:
# - devise ~> 4.9.0
# - devise-jwt ~> 0.10.0
# - bcrypt ~> 3.1.7

Devise.setup do |config|
  # ==> Security Configuration
  # Configure security-related parameters for authentication
  
  # Secret key for JWT token generation and verification
  config.jwt do |jwt|
    jwt.secret = ENV.fetch('JWT_SECRET') { Rails.application.credentials.jwt_secret }
    jwt.dispatch_requests = [
      ['POST', %r{^/api/v1/auth/login$}],
      ['POST', %r{^/login$}]
    ]
    jwt.revocation_requests = [
      ['DELETE', %r{^/api/v1/auth/logout$}],
      ['DELETE', %r{^/logout$}]
    ]
    jwt.expiration_time = 24.hours.to_i
    jwt.algorithm = 'HS256'
  end

  # ==> Mailer Configuration
  # Configure mailer behavior for authentication-related emails
  config.mailer_sender = 'noreply@example.com'
  config.mailer = 'Devise::Mailer'
  config.parent_mailer = 'ActionMailer::Base'

  # ==> ORM Configuration
  # Load and configure the ORM (Active Record)
  require 'devise/orm/active_record'

  # ==> Authentication Configuration
  # Configure authentication keys and methods
  config.authentication_keys = [:email]
  config.case_insensitive_keys = [:email]
  config.strip_whitespace_keys = [:email]
  config.params_authenticatable = true
  config.http_authenticatable = true
  config.http_authenticatable_on_xhr = true
  config.http_authentication_realm = 'Application'

  # ==> Password Configuration
  # Configure secure password requirements
  config.password_length = 12..128
  config.password_regex = /\A(?=.*[a-z])(?=.*[A-Z])(?=.*\d)(?=.*[@$!%*?&])[A-Za-z\d@$!%*?&]+\z/
  config.reconfirmable = true
  config.reset_password_within = 6.hours
  config.sign_out_via = :delete
  config.scoped_views = false
  config.sign_out_all_scopes = true

  # ==> Security Features
  # Configure additional security features
  config.stretches = 12
  config.pepper = ENV.fetch('DEVISE_PEPPER') { Rails.application.credentials.devise_pepper }
  config.send_email_changed_notification = true
  config.send_password_change_notification = true

  # ==> Session Configuration
  # Configure session security settings
  config.skip_session_storage = [:http_auth, :params_auth]
  config.clean_up_csrf_token_on_authentication = true
  config.reload_routes = true
  config.paranoid = true

  # ==> Timeout Configuration
  # Configure timeout and remember me settings
  config.timeout_in = 30.minutes
  config.remember_for = 2.weeks
  config.expire_all_remember_me_on_sign_out = true
  config.extend_remember_period = false
  config.rememberable_options = { secure: true }

  # ==> Lockout Configuration
  # Configure account lockout settings
  config.lock_strategy = :failed_attempts
  config.unlock_keys = [:email]
  config.unlock_strategy = :time
  config.maximum_attempts = 5
  config.unlock_in = 30.minutes
  config.last_attempt_warning = true

  # ==> Rate Limiting
  # Configure rate limiting through Rack::Attack
  Rack::Attack.cache.store = Redis::Store.new(
    host: ENV.fetch('REDIS_HOST') { 'localhost' },
    port: ENV.fetch('REDIS_PORT') { 6379 },
    db: ENV.fetch('REDIS_DB') { 0 },
    namespace: 'rack::attack'
  )

  Rack::Attack.throttle('auth/ip', limit: 5, period: 30.seconds) do |req|
    req.ip if req.path =~ /\A\/api\/v1\/auth\//
  end

  # ==> Error Messages
  # Configure error message handling
  config.i18n.load_path += Dir[Rails.root.join('config', 'locales', 'devise.*.yml')]
  config.i18n.default_locale = :en

  # ==> Navigation Configuration
  # Configure navigation behavior
  config.navigational_formats = ['*/*', :html, :json]
  config.sign_out_via = [:delete, :get]

  # ==> Warden Configuration
  # Configure Warden behavior and callbacks
  config.warden do |manager|
    manager.default_strategies(scope: :user).unshift :jwt
    manager.failure_app = CustomFailureApp
    
    manager.intercept_401 = false
    
    manager.scope_defaults :user,
      store: false,
      strategies: [:jwt],
      action: 'devise/sessions#new'
  end
end

# Configure Warden hooks for audit logging
Warden::Manager.after_authentication do |user, auth, opts|
  AuditLogJob.perform_later(
    action: 'authentication',
    resource_type: 'User',
    resource_id: user.id,
    changes: { event: 'login' },
    user_id: user.id,
    ip_address: auth.request.remote_ip
  )
end

Warden::Manager.before_failure do |env, opts|
  request = ActionDispatch::Request.new(env)
  AuditLogJob.perform_later(
    action: 'authentication_failure',
    resource_type: 'User',
    resource_id: nil,
    changes: { 
      event: 'failed_login',
      reason: opts[:message]
    },
    user_id: nil,
    ip_address: request.remote_ip
  )
end