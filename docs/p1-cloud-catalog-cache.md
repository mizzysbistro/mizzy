# P1-02: Authenticated cloud catalog cache

**Status:** selected branch cards now open a branch-scoped POS workspace and refresh the branch catalog (stacked draft PR #22). Orders, tables, Kitchen status and payments remain local-only. Not verified by Dart/Flutter; not production-ready.

## Contract

- CloudCatalogRepository.syncBranch accepts an explicit organization/branch. It invokes the caller-provided branch-access check before the network request; production wiring should use AuthRepository.listMyOrganizations() to validate active membership and branch access.
- SupabaseCloudCatalogSource requires an active Supabase Auth session, fetches all menu_items pages for exactly that organization/branch, and includes inactive rows so deactivated items are not kept active offline.
- Every row is checked for valid UUIDs, branch scope, name, integer minor-unit price, uppercase three-letter currency, active flag and timestamp before SQLite writes begin.
- New rows use the stable cloud UUID and are marked synced. The result's deactivated count includes cached items made unavailable either because the cloud disabled/removed them or a conflict forces them out of sale. Server updates refresh cache rows already synced. Differing unsynchronized rows are preserved, marked conflict, and made unavailable for new orders instead of being silently overwritten.
- Items absent from the full cloud result are made inactive. Local/pending/failed catalog rows under a cloud branch that have no matching server UUID are quarantined and hidden from new sales until catalog-write sync or explicit reconciliation exists. When a SKU has been reassigned to a different cloud UUID, an obsolete synced cache row releases that SKU while retaining the row; sale-line name/SKU/price snapshots are not changed.
- This component is read-only against Supabase. It does not create/update/delete catalog items remotely and does not enable cloud order upload.

## Remaining integration and safety work

- The stacked draft now wires the authenticated workspace's active branch list to a selectable branch POS. Its callback rechecks membership via AuthRepository before fetching both catalog and tables; Supabase RLS remains the server authorization boundary.
- Decide how catalog management writes and audit history are performed; the service deliberately makes no cloud writes.
- Local demo data stays in its separate generated organization/branch namespace. Cloud-selected branches skip demo menu/table seeding and pull real branch table UUIDs/statuses. Dine-in is only offered when an available cloud table is cached. Cloud order upload remains disabled; orders are saved locally until the sync worker is tested.
- Keep order upload blocked until the selected branch catalog has completed a successful pull and any price/identity conflicts are reconciled.
- Run all new tests plus existing Flutter tests, formatter/analyzer, secret scanning, Android debug build and fresh local Supabase migration/pgTAP. Current GitHub Actions runners fail before workflow steps, so no Dart tests or build are yet verified.