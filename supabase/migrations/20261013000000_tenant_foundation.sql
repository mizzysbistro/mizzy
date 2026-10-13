-- Mizzy P0 tenant/branch foundation.
-- Draft only: apply first to a disposable Supabase test stack and run negative RLS tests.
-- Never deploy to production without explicit approval.

begin;

create table public.organizations (
    id uuid primary key default gen_random_uuid(),
    name text not null check (length(btrim(name)) between 1 and 120),
    created_by uuid not null references auth.users(id) on delete restrict,
    created_at timestamptz not null default now()
);

create table public.branches (
    id uuid primary key default gen_random_uuid(),
    organization_id uuid not null references public.organizations(id) on delete cascade,
    name text not null check (length(btrim(name)) between 1 and 120),
    is_active boolean not null default true,
    created_at timestamptz not null default now(),
    unique (organization_id, name),
    unique (id, organization_id)
);

create table public.organization_memberships (
    organization_id uuid not null references public.organizations(id) on delete cascade,
    user_id uuid not null references auth.users(id) on delete cascade,
    role text not null check (role in ('owner', 'member')),
    is_active boolean not null default true,
    created_at timestamptz not null default now(),
    primary key (organization_id, user_id)
);

create table public.branch_memberships (
    organization_id uuid not null,
    branch_id uuid not null,
    user_id uuid not null,
    role text not null check (role in ('manager', 'counter', 'kitchen')),
    is_active boolean not null default true,
    created_at timestamptz not null default now(),
    primary key (branch_id, user_id),
    foreign key (branch_id, organization_id)
        references public.branches(id, organization_id) on delete cascade,
    foreign key (organization_id, user_id)
        references public.organization_memberships(organization_id, user_id) on delete cascade
);

create table public.audit_events (
    id uuid primary key default gen_random_uuid(),
    organization_id uuid not null references public.organizations(id) on delete cascade,
    branch_id uuid,
    actor_id uuid references auth.users(id) on delete set null,
    action text not null check (length(btrim(action)) between 1 and 120),
    entity_type text not null check (length(btrim(entity_type)) between 1 and 120),
    entity_id text,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    foreign key (branch_id, organization_id)
        references public.branches(id, organization_id) on delete restrict
);

create index branches_org_active_idx
    on public.branches (organization_id, is_active);
create index org_memberships_user_active_idx
    on public.organization_memberships (user_id, is_active);
create index branch_memberships_user_role_idx
    on public.branch_memberships (user_id, role, is_active);
create index audit_events_org_created_idx
    on public.audit_events (organization_id, created_at desc);
create index audit_events_branch_created_idx
    on public.audit_events (branch_id, created_at desc);

create schema if not exists private;

create or replace function private.is_org_member(p_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.organization_memberships as om
        where om.organization_id = p_organization_id
          and om.user_id = (select auth.uid())
          and om.is_active
    );
$$;

create or replace function private.has_org_role(
    p_organization_id uuid,
    p_roles text[]
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.organization_memberships as om
        where om.organization_id = p_organization_id
          and om.user_id = (select auth.uid())
          and om.is_active
          and om.role = any (p_roles)
    );
$$;

create or replace function private.can_access_branch(p_branch_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.branches as b
        join public.organization_memberships as om
          on om.organization_id = b.organization_id
         and om.user_id = (select auth.uid())
         and om.is_active
        where b.id = p_branch_id
          and (
              om.role = 'owner'
              or exists (
                  select 1
                  from public.branch_memberships as bm
                  where bm.branch_id = b.id
                    and bm.organization_id = b.organization_id
                    and bm.user_id = om.user_id
                    and bm.is_active
              )
          )
    );
$$;

create or replace function private.has_branch_role(
    p_branch_id uuid,
    p_roles text[]
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.branches as b
        join public.organization_memberships as om
          on om.organization_id = b.organization_id
         and om.user_id = (select auth.uid())
         and om.is_active
        where b.id = p_branch_id
          and (
              om.role = 'owner'
              or exists (
                  select 1
                  from public.branch_memberships as bm
                  where bm.branch_id = b.id
                    and bm.organization_id = b.organization_id
                    and bm.user_id = om.user_id
                    and bm.is_active
                    and bm.role = any (p_roles)
              )
          )
    );
$$;

