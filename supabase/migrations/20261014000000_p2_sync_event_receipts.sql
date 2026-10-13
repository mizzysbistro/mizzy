-- P2: idempotent, expected-state Kitchen event application for offline replay.
-- Draft until tested against a disposable Supabase stack and independently reviewed.
begin;

create table public.sync_event_receipts (
    organization_id uuid not null,
    branch_id uuid not null,
    event_id uuid not null,
    request_fingerprint text not null check (request_fingerprint ~ '^[0-9a-f]{32}$'),
    ticket_id uuid not null,
    order_id uuid not null,
    ticket_status text not null
      check (ticket_status in ('queued', 'preparing', 'ready', 'served', 'cancelled')),
    order_status text not null
      check (order_status in ('saved', 'preparing', 'ready', 'served', 'completed', 'cancelled')),
    updated_at timestamptz not null,
    actor_id uuid not null references auth.users(id) on delete restrict,
    created_at timestamptz not null default now(),
    primary key (organization_id, branch_id, event_id),
    foreign key (branch_id, organization_id)
      references public.branches(id, organization_id) on delete cascade
);

alter table public.sync_event_receipts enable row level security;
revoke all on table public.sync_event_receipts from anon, authenticated;

create or replace function public.apply_kitchen_transition_event(
    p_event_id uuid,
    p_organization_id uuid,
    p_branch_id uuid,
    p_ticket_id uuid,
    p_expected_from_status text,
    p_next_status text
)
returns table (
    ticket_id uuid,
    order_id uuid,
    ticket_status text,
    order_status text,
    updated_at timestamptz,
    already_applied boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_actor uuid := (select auth.uid());
    v_fingerprint text;
    v_receipt public.sync_event_receipts%rowtype;
    v_ticket public.kitchen_tickets%rowtype;
    v_order_status text;
    v_now timestamptz := now();
    v_rows integer;
begin
    if v_actor is null then
        raise exception 'Authentication required' using errcode = '42501';
    end if;

    if p_event_id is null or p_organization_id is null or p_branch_id is null
       or p_ticket_id is null or p_expected_from_status is null
       or p_next_status is null then
        raise exception 'Invalid Kitchen event fields' using errcode = '22023';
    end if;

    if not exists (
        select 1
        from public.branches b
        where b.id = p_branch_id
          and b.organization_id = p_organization_id
          and b.is_active
    ) or not (
        select private.has_branch_role(
            p_branch_id,
            array['kitchen', 'manager']::text[]
        )
    ) then
        raise exception 'No access to the selected branch' using errcode = '42501';
    end if;

    -- Serialize concurrent copies of the same event before checking the receipt.
    perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended(
            p_organization_id::text || ':' || p_branch_id::text || ':' || p_event_id::text,
            0
        )
    );

    v_fingerprint := pg_catalog.md5(
        pg_catalog.jsonb_build_object(
            'eventId', p_event_id,
            'organizationId', p_organization_id,
            'branchId', p_branch_id,
            'ticketId', p_ticket_id,
            'fromStatus', p_expected_from_status,
            'toStatus', p_next_status
        )::text
    );

    select receipt.* into v_receipt
    from public.sync_event_receipts receipt
    where receipt.organization_id = p_organization_id
      and receipt.branch_id = p_branch_id
      and receipt.event_id = p_event_id
    for update;

    if found then
        if v_receipt.request_fingerprint <> v_fingerprint then
            raise exception 'Sync event ID reused with a different payload'
              using errcode = '23505';
        end if;
        return query select
            v_receipt.ticket_id,
            v_receipt.order_id,
            v_receipt.ticket_status,
            v_receipt.order_status,
            v_receipt.updated_at,
            true;
        return;
    end if;

    select kt.* into v_ticket
    from public.kitchen_tickets kt
    where kt.id = p_ticket_id
      and kt.organization_id = p_organization_id
      and kt.branch_id = p_branch_id
    for update;

    if not found then
        raise exception 'Kitchen ticket not found in the selected branch'
          using errcode = 'P0002';
    end if;

    -- This compare-and-set check prevents a delayed offline event from
    -- reversing a newer transition that another device already committed.
    if v_ticket.status is distinct from p_expected_from_status then
        raise exception 'Kitchen state changed; reload before synchronization'
          using errcode = '40001';
    end if;

    if not (
        (v_ticket.status = 'queued' and p_next_status in ('preparing', 'cancelled'))
        or (v_ticket.status = 'preparing' and p_next_status in ('ready', 'cancelled'))
        or (v_ticket.status = 'ready' and p_next_status in ('preparing', 'served'))
    ) then
        raise exception 'Invalid kitchen state transition' using errcode = '22023';
    end if;

    if p_next_status = 'cancelled' and exists (
        select 1
        from public.payments payment
        where payment.order_id = v_ticket.order_id
          and payment.organization_id = p_organization_id
          and payment.branch_id = p_branch_id
          and payment.status = 'captured'
    ) then
        raise exception 'Paid orders require an authorized refund before cancellation'
          using errcode = '22023';
    end if;

    v_order_status := case p_next_status
        when 'preparing' then 'preparing'
        when 'ready' then 'ready'
        when 'cancelled' then 'cancelled'
        when 'served' then case
            when coalesce((
                select sum(payment.amount_minor)
                from public.payments payment
                where payment.order_id = v_ticket.order_id
                  and payment.organization_id = p_organization_id
                  and payment.branch_id = p_branch_id
                  and payment.status = 'captured'
            ), 0) >= (
                select o.total_minor
                from public.orders o
                where o.id = v_ticket.order_id
                  and o.organization_id = p_organization_id
                  and o.branch_id = p_branch_id
            ) then 'completed'
            else 'served'
        end
        else null
    end;

    update public.kitchen_tickets
      set status = p_next_status, updated_at = v_now
    where id = p_ticket_id
      and organization_id = p_organization_id
      and branch_id = p_branch_id;
    get diagnostics v_rows = row_count;
    if v_rows <> 1 then
        raise exception 'Kitchen ticket changed concurrently; reload the order'
          using errcode = '40001';
    end if;

    update public.orders
      set status = v_order_status, updated_at = v_now
    where id = v_ticket.order_id
      and organization_id = p_organization_id
      and branch_id = p_branch_id;
    get diagnostics v_rows = row_count;
    if v_rows <> 1 then
        raise exception 'Parent order not found in the selected branch'
          using errcode = 'P0002';
    end if;

    if v_order_status in ('completed', 'cancelled') then
        update public.restaurant_tables table_row
          set status = 'available', updated_at = v_now
        where table_row.id = (
            select o.table_id
            from public.orders o
            where o.id = v_ticket.order_id
              and o.organization_id = p_organization_id
              and o.branch_id = p_branch_id
        )
          and table_row.organization_id = p_organization_id
          and table_row.branch_id = p_branch_id
          and table_row.status = 'occupied';
    end if;

    insert into public.audit_events (
        organization_id, branch_id, actor_id, action, entity_type, entity_id, metadata
    ) values (
        p_organization_id, p_branch_id, v_actor, 'kitchen.status_changed',
        'kitchen_ticket', p_ticket_id::text,
        pg_catalog.jsonb_build_object(
            'eventId', p_event_id,
            'from', v_ticket.status,
            'to', p_next_status,
            'orderId', v_ticket.order_id
        )
    );

    insert into public.sync_event_receipts (
        organization_id, branch_id, event_id, request_fingerprint,
        ticket_id, order_id, ticket_status, order_status, updated_at, actor_id
    ) values (
        p_organization_id, p_branch_id, p_event_id, v_fingerprint,
        p_ticket_id, v_ticket.order_id, p_next_status, v_order_status, v_now, v_actor
    );

    return query select
        p_ticket_id, v_ticket.order_id, p_next_status, v_order_status, v_now, false;
end;
$$;

revoke all on function public.apply_kitchen_transition_event(
    uuid, uuid, uuid, uuid, text, text
) from public, anon;
grant execute on function public.apply_kitchen_transition_event(
    uuid, uuid, uuid, uuid, text, text
) to authenticated;

commit;
