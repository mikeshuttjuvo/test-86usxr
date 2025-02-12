# frozen_string_literal: true

# rack-cors ~> 2.0
# Configures Cross-Origin Resource Sharing (CORS) settings for secure API access

# Configure CORS middleware with secure defaults and environment-specific settings
Rails.application.config.middleware.insert_before 0, Rack::Cors do |cors|
  allowed_origins = case Rails.env
                   when 'production'
                     ENV.fetch('CORS_ALLOWED_ORIGINS', '').split(',').map(&:strip)
                   when 'staging'
                     [ENV.fetch('STAGING_ORIGIN', 'https://staging.example.com')]
                   else
                     ['http://localhost:3000', 'http://127.0.0.1:3000']
                   end

  cors.allow do |allow|
    # Strict origin validation based on environment configuration
    allow.origins(*allowed_origins)

    # Explicitly allowlist permitted HTTP methods
    allow.methods %w[GET POST PUT PATCH DELETE OPTIONS]

    # Configure allowed request headers including security-related headers
    allow.headers %w[
      Origin
      Content-Type
      Accept
      Authorization
      X-Requested-With
      X-CSRF-Token
    ]

    # Expose permitted response headers to client applications
    allow.expose %w[
      Content-Type
      ETag
      X-Request-Id
      X-Runtime
    ]

    # Enable credentials for authenticated requests
    allow.credentials true

    # Set preflight request cache duration (1 hour)
    allow.max_age 3600
  end

  # Additional security configuration for production environment
  if Rails.env.production?
    cors.allow do |allow|
      # Strict configuration for sensitive endpoints
      allow.origins(*allowed_origins)
      allow.methods %w[GET POST PUT DELETE]
      allow.headers %w[
        Authorization
        Content-Type
        X-CSRF-Token
      ]
      allow.credentials true
      allow.max_age 3600

      # Path-specific CORS configuration for sensitive routes
      allow.resource '/api/v1/secure/*',
                    headers: :any,
                    methods: %i[get post put delete],
                    credentials: true,
                    max_age: 3600
    end
  end
end