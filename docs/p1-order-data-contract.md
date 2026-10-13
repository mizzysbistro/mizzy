# P1 order, kitchen and cash-tender contract

**Status:** design contract; the cloud order schema/RPCs are not implemented yet. This design intentionally keeps order writes server-authorized and retry-safe.

## One logical order

Counter, Orders and Kitchen are three views over one order ID. A successful local save atomically writes:

1. One `orders` row and immutable `order_lines` snapshots.
2. At most one `kitchen_tickets` row for that order.
3. A deterministic outbox event for the server save request.

The order save operation does not create a second order when a retry repeats the same idempotency key. Reusing a key with different canonical content is rejected.

## Cloud trust boundary

Do not grant authenticated clients direct `INSERT`, `UPDATE` or `DELETE` access to cloud orders, order lines, kitchen tickets, or payment rows. Client writes must use narrow PostgreSQL RPCs that run in a transaction and check `auth.uid()`, organization membership, branch membership and role. Every RPC is `SECURITY DEFINER` only where required, uses `SET search_path = ''`, schema-qualified table/function names, and minimal EXECUTE grants.

### Save-order request

A signed-in Owner, Manager or Counter can call the save RPC for an assigned branch. It validates:

- Request identity, UUIDs, order type, table membership, payload size and non-empty lines.
- Each menu item belongs to the selected organization and branch, is active, and has the expected current price. A stale price is a conflict requiring operator review, not a silent server-side repricing.
- Quantity is a positive fixed-point value. Money is computed using integer minor units, never floating point.
- Duplicate idempotency keys resolve to the existing server order only when the canonical payload fingerprint matches.
- Order, lines, initial kitchen ticket, audit event and response commit atomically.

The first iteration does not trust client-supplied total/discount/tax fields. Discounts, promotions, refunds, and non-cash tenders require separate server rules before they are enabled.

### Kitchen state machine

Kitchen can read assigned-branch ticket/order details but has no direct table writes. The transition RPC allows only `queued -> preparing/cancelled`, `preparing -> ready/cancelled`, `ready -> preparing/served`. It updates the ticket, parent order, audit event and outbox/sync version atomically. Repeating the current state is idempotent; illegal state jumps are rejected.

### Cash tender

The initial payment RPC is cash-only. It records integer minor units under a unique idempotency key, rejects overpayment and conflicting retries, and closes an order only when the captured tender matches the due amount. Electronic payments remain disabled until a trusted provider callback / server verification exists; a client request never proves a card, QR or e-wallet payment succeeded.

### Required tests before enabling writes

- Fresh migration and catalog/grant tests.
- Owner, Manager, Counter, Kitchen and anonymous role matrices; different organization and different branch.
- Unassigned branch, inactive membership, wrong menu item branch, stale price, empty/malformed lines and invalid table.
- Duplicate request key with same and different payload; rollback after forced failure; concurrent retry.
- Duplicate kitchen ticket prevention, legal/illegal transitions and synchronization of the single parent order.
- Cash payment idempotency, underpayment, exact payment, overpayment, order closure and concurrent payment retries.
