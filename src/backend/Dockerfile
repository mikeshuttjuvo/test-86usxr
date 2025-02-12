# Stage 1: Builder base image
FROM ruby:3.2-slim AS builder

# Set environment variables
ENV LANG=C.UTF-8 \
    BUNDLE_JOBS=4 \
    BUNDLE_RETRY=3 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_APP_CONFIG=/usr/local/bundle

# Install essential packages and dependencies
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    curl \
    git \
    nodejs \
    ca-certificates \
    tzdata \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user for security
RUN groupadd -r app && \
    useradd -r -g app -d /app -s /bin/false app && \
    mkdir -p /app && \
    chown -R app:app /app

WORKDIR /app

# Install specific bundler version from Gemfile.lock
RUN gem install bundler -v 2.4.0

# Stage 2: Development environment
FROM builder AS development

USER app

# Copy dependency files
COPY --chown=app:app Gemfile Gemfile.lock ./

# Install all gems including development and test
RUN bundle config set --local without '' && \
    bundle install --jobs=${BUNDLE_JOBS} --retry=${BUNDLE_RETRY}

# Copy application code
COPY --chown=app:app . .

# Configure development environment
ENV RAILS_ENV=development \
    RAILS_LOG_TO_STDOUT=true \
    PORT=3000

# Development volumes for hot reloading
VOLUME ["/app", "/app/tmp", "/app/log"]

EXPOSE 3000

# Health check for development
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1

CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0", "-p", "3000"]

# Stage 3: Production environment
FROM builder AS production

USER app

# Copy dependency files
COPY --chown=app:app Gemfile Gemfile.lock ./

# Install production gems only
RUN bundle config set --local without 'development test' && \
    bundle config set --local deployment 'true' && \
    bundle install --jobs=${BUNDLE_JOBS} --retry=${BUNDLE_RETRY}

# Copy application code
COPY --chown=app:app . .

# Configure production environment
ENV RAILS_ENV=production \
    RAILS_LOG_TO_STDOUT=true \
    RAILS_SERVE_STATIC_FILES=true \
    PORT=3000

# Remove unnecessary files
RUN rm -rf \
    test \
    spec \
    tmp/* \
    log/* \
    .git \
    .gitignore \
    .rspec \
    .rubocop* \
    .env* \
    docker-compose* \
    README.md

# Precompile assets if needed
RUN bundle exec rake assets:precompile

# Clean up build dependencies
USER root
RUN apt-get update -qq && \
    apt-get remove -y build-essential git && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /usr/share/doc /usr/share/man
USER app

EXPOSE 3000

# Production health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1

# Start Puma server
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]