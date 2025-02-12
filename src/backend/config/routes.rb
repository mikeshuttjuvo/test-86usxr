# frozen_string_literal: true

Rails.application.routes.draw do
  # Configure rate limiting middleware
  Rack::Attack.enabled = true
  Rack::Attack.cache.store = REDIS_CACHE_POOL

  # Health check endpoint for monitoring
  get '/health', to: 'application#health'

  # API routes with versioning
  namespace :api do
    namespace :v1, constraints: ApiVersionConstraint.new('v1') do
      # Authentication routes
      post '/auth/login', to: 'auth#login'
      post '/auth/logout', to: 'auth#logout'
      post '/auth/refresh', to: 'auth#refresh'
      get '/auth/validate', to: 'auth#validate'

      # Location resources with custom actions
      resources :locations do
        collection do
          get 'nearby', to: 'locations#nearby'
        end
      end

      # Job resources with custom actions
      resources :jobs do
        member do
          put 'status', to: 'jobs#update_status'
        end
      end
    end
  end

  # Catch-all route for invalid API versions
  match '/api/*path',
        to: 'api/v1/application#api_version_not_found',
        via: :all,
        constraints: { path: /v\d+/ }

  # Catch-all route for unmatched routes
  match '*path',
        to: 'application#route_not_found',
        via: :all,
        constraints: lambda { |req|
          !req.path.start_with?('/assets/', '/packs/', '/cable')
        }

  # Root route redirects to API documentation
  root to: redirect('/api/docs')
end

# Rate limiting configuration
Rack::Attack.throttle('api/ip', limit: 1000, period: 1.hour) do |req|
  req.ip if req.path.start_with?('/api/')
end

# Authentication rate limits
Rack::Attack.throttle('auth/login', limit: 5, period: 20.minutes) do |req|
  if req.path == '/api/v1/auth/login' && req.post?
    req.ip
  end
end

Rack::Attack.throttle('auth/refresh', limit: 10, period: 1.hour) do |req|
  if req.path == '/api/v1/auth/refresh' && req.post?
    req.ip
  end
end

# Location endpoint rate limits
Rack::Attack.throttle('locations/create', limit: 10, period: 1.minute) do |req|
  if req.path == '/api/v1/locations' && req.post?
    req.ip
  end
end

Rack::Attack.throttle('locations/nearby', limit: 30, period: 1.minute) do |req|
  if req.path == '/api/v1/locations/nearby' && req.get?
    req.ip
  end
end

# Job endpoint rate limits
Rack::Attack.throttle('jobs/create', limit: 10, period: 1.minute) do |req|
  if req.path == '/api/v1/jobs' && req.post?
    req.ip
  end
end

Rack::Attack.throttle('jobs/status', limit: 20, period: 1.minute) do |req|
  if req.path.match?(%r{/api/v1/jobs/\d+/status}) && req.put?
    req.ip
  end
end

# Configure Rack::Attack response
Rack::Attack.throttled_responder = lambda do |env|
  now = Time.current
  match_data = env['rack.attack.match_data']

  headers = {
    'Content-Type' => 'application/json',
    'X-RateLimit-Limit' => match_data[:limit].to_s,
    'X-RateLimit-Remaining' => '0',
    'X-RateLimit-Reset' => (now + (match_data[:period] - now.to_i % match_data[:period])).to_i.to_s
  }

  [
    429,
    headers,
    [{
      error: 'rate_limit_exceeded',
      message: 'Rate limit exceeded. Please try again later.',
      status: 429
    }.to_json]
  ]
end

# Track API metrics
ActiveSupport::Notifications.subscribe /rack_attack/ do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  req = event.payload[:request]

  NewRelic::Agent.record_metric(
    "Custom/RackAttack/#{event.payload[:discriminator]}",
    1
  )
end