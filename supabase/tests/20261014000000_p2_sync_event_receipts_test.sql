begin;

create extension if not exists pgtap with schema extensions;

select plan(14);

-- Isolated test users/tenant. The transaction is rolled back at the end.
insert into auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('40000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'sync-owner@example.invalid', '', now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()),
  ('40000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'sync-counter@example.invalid', '', now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()),
  ('40000000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'sync-kitchen@example.invalid', '', now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now());

insert into public.organizations (id, name, created_by)
values ('dddddddd-0000-4000-8000-000000000001', 'Sync Event Test Org', '40000000-0000-4000-8000-000000000001');

insert into public.branches (id, organization_id, name)
values
  ('dddddddd-0000-4000-8000-000000000011', 'dddddddd-0000-4000-8000-000000000001', 'Sync Test Branch'),
  ('dddddddd-0000-4000-8000-000000000012', 'dddddddd-0000-4000-8000-000000000001', 'Unassigned Test Branch');

insert into public.organization_memberships (organization_id, user_id, role)
values
  ('dddddddd-0000-4000-8000-000000000001', '40000000-0000-4000-8000-000000000001', 'owner'),
  ('dddddddd-0000-4000-8000-000000000001', '40000000-0000-4000-8000-000000000002', 'member'),
  ('dddddddd-0000-4000-8000-000000000001', '40000000-0000-4000-8000-000000000003', 'member');

insert into public.branch_memberships (organization_id, branch_id, user_id, role)
values
  ('dddddddd-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000011', '40000000-0000-4000-8000-000000000002', 'counter'),
  ('dddddddd-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-000000000011', '40000000-0000-4000-8000-000000000003', 'kitchen');

insert into public.menu_items (
  id, organization_id, branch_id, name, price_minor, currency_code
) values (
  'dddddddd-0000-4000-8000-000000000021',
  'dddddddd-0000-4000-8000-000000000001',
  'dddddddd-0000-4000-8000-000000000011',
  'Sync test meal', 1000, 'PHP'
);

select ok(
  has_function_privilege(
    'authenticated',
    'public.apply_kitchen_transition_event(uuid,uuid,uuid,uuid,text,text)',
    'EXECUTE'
  ),
  'authenticated sessions can call the guarded Kitchen event RPC'
);
select ok(
  not has_function_privilege(
    'anon',
    'public.apply_kitchen_transition_event(uuid,uuid,uuid,uuid,text,text)',
    'EXECUTE'
  ),
  'anonymous callers cannot call the Kitchen event RPC'
);
select ok(
  not has_table_privilege('authenticated', 'public.sync_event_receipts', 'INSERT'),
  'clients cannot write idempotency receipts directly'
);

set local role authenticated;
set local request.jwt.claim.sub = '40000000-0000-4000-8000-000000000002';

select ok(exists (
  select 1 from public.save_order(
    'dddddddd-0000-4000-8000-000000000041',
    'dddddddd-0000-4000-8000-000000000001',
    'dddddddd-0000-4000-8000-000000000011',
    'dddddddd-0000-4000-8000-000000000051',
    1,
    'dddddddd-0000-4000-8000-000000000061',
    'dddddddd-0000-4000-8000-000000000071',
    'takeaway',
    null,
    null,
    '[{"id":"dddddddd-0000-4000-8000-000000000081","catalogItemId":"dddddddd-0000-4000-8000-000000000021","quantityMilli":1000,"unitPriceMinor":1000}]'::jsonb
  )
), 'a signed-in Counter can create the base order and Kitchen ticket');

set local request.jwt.claim.sub = '40000000-0000-4000-8000-000000000003';

select is((
  select already_applied from public.apply_kitchen_transition_event(
    'dddddddd-0000-4000-8000-000000000091',
    'dddddddd-0000-4000-8000-000000000001',
    'dddddddd-0000-4000-8000-000000000011',
    'dddddddd-0000-4000-8000-000000000071',
    'queued',
    'preparing'
  )
), false, 'first application records a new event receipt');

select is((
  select already_applied from public.apply_kitchen_transition_event(
    'dddddddd-0000-4000-8000-000000000091',
    'dddddddd-0000-4000-8000-000000000001',
    'dddddddd-0000-4000-8000-000000000011',
    'dddddddd-0000-4000-8000-000000000071',
    'queued',
    'preparing'
  )
), true, 'duplicate event returns its existing receipt');

select is((
  select status from public.kitchen_tickets
  where id = 'dddddddd-0000-4000-8000-000000000071'
), 'preparing', 'the Kitchen status transition is applied once');

select is((
  select count(*) from public.sync_event_receipts
  where organization_id = 'dddddddd-0000-4000-8000-000000000001'
    and branch_id = 'dddddddd-0000-4000-8000-000000000011'
    and event_id = 'dddddddd-0000-4000-8000-000000000091'
), 1::bigint, 'exactly one receipt exists per event');

select is((
  select count(*) from public.audit_events
  where action = 'kitchen.status_changed'
    and entity_id = 'dddddddd-0000-4000-8000-000000000071'
    and metadata->>'eventId' = 'dddddddd-0000-4000-8000-000000000091'
), 1::bigint, 'duplicate delivery does not duplicate the audit event');

select throws_ok(
  $$select * from public.apply_kitchen_transition_event(
    'dddddddd-0000-4000-8000-000000000091',
    'dddddddd-0000-4000-8000-000000000001',
    'dddddddd-0000-4000-8000-000000000011',
    'dddddddd-0000-4000-8000-000000000071',
    'preparing',
    'ready'
  )$$,
  '23505',
  'Sync event ID reused with a different payload',
  'same event ID cannot be reused with changed contents'
);

select throws_ok(
  $$select * from public.apply_kitchen_transition_event(
    'dddddddd-0000-4000-8000-000000000092',
    'dddddddd-0000-4000-8000-000000000001',
    'dddddddd-0000-4000-8000-000000000011',
    'dddddddd-0000-4000-8000-000000000071',
    'queued',
    'ready'
  )$$,
  '40001',
  'Kitchen state changed; reload before synchronization',
  'stale offline transition cannot overwrite newer state'
);

select throws_ok(
  $$select * from public.apply_kitchen_transition_event(
    'dddddddd-0000-4000-8000-000000000093',
    'dddddddd-0000-4000-8000-000000000001',
    'dddddddd-0000-4000-8000-000000000011',
    'dddddddd-0000-4000-8000-000000000071',
    'preparing',
    'served'
  )$$,
  '22023',
  'Invalid kitchen state transition',
  'invalid state transition is rejected'
);

set local request.jwt.claim.sub = '40000000-0000-4000-8000-000000000002';

select throws_ok(
  $$select * from public.apply_kitchen_transition_event(
    'dddddddd-0000-4000-8000-000000000094',
    'dddddddd-0000-4000-8000-000000000001',
    'dddddddd-0000-4000-8000-000000000011',
    'dddddddd-0000-4000-8000-000000000071',
    'preparing',
    'ready'
  )$$,
  '42501',
  'No access to the selected branch',
  'Counter cannot apply Kitchen status events'
);

set local request.jwt.claim.sub = '40000000-0000-4000-8000-000000000003';

select throws_ok(
  $$select * from public.apply_kitchen_transition_event(
    'dddddddd-0000-4000-8000-000000000095',
    'dddddddd-0000-4000-8000-000000000001',
    'dddddddd-0000-4000-8000-000000000012',
    'dddddddd-0000-4000-8000-000000000071',
    'preparing',
    'ready'
  )$$,
  '42501',
  'No access to the selected branch',
  'membership in one branch does not authorize another'
);

select * from finish();
rollback;
