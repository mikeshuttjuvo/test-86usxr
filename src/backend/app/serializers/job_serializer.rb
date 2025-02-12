# frozen_string_literal: true

class JobSerializer < ApplicationSerializer
  # Version for cache invalidation when serializer changes
  SERIALIZER_VERSION = '1.0.0'

  # Enable caching with Redis
  cache key: :cache_key, enabled: true

  # Define attributes to be serialized
  attributes :id,
             :title,
             :description,
             :status,
             :start_date,
             :end_date,
             :active,
             :location_id

  # Initialize with job instance and configure caching
  def initialize(object, options = {})
    super
    @job = object
    setup_cache_options
  end

  # Override cache key generation to include version
  def cache_key
    base_key = super
    options_digest = Digest::SHA256.hexdigest(instance_options.to_s)
    "#{base_key}/#{SERIALIZER_VERSION}/#{options_digest}"
  end

  # Define attribute serialization methods
  def attributes(*args)
    data = super

    # Format dates in ISO8601
    data[:start_date] = object.start_date&.iso8601
    data[:end_date] = object.end_date&.iso8601

    # Ensure title is properly formatted
    data[:title] = format_title(object.title)

    # Mask sensitive information in description
    data[:description] = mask_sensitive_job_data(object.description)

    # Validate and normalize status
    data[:status] = normalize_status(object.status)

    # Include boolean flags
    data[:active] = object.active?

    # Include foreign key for relationship
    data[:location_id] = object.location_id

    # Apply masking to all sensitive fields
    mask_sensitive_data(data)
  end

  protected

  # Mask sensitive information in job data
  def mask_sensitive_job_data(field_value)
    return nil if field_value.nil?
    return field_value unless field_value.is_a?(String)

    # Define sensitive patterns specific to job data
    sensitive_patterns = {
      /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i => :email,
      /\b\d{3}[-.]?\d{3}[-.]?\d{4}\b/ => :phone,
      /\b(SSN|EIN|TIN)\b.{0,10}?\d/ => :id_number
    }

    masked_value = field_value.dup
    sensitive_patterns.each do |pattern, type|
      masked_value.gsub!(pattern) do |match|
        case type
        when :email
          mask_email(match)
        when :phone
          mask_phone(match)
        when :id_number
          mask_id_number(match)
        else
          '*' * match.length
        end
      end
    end

    masked_value
  end

  private

  # Set up caching configuration
  def setup_cache_options
    @cache_options = cache_options.merge(
      expires_in: 1.hour,
      version: SERIALIZER_VERSION,
      namespace: 'job_serializer'
    )
  end

  # Format job title consistently
  def format_title(title)
    return nil if title.nil?
    title.strip.gsub(/\s+/, ' ').capitalize
  end

  # Normalize job status values
  def normalize_status(status)
    return nil if status.nil?
    status.downcase.strip
  end

  # Mask email addresses
  def mask_email(email)
    return email unless email.include?('@')
    local, domain = email.split('@')
    "#{local[0]}#{'*' * (local.length - 1)}@#{domain}"
  end

  # Mask phone numbers
  def mask_phone(phone)
    clean_phone = phone.gsub(/[-.]/, '')
    "#{'*' * 6}#{clean_phone[-4..-1]}"
  end

  # Mask identification numbers
  def mask_id_number(number)
    clean_number = number.gsub(/\D/, '')
    "#{'*' * (clean_number.length - 4)}#{clean_number[-4..-1]}"
  end
end