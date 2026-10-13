# P2 cloud synchronization contract

**Status:** implementation prerequisite / draft. The authenticated worker is not implemented, and no cross-device synchronization is active.

## One event, one durable server effect

A local outbox row is not proof of cloud persistence. The client may set status `done` only after the trusted Supabase RPC returns a durable success result. Stable local event IDs must be reused on retries; do not mint a new ID after a timeout.

### Order creation

- Send order creation through `public.save_order`, not direct table writes. The RPC rechecks the signed-in user’s branch role and active branch, validates cloud catalog membership/current price, computes server totals, and commits the order, lines and initial Kitchen ticket in one transaction.
- The local Kitchen-ticket create outbox event is dependent on order creation because the cloud order RPC creates the ticket itself. After the parent event is confirmed, verify that the remote ticket ID/order ID match before acknowledging the local ticket-create event. Never issue a second insert for the same ticket.
- The current local sample catalog is seeded only in SQLite; it is not the remote `menu_items` catalog. Orders referencing unavailable/stale cloud menu IDs must be quarantined for catalog reconciliation rather than silently re-priced or retried forever. Catalog synchronization remains a prerequisite.

### Kitchen transitions

- Use `public.apply_kitchen_transition_event` with the stable event UUID, organization/branch, ticket UUID, recorded `fromStatus`, and desired `toStatus`.
- The server locks the event identity, checks the active user’s branch role, compares the expected source state, updates ticket/order/table state and audit history, and stores an idempotency receipt in the same transaction.
- Replaying the same event UUID and same request returns the original receipt without applying another transition or audit entry. Reusing that event UUID with changed contents is rejected.
- A stale expected source state returns a conflict. The client must quarantine the event and ask an authorized operator to reconcile; it must not attempt to force the old transition or invent a new event ID.
- Receipts are not directly readable/writable by app clients; the RPC is the authorization boundary.

## Required worker behavior

1. Require a live Supabase Auth session and an explicitly selected organization/branch. Confirm active membership; the RPC independently rechecks authorization.
2. Claim a bounded outbox batch for exactly one organization/branch. Respect the dependency links; do not lease a Kitchen child until the parent is server-confirmed.
3. Validate schema version, UUIDs and payload shape. Never send service-role credentials or use direct writes to protected orders, tickets, payments or receipts.
4. Map permanent authorization, price/catalog, schema and stale-state failures to a safe conflict state. Retry only transient network/server/rate-limit errors with backoff.
5. Mark an event delivered only after RPC success/verified no-op; never label a local queued payment as successful.
6. Add pull cursors, remote change reconciliation and multi-device integration only after upload idempotency and branch-scope tests pass.

## Not yet covered

This contract does not enable a worker by itself. Catalog sync, authenticated upload/pull orchestration, app restart/offline-reconnect tests, cash-payment event sync, inventory event sync, CI verification, independent security review, and production configuration remain outstanding.