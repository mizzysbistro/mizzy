begin;

create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users (
  id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('50000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'table-owner@example.invalid', '', now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now()),
  ('50000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'table-counter@example.invalid', '', now(), '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now());

insert into public.organizations (id, name, created_by)
values ('eeeeeeee-0000-4000-8000-000000000001', 'Table Guard Test Org', '50000000-0000-4000-8000-000000000001');

insert into public.branches (id, organization_id, name)
values ('eeeeeeee-0000-4000-8000-000000000011', 'eeeeeeee-0000-4000-8000-000000000001', 'Table Guard Branch');

insert into public.organization_memberships (organization_id, user_id, role)
values
  ('eeeeeeee-0000-4000-8000-000000000001', '50000000-0000-4000-8000-000000000001', 'owner'),
  ('eeeeeeee-0000-4000-8000-000000000001', '50000000-0000-4000-8000-000000000002', 'member');

insert into public.branch_memberships (organization_id, branch_id, user_id, role)
values ('eeeeeeee-0000-4000-8000-000000000001', 'eeeeeeee-0000-4000-8000-000000000011', '50000000-0000-4000-8000-000000000002', 'counter');

insert into public.menu_items (
  id, organization_id, branch_id, name, price_minor, currency_code
) values (
  'eeeeeeee-0000-4000-8000-000000000021',
  'eeeeeeee-0000-4000-8000-000000000001',
  'eeeeeeee-0000-4000-8000-000000000011',
  'Table guard meal', 1000, 'PHP'
);

insert into public.restaurant_tables (
  id, organization_id, branch_id, name, capacity, status
) values
  ('eeeeeeee-0000-4000-8000-000000000031', 'eeeeeeee-0000-4000-8000-000000000001', 'eeeeeeee-0000-4000-8000-000000000011', 'TG1', 2, 'available'),
  ('eeeeeeee-0000-4000-8000-000000000032', 'eeeeeeee-0000-4000-8000-000000000001', 'eeeeeeee-0000-4000-8000-000000000011', 'TG2', 2, 'available');

set local role authenticated;
set local request.jwt.claim.sub = '50000000-0000-4000-8000-000000000002';

select is((
  select order_status from public.save_order(
    'eeeeeeee-0000-4000-8000-000000000041',
    'eeeeeeee-0000-4000-8000-000000000001',
    'eeeeeeee-0000-4000-8000-000000000011',
    'eeeeeeee-0000-4000-8000-000000000051',
    1,
    'eeeeeeee-0000-4000-8000-000000000061',
    'eeeeeeee-0000-4000-8000-000000000071',
    'dine_in',
    'eeeeeeee-0000-4000-8000-000000000031',
    null,
    '[{"id":"eeeeeeee-0000-4000-8000-000000000081","catalogItemId":"eeeeeeee-0000-4000-8000-000000000021","quantityMilli":1000,"unitPriceMinor":1000}]'::jsonb
  )
), 'saved', 'a new order may reserve an available active table');

select is((
  select status from public.restaurant_tables
  where id = 'eeeeeeee-0000-4000-8000-000000000031'
), 'occupied', 'successful dine-in save occupies the table');

select is((
  select already_saved from public.save_order(
    'eeeeeeee-0000-4000-8000-000000000041',
    'eeeeeeee-0000-4000-8000-000000000001',
    'eeeeeeee-0000-4000-8000-000000000011',
    'eeeeeeee-0000-4000-8000-000000000051',
    1,
    'eeeeeeee-0000-4000-8000-000000000061',
    'eeeeeeee-0000-4000-8000-000000000071',
    'dine_in',
    'eeeeeeee-0000-4000-8000-000000000031',
    null,
    '[{"id":"eeeeeeee-0000-4000-8000-000000000081","catalogItemId":"eeeeeeee-0000-4000-8000-000000000021","quantityMilli":1000,"unitPriceMinor":1000}]'::jsonb
  )
), true, 'idempotent retry of the same order is still allowed after the table is occupied');

select throws_ok(
  $$select * from public.save_order(
    'eeeeeeee-0000-4000-8000-000000000042',
    'eeeeeeee-0000-4000-8000-000000000001',
    'eeeeeeee-0000-4000-8000-000000000011',
    'eeeeeeee-0000-4000-8000-000000000052',
    2,
    'eeeeeeee-0000-4000-8000-000000000062',
    'eeeeeeee-0000-4000-8000-000000000072',
    'dine_in',
    'eeeeeeee-0000-4000-8000-000000000031',
    null,
    '[{"id":"eeeeeeee-0000-4000-8000-000000000082","catalogItemId":"eeeeeeee-0000-4000-8000-000000000021","quantityMilli":1000,"unitPriceMinor":1000}]'::jsonb
  )$$,
  '40001',
  'Dine-in table is not available for a new order',
  'a different order cannot reserve an occupied table'
);

reset role;
update public.restaurant_tables
set status = 'reserved'
where id = 'eeeeeeee-0000-4000-8000-000000000032';
set local role authenticated;
set local request.jwt.claim.sub = '50000000-0000-4000-8000-000000000002';

select throws_ok(
  $$select * from public.save_order(
    'eeeeeeee-0000-4000-8000-000000000043',
    'eeeeeeee-0000-4000-8000-000000000001',
    'eeeeeeee-0000-4000-8000-000000000011',
    'eeeeeeee-0000-4000-8000-000000000053',
    3,
    'eeeeeeee-0000-4000-8000-000000000063',
    'eeeeeeee-0000-4000-8000-000000000073',
    'dine_in',
    'eeeeeeee-0000-4000-8000-000000000032',
    null,
    '[{"id":"eeeeeeee-0000-4000-8000-000000000083","catalogItemId":"eeeeeeee-0000-4000-8000-000000000021","quantityMilli":1000,"unitPriceMinor":1000}]'::jsonb
  )$$,
  '40001',
  'Dine-in table is not available for a new order',
  'a reserved table cannot be newly assigned'
);

select is((
  select status from public.restaurant_tables
  where id = 'eeeeeeee-0000-4000-8000-000000000032'
), 'reserved', 'failed order leaves the reserved table unchanged');

select is((
  select order_status from public.save_order(
    'eeeeeeee-0000-4000-8000-000000000044',
    'eeeeeeee-0000-4000-8000-000000000001',
    'eeeeeeee-0000-4000-8000-000000000011',
    'eeeeeeee-0000-4000-8000-000000000054',
    4,
    'eeeeeeee-0000-4000-8000-000000000064',
    'eeeeeeee-0000-4000-8000-000000000074',
    'takeaway',
    null,
    null,
    '[{"id":"eeeeeeee-0000-4000-8000-000000000084","catalogItemId":"eeeeeeee-0000-4000-8000-000000000021","quantityMilli":1000,"unitPriceMinor":1000}]'::jsonb
  )
), 'saved', 'takeaway order creation remains unaffected');

select is((
  select count(*)::integer from public.orders
  where table_id = 'eeeeeeee-0000-4000-8000-000000000031'
), 1, 'rejected second order was not inserted for the occupied table');

select * from finish();
rollback;