-- Bootstrap the first tenant without exposing general organization/membership writes.
create or replace function public.create_organization(
    p_organization_name text,
    p_first_branch_name text
)
returns table (organization_id uuid, branch_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid := (select auth.uid());
    v_organization_id uuid;
    v_branch_id uuid;
begin
    if v_user_id is null then
        raise exception 'Authentication required' using errcode = '42501';
    end if;

    if p_organization_name is null
       or length(btrim(p_organization_name)) not between 1 and 120 then
        raise exception 'Organization name must be 1 to 120 characters'
            using errcode = '22023';
    end if;

    if p_first_branch_name is null
       or length(btrim(p_first_branch_name)) not between 1 and 120 then
        raise exception 'Branch name must be 1 to 120 characters'
            using errcode = '22023';
    end if;

    insert into public.organizations (name, created_by)
    values (btrim(p_organization_name), v_user_id)
    returning id into v_organization_id;

    insert into public.organization_memberships (
        organization_id, user_id, role
    ) values (v_organization_id, v_user_id, 'owner');

    insert into public.branches (organization_id, name)
    values (v_organization_id, btrim(p_first_branch_name))
    returning id into v_branch_id;

    return query select v_organization_id, v_branch_id;
end;
$$;

alter table public.organizations enable row level security;
alter table public.branches enable row level security;
alter table public.organization_memberships enable row level security;
alter table public.branch_memberships enable row level security;
alter table public.audit_events enable row level security;

-- Remove default API-role access before granting only what is intentional.
revoke all on table public.organizations from anon, authenticated;
revoke all on table public.branches from anon, authenticated;
revoke all on table public.organization_memberships from anon, authenticated;
revoke all on table public.branch_memberships from anon, authenticated;
revoke all on table public.audit_events from anon, authenticated;

grant select on table
    public.organizations,
    public.branches,
    public.organization_memberships,
    public.branch_memberships
to authenticated;

grant insert, delete on table public.branches to authenticated;
grant update (name, is_active) on table public.branches to authenticated;
grant select on table public.audit_events to authenticated;

create policy organizations_select_member
on public.organizations
for select to authenticated
using ((select private.is_org_member(id)));

create policy branches_select_member
on public.branches
for select to authenticated
using ((select private.can_access_branch(id)));

create policy branches_insert_owner
on public.branches
for insert to authenticated
with check ((select private.has_org_role(organization_id, array['owner']::text[])));

create policy branches_update_owner_or_branch_manager
on public.branches
for update to authenticated
using (
    (select private.has_org_role(organization_id, array['owner']::text[]))
    or (select private.has_branch_role(id, array['manager']::text[]))
)
with check (
    (select private.has_org_role(organization_id, array['owner']::text[]))
    or (select private.has_branch_role(id, array['manager']::text[]))
);

create policy branches_delete_owner
on public.branches
for delete to authenticated
using ((select private.has_org_role(organization_id, array['owner']::text[])));

create policy organization_memberships_select_owner
on public.organization_memberships
for select to authenticated
using (
    (select private.has_org_role(organization_id, array['owner']::text[]))
);

create policy branch_memberships_select_owner_or_branch_manager
on public.branch_memberships
for select to authenticated
using (
    (select private.has_org_role(organization_id, array['owner']::text[]))
    or (select private.has_branch_role(branch_id, array['manager']::text[]))
);

create policy audit_events_select_owner_or_branch_manager
on public.audit_events
for select to authenticated
using (
    (select private.has_org_role(organization_id, array['owner']::text[]))
    or (
        branch_id is not null
        and (select private.has_branch_role(branch_id, array['manager']::text[]))
    )
);

-- No client write policies are defined for memberships or audit_events.
-- Later trusted membership/audit workflows must be added with their own checks.

revoke all on function private.is_org_member(uuid) from public, anon;
revoke all on function private.has_org_role(uuid, text[]) from public, anon;
revoke all on function private.can_access_branch(uuid) from public, anon;
revoke all on function private.has_branch_role(uuid, text[]) from public, anon;
grant usage on schema private to authenticated;
grant execute on function private.is_org_member(uuid) to authenticated;
grant execute on function private.has_org_role(uuid, text[]) to authenticated;
grant execute on function private.can_access_branch(uuid) to authenticated;
grant execute on function private.has_branch_role(uuid, text[]) to authenticated;

revoke all on function public.create_organization(text, text) from public, anon;
grant execute on function public.create_organization(text, text) to authenticated;

commit;
