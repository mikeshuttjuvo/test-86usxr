# frozen_string_literal: true

require 'rails_helper'

RSpec.describe User, type: :model do
  # Setup test data
  let(:user) { create(:user) }
  let(:admin) { create(:user, role: 'admin') }
  let(:manager) { create(:user, role: 'manager') }
  let(:valid_password) { 'P@ssw0rd123!' }

  describe 'validations' do
    it { should validate_presence_of(:email) }
    it { should validate_uniqueness_of(:email).case_insensitive }
    it { should validate_presence_of(:role) }
    it { should validate_inclusion_of(:role).in_array(User::ROLES) }
    it { should validate_presence_of(:first_name) }
    it { should validate_presence_of(:last_name) }
    it { should validate_length_of(:first_name).is_at_most(50) }
    it { should validate_length_of(:last_name).is_at_most(50) }

    context 'password validation' do
      it { should validate_presence_of(:password).on(:create) }
      it { should validate_length_of(:password).is_at_least(12) }

      it 'validates password complexity' do
        user = build(:user, password: 'simple')
        expect(user).not_to be_valid
        expect(user.errors[:password]).to include(/must contain at least one uppercase letter, one lowercase letter, one number, and one special character/)
      end

      it 'accepts valid complex passwords' do
        user = build(:user, password: valid_password)
        expect(user).to be_valid
      end
    end

    it 'validates email format' do
      user = build(:user, email: 'invalid_email')
      expect(user).not_to be_valid
      expect(user.errors[:email]).to include('is invalid')
    end
  end

  describe 'authentication' do
    describe '#generate_jwt' do
      it 'generates a valid JWT token with correct claims' do
        token = user.generate_jwt
        decoded_token = JWT.decode(
          token,
          Rails.application.credentials.jwt_secret_key,
          true,
          algorithm: 'HS256'
        ).first

        expect(decoded_token['user_id']).to eq(user.id)
        expect(decoded_token['role']).to eq(user.role)
        expect(decoded_token['jti']).to eq(user.jti)
        expect(decoded_token['exp']).to be > Time.current.to_i
        expect(decoded_token['iss']).to eq(Rails.application.config.jwt_issuer)
      end

      it 'generates tokens that expire in 24 hours' do
        token = user.generate_jwt
        decoded_token = JWT.decode(
          token,
          Rails.application.credentials.jwt_secret_key,
          true,
          algorithm: 'HS256'
        ).first

        expect(decoded_token['exp']).to be_within(1).of(24.hours.from_now.to_i)
      end
    end

    describe '#valid_password?' do
      it 'validates correct passwords' do
        user.password = valid_password
        user.save
        expect(user.valid_password?(valid_password)).to be true
      end

      it 'rejects incorrect passwords' do
        user.password = valid_password
        user.save
        expect(user.valid_password?('wrong_password')).to be false
      end

      it 'tracks failed attempts' do
        expect {
          User::MAX_LOGIN_ATTEMPTS.times { user.valid_password?('wrong_password') }
        }.to change { user.reload.failed_attempts }.by(User::MAX_LOGIN_ATTEMPTS)
      end

      it 'locks account after maximum failed attempts' do
        User::MAX_LOGIN_ATTEMPTS.times { user.valid_password?('wrong_password') }
        expect(user.reload.access_locked?).to be true
      end
    end
  end

  describe 'authorization' do
    describe 'role checks' do
      it 'correctly identifies admin role' do
        expect(admin.admin?).to be true
        expect(manager.admin?).to be false
        expect(user.admin?).to be false
      end

      it 'correctly identifies manager role' do
        expect(admin.manager?).to be false
        expect(manager.manager?).to be true
        expect(user.manager?).to be false
      end

      it 'caches role check results' do
        expect(Rails.cache).to receive(:fetch).with(
          "#{admin.cache_key}:role:admin",
          ttl: User::CACHE_TTL
        ).and_return(true)
        
        admin.admin?
      end
    end
  end

  describe 'data protection' do
    it 'encrypts sensitive attributes' do
      user = create(:user, password: valid_password)
      expect(user.encrypted_password).not_to eq(valid_password)
      expect(user.encrypted_password).to be_present
    end

    it 'generates audit logs for sensitive changes' do
      expect {
        user.update(role: 'manager')
      }.to change(AuditLog, :count).by(1)

      audit_log = AuditLog.last
      expect(audit_log.action).to eq('update')
      expect(audit_log.resource_type).to eq('User')
      expect(audit_log.resource_id).to eq(user.id)
      expect(audit_log.changes).to include('role')
    end

    it 'implements soft deletion' do
      expect {
        user.soft_delete
      }.not_to change(User, :count)

      expect(user.deleted_at).to be_present
      expect(user.active).to be false
      expect(User.find_by(id: user.id)).to be_nil
      expect(User.with_deleted.find(user.id)).to eq(user)
    end
  end

  describe 'performance' do
    it 'caches full name' do
      expect(Rails.cache).to receive(:fetch).with(
        "#{user.cache_key}:full_name",
        ttl: User::CACHE_TTL
      ).and_return("#{user.first_name} #{user.last_name}")

      user.full_name
    end

    it 'invalidates cache on update' do
      expect(Rails.cache).to receive(:delete_matched).with("#{user.cache_key}:*")
      user.update(first_name: 'Updated')
    end

    it 'uses connection pooling for database operations' do
      expect(ActiveRecord::Base.connection_pool).to receive(:with_connection).and_call_original
      User.transaction_with_retry { user.save }
    end

    it 'prevents N+1 queries' do
      create_list(:user, 3)
      
      expect {
        User.includes(:audit_logs).map(&:full_name)
      }.to make_database_queries(count: 2) # One for users, one for audit logs
    end
  end
end