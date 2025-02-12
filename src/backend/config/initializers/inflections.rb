# frozen_string_literal: true

# Be sure to restart your server when you modify this file.

# Add new inflection rules using the following format. Inflections
# are locale specific, and you may define rules for as many different
# locales as you wish. The rules in this file are for the English locale.

# Defines custom inflection rules for proper pluralization, singularization,
# and acronym handling throughout the application. This is particularly
# important for consistent API endpoint naming and resource identification.

ActiveSupport::Inflector.inflections(:en) do |inflect|
  # Technical Acronyms
  # Ensures proper casing of technical terms in routes, model names,
  # and string transformations throughout the application
  inflect.acronym 'API'   # Application Programming Interface
  inflect.acronym 'REST'  # Representational State Transfer
  inflect.acronym 'JSON'  # JavaScript Object Notation
  inflect.acronym 'JWT'   # JSON Web Token
  inflect.acronym 'HTTP'  # Hypertext Transfer Protocol
  inflect.acronym 'HTTPS' # Hypertext Transfer Protocol Secure
  inflect.acronym 'SSL'   # Secure Sockets Layer
  inflect.acronym 'TLS'   # Transport Layer Security
  inflect.acronym 'UUID'  # Universally Unique Identifier
  inflect.acronym 'CRUD'  # Create Read Update Delete
  inflect.acronym 'SQL'   # Structured Query Language

  # No irregular inflections are currently required based on the
  # technical specifications and domain model
  
  # No uncountable words are currently identified in the
  # technical specifications and domain model
end