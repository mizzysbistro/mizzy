begin;

create extension if not exists pgtap with schema extensions;

select plan(15);

-- Synthetic identities and tenant fixtures only; transaction rolls back at the end.
insert into auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('30000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'p1-owner@example.invalid', '', now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()),
  ('30000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'p1-counter@example.invalid', '', now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()),
  ('30000000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'p1-kitchen@example.invalid', '', now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now());

insert into public.organizations (id, name, created_by)
values ('cccccccc-0000-4000-8000-000000000001', 'P1 RPC Test Org', '30000000-0000-4000-8000-000000000001');

insert into public.branches (id, organization_id, name)
values ('cccccccc-0000-4000-8000-000000000011', 'cccccccc-0000-4000-8000-000000000001', 'P1 Test Branch');

insert into public.organization_memberships (organization_id, user_id, role)
values
  ('cccccccc-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000001', 'owner'),
  ('cccccccc-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000002', 'member'),
  ('cccccccc-0000-4000-8000-000000000001', '30000000-0000-4000-8000-000000000003', 'member');

insert into public.branch_memberships (organization_id, branch_id, user_id, role)
values
  ('cccccccc-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000011', '30000000-0000-4000-8000-000000000002', 'counter'),
  ('cccccccc-0000-4000-8000-000000000001', 'cccccccc-0000-4000-8000-000000000011', '30000000-0000-4000-8000-000000000003', 'kitchen');

insert into public.menu_items (
  id, organization_id, branch_id, name, price_minor, currency_code
) values (
  'cccccccc-0000-4000-8000-000000000021',
  'cccccccc-0000-4000-8000-000000000001',
  'cccccccc-0000-4000-8000-000000000011',
  'Test meal', 1000, 'PHP'
);

insert into public.restaurant_tables (
  id, organization_id, branch_id, name, capacity
) values (
  'cccccccc-0000-4000-8000-000000000031',
  'cccccccc-0000-4000-8000-000000000001',
  'cccccccc-0000-4000-8000-000000000011',
  'T1', 2
);

set local role authenticated;
set local request.jwt.claim.sub = '30000000-0000-4000-8000-000000000002';

select is((
  select order_status from public.save_order(
    'cccccccc-0000-4000-8000-000000000041',
    'cccccccc-0000-4000-8000-000000000001',
    'cccccccc-0000-4000-8000-000000000011',
    'cccccccc-0000-4000-8000-000000000051',
    1,
    'cccccccc-0000-4000-8000-000000000061',
    'cccccccc-0000-4000-8000-000000000071',
    'dine_in',
    'cccccccc-0000-4000-8000-000000000031',
    null,
    '[{"id":"cccccccc-0000-4000-8000-000000000081","catalogItemId":"cccccccc-0000-4000-8000-000000000021","quantityMilli":1000,"unitPriceMinor":1000}]'::jsonb
  )
), 'saved', 'Counter saves one order');

select is((
  select total_minor from public.save_order(
    'cccccccc-0000-4000-8000-000000000041',
    'cccccccc-0000-4000-8000-000000000001',
    'cccccccc-0000-4000-8000-000000000011',
    'cccccccc-0000-4000-8000-000000000051',
    1,
    'cccccccc-0000-4000-8000-000000000061',
    'cccccccc-0000-4000-8000-000000000071',
    'dine_in',
    'cccccccc-0000-4000-8000-000000000031',
    null,
    '[{"id":"cccccccc-0000-4000-8000-000000000081","catalogItemId":"cccccccc-0000-4000-8000-000000000021","quantityMilli":1000,"unitPriceMinor":1000}]'::jsonb
  )
), 1000::bigint, 'server computes order total in integer minor units');

select is((
  select already_saved from public.save_order(
    'cccccccc-0000-4000-8000-000000000041',
    'cccccccc-0000-4000-8000-000000000001',
    'cccccccc-0000-4000-8000-000000000011',
    'cccccccc-0000-4000-8000-000000000051',
    1,
    'cccccccc-0000-4000-8000-000000000061',
    'cccccccc-0000-4000-8000-000000000071',
    'dine_in',
    'cccccccc-0000-4000-8000-000000000031',
    null,
    '[{"id":"cccccccc-0000-4000-8000-000000000081","catalogItemId":"cccccccc-0000-4000-8000-000000000021","quantityMilli":1000,"unitPriceMinor":1000}]'::jsonb
  )
), true, 'same idempotency key and payload returns existing order');

select throws_ok(
  $$select * from public.save_order(
    'cccccccc-0000-4000-8000-000000000041',
    'cccccccc-0000-4000-8000-000000000001',
    'cccccccc-0000-4000-8000-000000000011',
    'cccccccc-0000-4000-8000-000000000051',
    1,
    'cccccccc-0000-4000-8000-000000000061',
    'cccccccc-0000-4000-8000-000000000071',
    'dine_in',
    'cccccccc-0000-4000-8000-000000000031',
    'different payload',
    '[{"id":"cccccccc-0000-4000-8000-000000000081","catalogItemId":"cccccccc-0000-4000-8000-000000000021","quantityMilli":1000,"unitPriceMinor":1000}]'::jsonb
  )$$,
  '23505',
  'Idempotency key reused with a different request',
  'different payload cannot reuse an order idempotency key'
);

select is((select count(*)::integer from public.orders where id = 'cccccccc-0000-4000-8000-000000000041'), 1, 'only one parent order is stored');
select is((select count(*)::integer from public.order_lines where order_id = 'cccccccc-0000-4000-8000-000000000041'), 1, 'order has one persisted line snapshot');
select is((select count(*)::integer from public.kitchen_tickets where order_id = 'cccccccc-0000-4000-8000-000000000041'), 1, 'one kitchen ticket is linked to the order');
select is((select status from public.restaurant_tables where id = 'cccccccc-0000-4000-8000-000000000031'), 'occupied', 'saving a dine-in order occupies its table');

set local request.jwt.claim.sub = '30000000-0000-4000-8000-000000000003';

select is((
  select order_status from public.transition_kitchen_ticket('cccccccc-0000-4000-8000-000000000071', 'preparing')
), 'preparing', 'Kitchen can move queued ticket to preparing');

select is((
  select order_status from public.transition_kitchen_ticket('cccccccc-0000-4000-8000-000000000071', 'ready')
), 'ready', 'Kitchen can move preparing ticket to ready');

select is((
  select order_status from public.transition_kitchen_ticket('cccccccc-0000-4000-8000-000000000071', 'served')
), 'served', 'Kitchen served state updates the same parent order');

select throws_ok(
  $$select * from public.save_order(
    'cccccccc-0000-4000-8000-000000000091',
    'cccccccc-0000-4000-8000-000000000001',
    'cccccccc-0000-4000-8000-000000000011',
    'cccccccc-0000-4000-8000-000000000051',
    2,
    'cccccccc-0000-4000-8000-000000000092',
    'cccccccc-0000-4000-8000-000000000093',
    'takeaway',
    null,
    null,
    '[{"id":"cccccccc-0000-4000-8000-000000000094","catalogItemId":"cccccccc-0000-4000-8000-000000000021","quantityMilli":1000,"unitPriceMinor":1000}]'::jsonb
  )$$,
  '42501',
  'No access to the selected branch',
  'Kitchen cannot create counter orders'
);

set local request.jwt.claim.sub = '30000000-0000-4000-8000-000000000002';

select is((
  select order_status from public.record_cash_payment(
    'cccccccc-0000-4000-8000-000000000101',
    'cccccccc-0000-4000-8000-000000000001',
    'cccccccc-0000-4000-8000-000000000011',
    'cccccccc-0000-4000-8000-000000000041',
    'cccccccc-0000-4000-8000-000000000102',
    1000
  )
), 'completed', 'exact cash tender completes a served order');

select is((select status from public.orders where id = 'cccccccc-0000-4000-8000-000000000041'), 'completed', 'cash and Kitchen views converge on one completed order');
select is((select status from public.restaurant_tables where id = 'cccccccc-0000-4000-8000-000000000031'), 'available', 'completed dine-in order releases its table');

select * from finish();
rollback;
