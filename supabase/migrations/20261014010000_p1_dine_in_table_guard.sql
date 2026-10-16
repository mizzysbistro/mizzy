-- P1 safety fix: serialize dine-in order creation against live table state.
-- save_order already locks the selected row, but it did not reject a row that
-- was already occupied or reserved. This trigger re-checks while the same row
-- lock is held and before the order is inserted.
begin;

create or replace function private.guard_dine_in_table_availability()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_status text;
    v_is_active boolean;
begin
    if new.order_type is distinct from 'dine_in' or new.table_id is null then
        return new;
    end if;

    select t.status, t.is_active
      into v_status, v_is_active
    from public.restaurant_tables t
    where t.id = new.table_id
      and t.organization_id = new.organization_id
      and t.branch_id = new.branch_id
    for update;

    if not found then
        raise exception 'Dine-in table is missing or outside the selected branch'
          using errcode = '22023';
    end if;

    if not v_is_active or v_status is distinct from 'available' then
        raise exception 'Dine-in table is not available for a new order'
          using errcode = '40001';
    end if;

    return new;
end;
$$;

revoke all on function private.guard_dine_in_table_availability()
  from public, anon, authenticated;

drop trigger if exists orders_dine_in_table_availability on public.orders;
create trigger orders_dine_in_table_availability
before insert on public.orders
for each row
execute function private.guard_dine_in_table_availability();

commit;
