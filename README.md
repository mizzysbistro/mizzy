# Mizzy — Independent Android Restaurant POS

**Status:** P0 foundation initialization. This repository is the new independent Mizzy project and is kept separate from the existing POS repositories.

## Mission
Build a production-ready Android POS inspired by familiar restaurant workflows, with an original implementation, free-first/open-source strategy, no subscription paywall for Mizzy's agreed in-app features, partial offline operation, and Supabase cloud synchronization.

## Technology baseline
- Android application: Flutter/Dart
- Local persistence: SQLite
- Cloud: Supabase Auth, PostgreSQL, Realtime, and Storage where appropriate
- Security: organization/branch-scoped Row Level Security (RLS), least privilege, trusted backend authorization, audit logs
- Tracking: GitHub issues and this repository's P0–P6 roadmap

## Roles
Owner, Manager, Counter, Kitchen. Role profiles are least-privilege baselines; sensitive operations must be authorized server-side.

## Modules
Dashboard, POS, tables, orders, kitchen, inventory, purchasing, employees, reports, customers, loyalty, branches, backup/settings, authentication, permissions, audit trails, and offline synchronization.

## P0–P6
- P0 Foundation, identity, permissions, local persistence, cloud scaffolding, tests/CI
- P1 POS, tables, orders, payments, kitchen, unified Orders view
- P2 Partial offline operation and idempotent synchronization
- P3 Inventory and purchasing
- P4 Employees, customers, loyalty, promotions
- P5 Reports, branches, backup and restore
- P6 Security hardening, device validation, signed release and production readiness

## Safe execution
Never commit privileged Supabase keys. Do not claim builds, tests, cloud resources, backups, or releases without evidence. Do not weaken security to make tests pass. Any production deployment, external spending, or destructive data operation requires explicit approval.

## Free-first disclaimer
Use open-source tooling and free tiers where feasible. Third-party hosting, payment processing, SMS, hardware, distribution, and usage above free quotas may cost money; do not represent these as guaranteed free.

## Development status
This repository is initialized for planning and tracking. Flutter application code, Supabase project configuration, Android builds, and production deployment are not yet verified.