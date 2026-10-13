# P0 execution and validation checklist

This checklist is intentionally evidence-driven. Source files existing in Git do not count as successful test or release evidence.

## Flutter and Android gates

- [ ] `flutter pub get` completes and dependency resolution is recorded in the committed lockfile.
- [ ] `dart format --output=none --set-exit-if-changed lib test` passes without modifying source.
- [ ] `flutter analyze` reports no issues.
- [ ] Widget tests and SQLite FFI repository tests pass.
- [ ] Debug APK builds in CI and the APK artifact is downloadable.
- [ ] Record workflow URL, commit SHA, toolchain versions, artifact size, and SHA-256.
- [ ] Install on a real Android phone/tablet and verify launch, data retention after restart, and upgrade behavior.

## Local persistence/order tests

- [ ] The database enables foreign keys and upgrades without deleting orders or payments.
- [ ] Saving an order, its sale-line snapshots, Kitchen ticket, and outbox entries is one transaction.
- [ ] Retry with the same idempotency key returns the same order; a changed payload under that key is rejected.
- [ ] Kitchen transitions update the linked ticket and parent order together and cannot create a second order.
- [ ] Organization/branch scoped reads do not return another branch's order.
- [ ] Amounts use integer minor units; no money calculations use floating-point values.

## Supabase and access control

- [ ] Apply the draft migration to a disposable local Supabase stack with a recorded CLI version.
- [ ] Run the schema/grant pgTAP tests.
- [ ] Run the role/RLS tests for Owner, Manager, Counter, Kitchen, anonymous, cross-organization, and unassigned-branch access.
- [ ] Verify organization bootstrap RPC, function grants, fixed search paths, and no direct membership/audit writes.
- [ ] Add integration tests for organization bootstrap rollback and unauthorized role changes.
- [ ] Inspect secret scanner output and dependency audit results.
- [ ] Only use a publishable/anon client key protected by RLS; never package a service-role key.

## Release gate

P0 remains in progress until tests pass on CI. P1–P6 remain in progress until each required feature has acceptance evidence. Never deploy to a production database, publish a release, or pay for a plan without explicit approval.
