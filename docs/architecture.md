# Architecture decision record: application and persistence

**Status:** Proposed implementation baseline; not yet runtime-verified.  
**Date:** 2026-10-13

## Boundaries

Keep dependencies moving inward:

- **Presentation** (lib/features/**/presentation): Flutter widgets and view state. Do not issue raw SQL from widgets.
- **Application** (lib/features/**/application): workflows and use cases, including validation, permissions requested by the UI, and order-state transitions.
- **Domain** (lib/features/**/domain): entities, value objects, invariants, and repository contracts. No Flutter, SQLite, or Supabase imports.
- **Data** (lib/features/**/data): repository implementations, DTOs, SQL mappings, outbox processing and reconciliation.
- **Infrastructure** (lib/core/**): database lifecycle, environment/configuration, logging, clock/ID providers, and platform integrations.

A UI permission check improves usability but is not a security boundary. The database/backend must authorize every protected operation.

## Local-first persistence

SQLite is the durable local record for device operation. Use versioned migrations and a database transaction for each logically atomic operation. Never store currency as a floating-point value: store integer minor units (for example, Philippine centavos) plus an ISO currency code. Preserve immutable sale-line snapshots (name, SKU if present, quantity, unit amount, discount/tax amounts) so later catalog edits cannot rewrite historical receipts.

Use UUIDs generated before writes for entities that may sync. A logical order has one order ID across Counter, Orders, and Kitchen views. A Kitchen ticket references that order and branch; it must not create a second order. State transitions and their audit/outbox records commit together.

## Suggested local tables

- local_meta: schema version and installation/device ID.
- catalog_items: cached catalog, branch-independent fields only where appropriate.
- restaurant_tables: table/area cache scoped by organization and branch.
- orders: UUID, organization/branch IDs, local order number, status, table, currency, integer total, created/updated timestamps, sync state.
- order_lines: order UUID, product UUID, quantity in a documented fixed-point/unit representation, and immutable sale snapshots.
- kitchen_tickets: UUID, order UUID, status, timestamps; unique logical mapping as defined by the order workflow.
- payments: payment intent/transaction state, method, amounts in minor units, provider reference and idempotency key. Never mark a queued electronic payment as successful.
- inventory_movements: append-only stock deltas with reason, source entity, actor and timestamp.
- sync_outbox: UUID operation ID, entity ID/type, operation type, payload/schema version, created time, attempts, last error and state.
- sync_cursors: server cursor per table/branch stream.

All tenant-owned local rows carry organization_id; all branch-owned rows carry branch_id. Queries must scope by active organization and branch. Local data is device data and is not a substitute for server RLS.

## Sync safety

1. Save an order, order lines, kitchen event, and outbox events in one SQLite transaction.
2. Use stable operation UUIDs and server-side unique constraints to make retries idempotent.
3. Retry transient network failures with bounded exponential backoff and jitter; surface permanent validation/conflict failures.
4. Do not blindly overwrite server state. Define merge policies per entity and stop for operator resolution where merging would affect money, stock, or kitchen fulfillment.
5. The UI must clearly distinguish local, pending, synced, failed, and conflicting changes.
6. Card/electronic payment confirmation comes only from a trusted provider/server result. A queued request is not a successful payment.
7. Keep audit history for voids, discounts, refunds, stock changes, and role changes.

## Role baseline

- **Owner:** organization-wide settings, branch creation, members/roles, all branch operations and reports.
- **Manager:** assigned branch operations, catalog/stock workflows, staff operations allowed by policy, and branch reports. No ability to elevate another user to Owner.
- **Counter:** POS, table assignment, order save/adjustment within policy, and tender workflow. Refunds, voids, discounts above configured thresholds and cash adjustments require explicit authorization.
- **Kitchen:** view assigned kitchen work and perform allowed preparation/status transitions. No access to payment credentials or owner/financial administration.

Roles are enforced server-side and scoped to branch memberships; hiding a button is not authorization.

## Decision gates

- Add persistence packages only with explicit dependency pins/constraints, lockfile review, and successful CI.
- Add Supabase client configuration only with publishable/anon key placeholders. Never place a service-role key in the Android bundle.
- Do not provision a cloud project or make a paid upgrade without approval.
- Mark this architecture verified only after code implementation, tests, and review of tenant/branch negative cases.
