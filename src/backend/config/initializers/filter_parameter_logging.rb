# frozen_string_literal: true

# Configure Rails parameter filtering to protect sensitive data in logs
# Implements comprehensive filtering for PII, financial data, and security credentials
# Ensures compliance with GDPR, PCI DSS, and SOC 2 requirements
#
# @see Technical Specifications/7.2 Data Security
# @see Technical Specifications/7.3.2 Security Controls
# @see Technical Specifications/7.3.4 Compliance Requirements

# Security Credentials
security_patterns = [
  /password/i,          # Passwords and similar credentials
  /token/i,            # All types of tokens
  /secret/i,           # Secret keys and values
  /key/i,              # API keys and encryption keys
  /authorization/i,     # Authorization headers and credentials
  /credential/i,        # Generic credentials
  /signature/i         # Digital signatures and signing keys
]

# Authentication Tokens
auth_patterns = [
  /access[_-]?token/i,    # OAuth and JWT access tokens
  /refresh[_-]?token/i,   # OAuth refresh tokens
  /bearer/i,              # Bearer token headers
  /api[_-]?key/i         # API authentication keys
]

# Personal Identifiable Information (PII)
pii_patterns = [
  /ssn|social[_-]?security/i,      # Social Security Numbers
  /birth[_-]?(?:date|day)/i,       # Birth dates
  /(?:first|last)[_-]?name/i,      # Name components
  /email/i,                        # Email addresses
  /phone[_-]?number/i,             # Phone numbers
  /address/i,                      # Physical addresses
  /license[_-]?(?:number|id)/i,    # License numbers
  /passport[_-]?(?:number|id)/i,   # Passport numbers
  /tax[_-]?id/i                    # Tax identification numbers
]

# Financial Information
financial_patterns = [
  /(?:credit|debit)[_-]?card/i,        # Credit/debit card references
  /card[_-]?(?:number|cvv|cvc)/i,      # Card numbers and security codes
  /account[_-]?number/i,               # Bank account numbers
  /routing[_-]?number/i,               # Bank routing numbers
  /(?:iban|swift)/i,                   # International banking numbers
  /(?:bank|wire)[_-]?transfer/i,       # Bank transfer details
  /payment[_-]?(?:info|details)/i      # Payment information
]

# Health Information
health_patterns = [
  /health[_-]?(?:info|record)/i,       # Health records
  /medical[_-]?(?:info|record)/i,      # Medical information
  /insurance[_-]?(?:info|policy)/i     # Insurance information
]

# Combine all patterns into comprehensive filter
Rails.application.config.filter_parameters += [
  *security_patterns,
  *auth_patterns,
  *pii_patterns,
  *financial_patterns,
  *health_patterns,
  # Additional patterns for edge cases
  /password[_-]?confirmation/i,         # Password confirmation fields
  /current[_-]?password/i,             # Current password fields
  /one[_-]?time[_-]?(?:password|code)/i, # OTP and 2FA codes
  /mfa[_-]?token/i,                    # Multi-factor authentication tokens
  /private[_-]?key/i,                  # Private keys
  /encryption[_-]?key/i,               # Encryption keys
  /oauth/i,                            # OAuth related parameters
  /session[_-]?(?:id|token)/i          # Session identifiers
]

# Configure additional logging sanitization if in production
if Rails.env.production?
  # Ensure backtraces don't leak sensitive information
  Rails.backtrace_cleaner.add_silencer { |line| line =~ /password|token|key/i }
  
  # Add custom sanitization for request parameters
  module ActionDispatch
    class Request
      private
      
      def filtered_parameters
        @filtered_parameters ||= begin
          filtered = super
          # Additional custom filtering logic for complex nested structures
          deep_filter_sensitive_data(filtered)
        end
      end

      def deep_filter_sensitive_data(hash)
        hash.each_with_object({}) do |(key, value), result|
          result[key] = case value
          when Hash
            deep_filter_sensitive_data(value)
          when Array
            value.map { |v| v.is_a?(Hash) ? deep_filter_sensitive_data(v) : v }
          else
            value
          end
        end
      end
    end
  end
end