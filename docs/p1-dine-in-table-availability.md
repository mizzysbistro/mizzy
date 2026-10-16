# P1 dine-in table availability guard

**Status:** draft server-side protection for review; migration and pgTAP test have not run.

## Problem and behavior

The existing `save_order` RPC row-locks an assigned table and checks branch scope, but it does not reject an existing `occupied` or `reserved` status before the new order row is inserted. Row locking alone does not prevent a second transaction from assigning the same table after the first transaction commits.

The migration adds a `BEFORE INSERT` trigger on `public.orders` that only handles `dine_in` orders. Because `save_order` already selects the table `FOR UPDATE`, the trigger checks `status = 'available'` within the same transaction and rejects a conflicting request with SQLSTATE `40001`. Idempotent retries of the original order return the previously saved order before inserting a row and remain valid. Takeaway/delivery paths are unaffected.

## Verification plan

- Run the new eight-assertion pgTAP file on a fresh local Supabase database.
- Run all existing migration/RLS/order RPC tests.
- Check concurrent same-table attempts, ideally using an integration test with two concurrent database sessions, before enabling cloud dine-in sync.
- Do not merge or deploy this protection until actual database verification and independent review complete.

No production database, hosted project, or paid resource was changed.
