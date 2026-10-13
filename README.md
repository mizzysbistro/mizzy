# Mizzy — Independent Android Restaurant POS

**Status:** P1 ordering workflow is under implementation. The Counter → Orders → Kitchen loop exists as a local-only development demo; cloud sync and real payments are not enabled. This repository is independent of the existing POS repositories.

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

Implemented in source (verification status varies by commit; see CI links below):

- Versioned SQLite schema and persisted device/installation ID.
- Local Counter, Tables, Orders, and Kitchen demo screens backed by one SQLite order repository. The demo menu is seeded once into the organization/branch-scoped SQLite catalog and is loaded from the catalog; order lines snapshot the catalog UUID, SKU, name and price. The table grid supports dine-in selection, transactional table occupancy/release, and table names in Orders; saving an order writes immutable line snapshots, one kitchen ticket, and outbox operations in one transaction. Kitchen transitions update the same parent order, and cancellation is blocked when any captured payment exists until refund handling is implemented.
- Retry/idempotency protections, including order-ID-aware request fingerprints, branch-scoped reads, legal Kitchen transitions, and scoped organization/branch access tests.
- Build-time Supabase configuration validation and guarded client initialization.
- Draft versioned Supabase tenant/branch migration and database catalog/grant smoke-test SQL.
- GitHub Actions workflow for formatting, analysis, tests, debug APK, and secret scanning.

Not yet verified or complete:

- Earlier green CI at commit `95a9528338085b2f2a057362e9b8fd5c066e6b81` passed formatter, analyzer, 17 Flutter tests, secret scan, Android debug APK build, and local Supabase migration/pgTAP validation ([Flutter run](https://github.com/mizzysbistro/mizzy/actions/runs/38421231622); [database run](https://github.com/mizzysbistro/mizzy/actions/runs/38421231810)).
- The expanded SQLite order repository suite (13 tests) and two local POS widget tests (Counter → Orders → Kitchen, plus dine-in table selection) are **not yet verified**. Latest PR CI jobs failed before any workflow step started (`runner_id: 0`, empty steps and no logs); see [CI blocker issue #13](https://github.com/mizzysbistro/mizzy/issues/13). Do not infer a test failure or success from those runs.
- No hosted Supabase project is connected; authenticated cloud POS flows, real-time synchronization and production payment processing are not active.
- The Counter/Orders/Kitchen UI is still local-only and uses a sample menu. Inventory, purchasing and reporting have not been connected to operational screens.
- The recorded debug APK is an older development artifact, not a signed production release; no production database, signed release APK, hardware validation or store publication has been created.

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
