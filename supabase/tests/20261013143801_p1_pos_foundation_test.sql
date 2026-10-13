begin;

create extension if not exists pgtap with schema extensions;

select plan(27);

-- P1 catalog smoke checks. These tests intentionally avoid production data.
select has_table('public', 'menu_items', 'menu catalog table exists');
select has_table('public', 'restaurant_tables', 'restaurant table layout exists');
select has_table('public', 'orders', 'single logical orders table exists');
select has_table('public', 'order_lines', 'order line snapshots table exists');
select has_table('public', 'kitchen_tickets', 'one kitchen ticket per order table exists');
select has_table('public', 'payments', 'cash tender ledger exists');

select ok((select relrowsecurity from pg_class where oid = 'public.menu_items'::regclass), 'menu items has RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.restaurant_tables'::regclass), 'restaurant tables has RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.orders'::regclass), 'orders has RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.order_lines'::regclass), 'order lines has RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.kitchen_tickets'::regclass), 'kitchen tickets has RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.payments'::regclass), 'payments has RLS enabled');

select ok(not has_table_privilege('authenticated', 'public.orders', 'INSERT'), 'clients cannot directly insert orders');
select ok(not has_table_privilege('authenticated', 'public.orders', 'UPDATE'), 'clients cannot directly mutate orders');
select ok(not has_table_privilege('authenticated', 'public.orders', 'DELETE'), 'clients cannot directly delete orders');
select ok(not has_table_privilege('authenticated', 'public.order_lines', 'INSERT'), 'clients cannot directly insert order lines');
select ok(not has_table_privilege('authenticated', 'public.kitchen_tickets', 'UPDATE'), 'clients cannot directly mutate kitchen tickets');
select ok(not has_table_privilege('authenticated', 'public.payments', 'INSERT'), 'clients cannot directly record payments');

select ok(has_function_privilege('authenticated', 'public.save_order(uuid,uuid,uuid,uuid,bigint,uuid,uuid,text,uuid,text,jsonb)', 'EXECUTE'), 'authenticated callers can use save-order RPC');
select ok(not has_function_privilege('anon', 'public.save_order(uuid,uuid,uuid,uuid,bigint,uuid,uuid,text,uuid,text,jsonb)', 'EXECUTE'), 'anonymous callers cannot use save-order RPC');
select ok(has_function_privilege('authenticated', 'public.transition_kitchen_ticket(uuid,text)', 'EXECUTE'), 'authenticated callers can use kitchen transition RPC');
select ok(not has_function_privilege('anon', 'public.transition_kitchen_ticket(uuid,text)', 'EXECUTE'), 'anonymous callers cannot use kitchen transition RPC');
select ok(has_function_privilege('authenticated', 'public.record_cash_payment(uuid,uuid,uuid,uuid,uuid,bigint)', 'EXECUTE'), 'authenticated callers can use cash payment RPC');
select ok(not has_function_privilege('anon', 'public.record_cash_payment(uuid,uuid,uuid,uuid,uuid,bigint)', 'EXECUTE'), 'anonymous callers cannot use cash payment RPC');

select ok((select prosecdef from pg_proc where oid = 'public.save_order(uuid,uuid,uuid,uuid,bigint,uuid,uuid,text,uuid,text,jsonb)'::regprocedure), 'save-order RPC runs with a controlled definer context');
select ok((select prosecdef from pg_proc where oid = 'public.transition_kitchen_ticket(uuid,text)'::regprocedure), 'kitchen transition RPC runs with a controlled definer context');
select ok((select prosecdef from pg_proc where oid = 'public.record_cash_payment(uuid,uuid,uuid,uuid,uuid,bigint)'::regprocedure), 'cash payment RPC runs with a controlled definer context');

select * from finish();
rollback;
