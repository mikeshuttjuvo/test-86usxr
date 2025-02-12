# frozen_string_literal: true

class AuditLogSerializer < ApplicationSerializer
  # Version for cache key generation
  VERSION = '1.0'

  # Pattern for masking IP addresses (x.x.*.*)
  MASKED_IP_PATTERN = /^(\d{1,3}\.\d{1,3})\.\d{1,3}\.\d{1,3}$/

  # Cache expiry for audit log records (24 hours)
  CACHE_EXPIRY = 24.hours

  # Define attributes to be serialized
  attributes :id, :action, :resource_type, :resource_id, :changes, :user_id, :ip_address, :created_at

  # Override cache options for audit logs
  def cache_options
    {
      expires_in: CACHE_EXPIRY,
      namespace: 'audit_log',
      version: VERSION,
      race_condition_ttl: 10.seconds,
      compress: true,
      cache_nils: false
    }
  end

  # Generate cache key including audit-specific elements
  def cache_key
    key_components = [
      super,
      object.resource_type,
      object.resource_id,
      object.action
    ]
    
    Digest::SHA256.hexdigest(key_components.join('-'))
  end

  # Customize attribute serialization with masking
  def attributes(*args)
    data = super

    # Mask sensitive data in changes hash
    if data[:changes].present?
      data[:changes] = mask_sensitive_data(data[:changes])
    end

    # Mask user_id using one-way hash for privacy
    if data[:user_id].present?
      data[:user_id] = Digest::SHA256.hexdigest("user-#{data[:user_id]}-#{Rails.application.secrets.secret_key_base}")
    end

    # Mask IP address
    if data[:ip_address].present?
      data[:ip_address] = mask_ip_address(data[:ip_address])
    end

    data
  end

  private

  # Mask IP address while preserving first two octets
  def mask_ip_address(ip_address)
    return nil unless ip_address.present?

    if ip_address.include?(':') # IPv6
      segments = ip_address.split(':')
      return segments[0..3].join(':') + ':****:****:****:****'
    else # IPv4
      if (match = MASKED_IP_PATTERN.match(ip_address))
        return "#{match[1]}.*.*"
      end
    end

    # Return fully masked if pattern doesn't match
    '*.*.*.* '
  end

  # Override serializable hash to ensure consistent masking
  def serializable_hash(adapter_options = nil, options = {}, adapter_instance = self.class.serialization_adapter_instance)
    hash = super
    
    # Additional security checks for sensitive data
    hash.delete(:changes) if hash[:changes]&.empty?
    hash.delete(:ip_address) unless instance_options[:include_ip_address]
    
    hash
  end
end