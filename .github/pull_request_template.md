## Pull Request Description

### Problem Statement
<!-- Describe the problem this PR solves. Link to relevant issues. -->

### Solution Overview
<!-- Provide a high-level description of your solution -->

### Technical Details
<!-- Include implementation details, architectural decisions, and technical considerations -->

### Alternative Solutions Considered
<!-- List alternatives you considered and why they were not chosen -->

## Type of Change
<!-- Check all that apply -->
- [ ] New feature (non-breaking change adding functionality)
- [ ] Bug fix (non-breaking change fixing an issue)
- [ ] Breaking change (fix or feature causing existing functionality to change)
- [ ] Performance improvement
- [ ] Security enhancement
- [ ] Dependencies update
- [ ] Documentation update
- [ ] Configuration change
- [ ] Refactoring (no functional changes)

## Testing
<!-- Describe the tests you added or modified -->

### Test Coverage
- [ ] Unit tests added/modified
- [ ] Integration tests added/modified
- [ ] All tests passing (`bundle exec rspec`)
- [ ] Coverage maintained at 100% (`coverage/index.html`)

### Test Cases Added
<!-- List new test cases and scenarios covered -->

### Manual Testing Steps
<!-- Provide steps for manual verification -->

### Performance Impact
<!-- Describe performance implications and testing results -->

## Security Considerations

### Security Impact Assessment
- [ ] No PII/sensitive data exposure
- [ ] Input validation implemented
- [ ] Authentication controls maintained
- [ ] Authorization checks implemented
- [ ] Security scan passing (`bundle exec brakeman`)
- [ ] No new security vulnerabilities (`bundle exec bundle-audit`)

### Data Privacy Impact
<!-- Describe any data privacy implications -->

### Authentication Changes
<!-- Detail any changes to authentication mechanisms -->

### Authorization Changes
<!-- Detail any changes to authorization rules -->

## Database Changes
<!-- Complete if database changes are included -->

### Schema Changes
- [ ] Migrations are reversible
- [ ] No data loss risk
- [ ] Performance impact assessed
- [ ] Indexes properly configured

### Migration Strategy
<!-- Describe the deployment approach for migrations -->

### Rollback Plan
<!-- Detail how to rollback database changes if needed -->

### Data Impact
<!-- Describe impact on existing data -->

## Dependencies

### New Dependencies
<!-- List new gems/libraries added -->
- Package: 
- Version: 
- Purpose: 
- Security scan: 

### Updated Dependencies
<!-- List updated dependencies -->
- Package:
- From version:
- To version:
- Reason:

### Removed Dependencies
<!-- List removed dependencies -->

## Deployment Strategy

### Deployment Steps
1. <!-- List deployment steps -->

### Rollback Plan
1. <!-- List rollback steps -->

### Monitoring Requirements
- [ ] Logging added for new functionality
- [ ] Metrics configured in New Relic
- [ ] Alerts configured if needed
- [ ] Error tracking implemented

### Feature Flags
<!-- List any feature flags used -->

## Pre-merge Checklist
<!-- Verify all requirements are met -->

### Code Quality
- [ ] Follows Ruby style guide (Rubocop passing)
- [ ] Code is documented (YARD format)
- [ ] Complex logic is explained in comments
- [ ] No code smells or technical debt added
- [ ] Maintains single responsibility principle

### Testing
- [ ] All CI pipeline checks passing
- [ ] Test coverage maintained at 100%
- [ ] Edge cases covered
- [ ] Error scenarios tested
- [ ] Race conditions considered

### Security
- [ ] Security scan passing
- [ ] No sensitive data in logs
- [ ] Authentication/authorization properly implemented
- [ ] Input validation complete
- [ ] XSS/CSRF protections maintained

### Performance
- [ ] N+1 queries avoided
- [ ] Proper database indexing
- [ ] Cache strategy implemented where needed
- [ ] No unnecessary database calls
- [ ] Large payload impacts considered

### Documentation
- [ ] API documentation updated
- [ ] README updated if needed
- [ ] Change log updated
- [ ] Architecture diagrams updated if needed

### Compliance
- [ ] Meets regulatory requirements
- [ ] Follows security policies
- [ ] Maintains data privacy standards
- [ ] Audit trail maintained if required

## Required Reviewers
<!-- Based on CODEOWNERS configuration -->
- [ ] API Team Lead approval
- [ ] Security Team approval (if security-related)
- [ ] Data Team approval (if database changes)
- [ ] DevOps Team approval (if infrastructure changes)

## Additional Notes
<!-- Any additional information reviewers should know -->