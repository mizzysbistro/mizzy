# Mizzy — Independent Android Restaurant POS

**Status:** P0 foundations are under implementation. This repository is the new independent Mizzy project and is kept separate from the existing POS repositories.

## Mission

Build a production-ready Android POS inspired by familiar restaurant workflows, with an original implementation, free-first/open-source strategy, no subscription paywall for Mizzy's agreed in-app features, partial offline operation, and Supabase cloud synchronization.

## Technology baseline

- Android application: Flutter/Dart
- Local persistence: SQLite, versioned schema, transactional orders and sync outbox
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

## Current implementation status

Implemented in source (not yet runtime-verified):

- Versioned SQLite schema and persisted device/installation ID.
- Local order repository that saves the order, immutable sale-line snapshots, one kitchen ticket, and outbox operations in a single transaction.
- Idempotent local save retries, payload-fingerprint protection, branch-scoped reads, and validated Kitchen transitions that update the same parent order.
- Build-time Supabase configuration validation and guarded client initialization.
- Draft versioned Supabase tenant/branch migration and database catalog/grant smoke-test SQL.
- GitHub Actions workflow for formatting, analysis, tests, debug APK, and secret scanning.

Not yet verified or complete:

- No successful Flutter test, static-analysis, or APK-build result has been captured.
- Supabase migration and RLS tests have not been run against an isolated database.
- No Supabase project is connected; authentication lifecycle, realtime synchronization, and server-side order/payment workflows are not active.
- User-facing Counter, Orders, Kitchen, inventory, purchasing, and reporting screens are not yet connected to the local repository.
- No production database, signed release APK, or store publication has been created.

## Development setup

Install Flutter stable, including its bundled Dart SDK, and the Android SDK. The baseline currently targets Flutter 3.47+ and Dart 3.12+. Then run:

```sh
flutter pub get
dart format lib test
flutter analyze
flutter test
flutter build apk --debug
```

For FFI-based SQLite tests on Debian/Ubuntu, install the system SQLite library development package (libsqlite3-0 and libsqlite3-dev).

## Supabase client configuration

The app reads build-time defines. Supply a Supabase project URL and a **publishable/anon client key** with `--dart-define` or `--dart-define-from-file`, for example:

```sh
flutter run \
  --dart-define=SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLISHABLE_KEY
```

Only use a public client key protected by reviewed RLS policies. The app explicitly rejects Supabase keys using the modern `sb_secret_` prefix and legacy JWT keys whose decoded role claim is `service_role`. Never commit any keys to Git. A public mobile key is not an authorization boundary: database grants, RLS, and trusted backend checks remain mandatory.

For a local emulator only, the explicit opt-in define `SUPABASE_ALLOW_INSECURE_LOCAL=true` permits plain HTTP to `localhost`, `127.0.0.1`, or `10.0.2.2`. Do not use this setting for production.

## Database development

The SQL in `supabase/migrations` is a draft until it is applied and tested against a disposable Supabase local/test stack. The first migration creates organization/branch membership structures and restrictive RLS defaults, but the entire role matrix and cross-tenant / cross-branch negative cases must pass before any production use. See `supabase/tests/README.md`.

## Safe execution

Never commit privileged Supabase keys. Do not claim builds, tests, cloud resources, backups, or releases without evidence. Do not weaken security to make tests pass. Any production deployment, external spending, or destructive data operation requires explicit approval.

## Free-first disclaimer

Use open-source tooling and free tiers where feasible. Third-party hosting, payment processing, SMS, hardware, distribution, and usage above free quotas may cost money; do not represent these as guaranteed free.
