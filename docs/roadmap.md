# Mizzy P0–P6 Roadmap and Acceptance Gates

## Product goal
A new, independent Android POS with an original implementation inspired by common restaurant POS workflows. Agreed Mizzy in-app features should not be hidden behind a subscription paywall. External services and hardware may still have costs or quotas.

## P0 — Foundation, identity and permissions
**Deliverables:** isolated Flutter baseline, architecture/environment docs, SQLite persistence scaffold, Supabase client/config scaffold, migrations, authentication, organizations, branches, profiles, memberships, role permissions, RLS, test and CI baseline.
**Exit gate:** clean baseline build; migrations validated; auth/role tests pass; cross-tenant isolation tests pass; no client service-role secret; setup documented.

## P1 — POS, tables, orders and kitchen
**Deliverables:** categories/products/variants/modifiers, tables, cart/order creation, totals, payment/refund/cash flows as scoped, kitchen tickets and transitions, shared Orders view.
**Exit gate:** saving once produces one logical order; Kitchen and Orders reflect the same order/status; totals and payment states are correct; integration tests pass.

## P2 — Partial offline and synchronization
**Deliverables:** local queue for eligible operations, visible pending-sync state, idempotent uploads, conflict rules, retry/backoff, reconnection reconciliation.
**Exit gate:** disconnect/reconnect/interruption tests pass; no lost or duplicated orders/stock movements; no false electronic payment confirmations.

## P3 — Inventory and purchasing
**Deliverables:** ingredients, recipes/items, stock locations/balances/movements, suppliers, purchase orders/items, goods receipts/items, stock counts/items, waste, transfers/items.
**Exit gate:** stock ledger remains coherent across sale/receipt/count/waste/transfer flows; corrections auditable; permissions enforced.

## P4 — Employees, customers and loyalty
**Deliverables:** employee profiles, shifts, attendance, customers, loyalty accounts/transactions/rewards, promotions.
**Exit gate:** role checks, reward/points calculations, duplicate-event protection, auditability.

## P5 — Reports, branches and backup
**Deliverables:** dashboard, sales/payment/inventory reports, expenses, branch filters/aggregation, backup metadata and restore workflow.
**Exit gate:** report totals reconcile to source transactions; branch filters pass; restore is demonstrated and documented.

## P6 — Security and production readiness
**Deliverables:** dependency/secret scans, comprehensive regression, RLS negative tests, offline/realtime checks, Android phone/tablet validation, printer/peripheral tests when in scope, signed build, install/upgrade checks, release/rollback docs.
**Exit gate:** no unresolved release blockers; no critical/high security defects; artifact provenance/checksum recorded; known limitations disclosed; release explicitly authorized.

## Shared data model scope
Organizations, branches, profiles, memberships, branch memberships, role permissions, devices, audit logs; categories, products, variants, modifiers/options, tables, orders, order items/modifiers, kitchen tickets/items, payments, refunds, cash sessions/movements; ingredients, recipes/items, stock locations, inventory balances/movements, suppliers, purchase orders/items, goods receipts/items, stock counts/items, waste records, stock transfers/items; employee profiles, shifts, attendance events, customers, loyalty accounts/transactions/rewards, promotions, expenses, backup records.

## Role baselines
- Owner: organization administration, branches, users/permissions, settings and oversight.
- Manager: authorized branch operations, reports, inventory and staff oversight.
- Counter: POS, tables, orders, permitted payment/cash actions, customer transactions.
- Kitchen: assigned tickets and allowed preparation-status transitions.

These are least-privilege starting profiles. Enforce sensitive permissions server-side.