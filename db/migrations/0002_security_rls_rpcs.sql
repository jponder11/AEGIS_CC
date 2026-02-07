-- =========================================================
-- AEGIS_CC • Migration 0002 • Security + RLS + RPC-only Writes (Phase 2)
-- Goals:
-- - Enable RLS
-- - Allow authenticated read
-- - Block direct writes to core tables
-- - Provide RPC functions (SECURITY DEFINER) as the blessed write path
-- - Auto-create profiles on signup
-- - Simple text roles (PoC) + admin-only role assignment
-- - Ensure audit attribution (updated_by) + append-only status_logs
-- - Avoid duplicate logs by removing status-change triggers (RPC logs only)
-- =========================================================
-- -------------------------------
-- 0) Helpers: actor + updated_by stamping
-- -------------------------------
create or replace function public.current_actor_id()
returns uuid
language plpgsql
stable
as $$
declare
  v_actor uuid;
begin
  begin
    v_actor := auth.uid();
  exception when others then
    v_actor := null;
  end;
  return v_actor;
end $$;

create or replace function public.set_updated_at_and_by()
returns trigger
language plpgsql
as $$
declare
  v_actor uuid;
begin
  new.updated_at := now();
  v_actor := public.current_actor_id();
  if v_actor is not null then
    new.updated_by := v_actor;
  else
    new.updated_by := coalesce(new.updated_by, old.updated_by);
  end if;
  return new;
end $$;

-- -------------------------------
-- 1) Ensure updated_by exists on key tables (safe add)
-- -------------------------------
alter table public.projects
  add column if not exists updated_by uuid references public.profiles(id) on delete set null;
alter table public.sov_items
  add column if not exists updated_by uuid references public.profiles(id) on delete set null;
alter table public.timeline_tasks
  add column if not exists updated_by uuid references public.profiles(id) on delete set null;
alter table public.project_kickoff
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists updated_by uuid references public.profiles(id) on delete set null;
alter table public.profiles
  add column if not exists updated_by uuid references public.profiles(id) on delete set null;

-- -------------------------------
-- 2) Attach updated_at/updated_by triggers
-- -------------------------------
drop trigger if exists trg_projects_updated_at on public.projects;
create trigger trg_projects_updated_at
before update on public.projects
for each row execute function public.set_updated_at_and_by();

drop trigger if exists trg_sov_updated_at on public.sov_items;
create trigger trg_sov_updated_at
before update on public.sov_items
for each row execute function public.set_updated_at_and_by();

drop trigger if exists trg_timeline_updated_at on public.timeline_tasks;
create trigger trg_timeline_updated_at
before update on public.timeline_tasks
for each row execute function public.set_updated_at_and_by();

drop trigger if exists trg_kickoff_updated_at on public.project_kickoff;
create trigger trg_kickoff_updated_at
before update on public.project_kickoff
for each row execute function public.set_updated_at_and_by();

drop trigger if exists trg_profiles_updated_at on public.profiles;
create trigger trg_profiles_updated_at
before update on public.profiles
for each row execute function public.set_updated_at_and_by();

-- -------------------------------
-- 3) Status log helper + actor assertion
-- -------------------------------
create or replace function public.insert_status_log(
  p_entity_type text,
  p_entity_id uuid,
  p_project_id uuid,
  p_from_status text,
  p_to_status text,
  p_message text,
  p_metadata jsonb,
  p_created_by uuid
) returns void
language plpgsql
as $$
begin
  insert into public.status_logs (
    entity_type,
    entity_id,
    project_id,
    from_status,
    to_status,
    message,
    metadata,
    created_by
  ) values (
    p_entity_type,
    p_entity_id,
    p_project_id,
    p_from_status,
    p_to_status,
    p_message,
    coalesce(p_metadata, '{}'::jsonb),
    p_created_by
  );
end $$;

create or replace function public.assert_actor_exists(p_actor_id uuid)
returns void
language plpgsql
as $$
begin
  if p_actor_id is null then
    raise exception 'actor_id is required';
  end if;
  if not exists (select 1 from public.profiles where id = p_actor_id) then
    raise exception 'actor_id % does not exist in profiles', p_actor_id;
  end if;
end $$;

-- -------------------------------
-- 4) Remove table-level status log triggers (avoid duplicates)
-- -------------------------------
drop trigger if exists trg_projects_status_log on public.projects;
drop trigger if exists trg_timeline_tasks_status_log on public.timeline_tasks;
drop function if exists public.log_project_status_change();
drop function if exists public.log_timeline_task_status_change();

-- -------------------------------
-- 5) Profiles auto-create on signup
-- -------------------------------
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, email, role, is_active)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', ''),
    new.email,
    'user',
    true
  )
  on conflict (id) do update
    set email = excluded.email,
        full_name = excluded.full_name,
        is_active = true;
  return new;
end $$;

drop trigger if exists trg_on_auth_user_created on auth.users;
create trigger trg_on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_auth_user();

create or replace function public.handle_auth_user_updated()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.profiles
  set
    email = new.email,
    full_name = coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', full_name),
    updated_at = now()
  where id = new.id;
  return new;
end $$;

drop trigger if exists trg_on_auth_user_updated on auth.users;
create trigger trg_on_auth_user_updated
after update of email, raw_user_meta_data on auth.users
for each row execute function public.handle_auth_user_updated();

-- -------------------------------
-- 6) Simple roles (PoC)
-- -------------------------------
alter table public.profiles
  drop constraint if exists profiles_role_check;
alter table public.profiles
  add constraint profiles_role_check
  check (role in ('user','pm','super','ops','executive','accounting','shop','admin','commandant'));

create or replace function public.current_user_role()
returns text
language sql
stable
as $$
  select role
  from public.profiles
  where id = auth.uid();
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
as $$
  select coalesce(public.current_user_role() in ('admin','commandant'), false);
$$;

-- Admin-only RPC to set role
create or replace function public.set_user_role(
  p_target_user_id uuid,
  p_new_role text,
  p_actor_id uuid,
  p_message text default null
) returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_role text;
  v_old public.profiles;
  v_new public.profiles;
begin
  perform public.assert_actor_exists(p_actor_id);
  select role into v_actor_role from public.profiles where id = p_actor_id;
  if v_actor_role not in ('admin','commandant') then
    raise exception 'Only admin/commandant can set roles';
  end if;
  if p_new_role not in ('user','pm','super','ops','executive','accounting','shop','admin','commandant') then
    raise exception 'Invalid role: %', p_new_role;
  end if;
  select * into v_old from public.profiles where id = p_target_user_id for update;
  if not found then
    raise exception 'Target user % not found in profiles', p_target_user_id;
  end if;
  update public.profiles
  set role = p_new_role,
      updated_by = p_actor_id,
      updated_at = now()
  where id = p_target_user_id
  returning * into v_new;
  perform public.insert_status_log(
    'profile',
    v_new.id,
    null,
    v_old.role,
    v_new.role,
    coalesce(p_message, 'User role updated'),
    jsonb_build_object('target_user_id', p_target_user_id),
    p_actor_id
  );
  return v_new;
end $$;

-- -------------------------------
-- 7) RPCs: blessed write paths
-- -------------------------------
-- Project: create
create or replace function public.create_project(
  p_project_code text,
  p_name text,
  p_actor_id uuid,
  p_client_name text default null,
  p_gc_name text default null,
  p_site_address1 text default null,
  p_site_address2 text default null,
  p_site_city text default null,
  p_site_state text default null,
  p_site_zip text default null,
  p_contract_value numeric default 0,
  p_start_date date default null,
  p_end_date date default null,
  p_pm_user_id uuid default null,
  p_super_user_id uuid default null
) returns public.projects
language plpgsql
security definer
set search_path = public
as $$
declare
  v_proj public.projects;
begin
  perform public.assert_actor_exists(p_actor_id);
  if p_project_code is null or btrim(p_project_code) = '' then
    raise exception 'project_code is required';
  end if;
  if p_name is null or btrim(p_name) = '' then
    raise exception 'project name is required';
  end if;
  insert into public.projects (
    project_code,
    name,
    client_name,
    gc_name,
    site_address1,
    site_address2,
    site_city,
    site_state,
    site_zip,
    status,
    contract_value,
    start_date,
    end_date,
    pm_user_id,
    super_user_id,
    created_by,
    updated_by
  ) values (
    btrim(p_project_code),
    btrim(p_name),
    p_client_name,
    p_gc_name,
    p_site_address1,
    p_site_address2,
    p_site_city,
    p_site_state,
    p_site_zip,
    'prospect',
    coalesce(p_contract_value, 0),
    p_start_date,
    p_end_date,
    p_pm_user_id,
    p_super_user_id,
    p_actor_id,
    p_actor_id
  )
  returning * into v_proj;
  perform public.insert_status_log(
    'project',
    v_proj.id,
    v_proj.id,
    null,
    v_proj.status::text,
    'Project created',
    jsonb_build_object('project_code', v_proj.project_code, 'project_name', v_proj.name),
    p_actor_id
  );
  return v_proj;
end $$;

-- Project: update core
create or replace function public.update_project_core(
  p_project_id uuid,
  p_actor_id uuid,
  p_name text default null,
  p_client_name text default null,
  p_gc_name text default null,
  p_site_address1 text default null,
  p_site_address2 text default null,
  p_site_city text default null,
  p_site_state text default null,
  p_site_zip text default null,
  p_pm_user_id uuid default null,
  p_super_user_id uuid default null
) returns public.projects
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old public.projects;
  v_new public.projects;
begin
  perform public.assert_actor_exists(p_actor_id);
  select * into v_old from public.projects where id = p_project_id for update;
  if not found then
    raise exception 'Project % not found', p_project_id;
  end if;
  update public.projects
  set name = coalesce(p_name, name),
      client_name = coalesce(p_client_name, client_name),
      gc_name = coalesce(p_gc_name, gc_name),
      site_address1 = coalesce(p_site_address1, site_address1),
      site_address2 = coalesce(p_site_address2, site_address2),
      site_city = coalesce(p_site_city, site_city),
      site_state = coalesce(p_site_state, site_state),
      site_zip = coalesce(p_site_zip, site_zip),
      pm_user_id = coalesce(p_pm_user_id, pm_user_id),
      super_user_id = coalesce(p_super_user_id, super_user_id),
      updated_by = p_actor_id,
      updated_at = now()
  where id = p_project_id
  returning * into v_new;
  perform public.insert_status_log(
    'project',
    v_new.id,
    v_new.id,
    null,
    null,
    'Project core updated',
    jsonb_build_object('project_code', v_new.project_code, 'project_name', v_new.name),
    p_actor_id
  );
  return v_new;
end $$;

-- Project: update status (audited)
create or replace function public.update_project_status(
  p_project_id uuid,
  p_new_status project_status,
  p_actor_id uuid,
  p_message text default null,
  p_metadata jsonb default '{}'::jsonb
) returns public.projects
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old public.projects;
  v_new public.projects;
begin
  perform public.assert_actor_exists(p_actor_id);
  select * into v_old from public.projects where id = p_project_id for update;
  if not found then
    raise exception 'Project % not found', p_project_id;
  end if;
  if v_old.status = p_new_status then
    return v_old;
  end if;
  update public.projects
  set status = p_new_status,
      updated_by = p_actor_id,
      updated_at = now()
  where id = p_project_id
  returning * into v_new;
  perform public.insert_status_log(
    'project',
    v_new.id,
    v_new.id,
    v_old.status::text,
    v_new.status::text,
    coalesce(p_message, 'Project status changed'),
    coalesce(p_metadata, '{}'::jsonb),
    p_actor_id
  );
  return v_new;
end $$;

-- Project: set current kickoff pointer
create or replace function public.set_current_kickoff(
  p_project_id uuid,
  p_kickoff_id uuid,
  p_actor_id uuid,
  p_message text default null
) returns public.projects
language plpgsql
security definer
set search_path = public
as $$
declare
  v_proj public.projects;
begin
  perform public.assert_actor_exists(p_actor_id);
  if not exists (
    select 1 from public.project_kickoff
    where id = p_kickoff_id and project_id = p_project_id
  ) then
    raise exception 'Kickoff % does not belong to project %', p_kickoff_id, p_project_id;
  end if;
  update public.projects
  set kickoff_current_id = p_kickoff_id,
      updated_by = p_actor_id,
      updated_at = now()
  where id = p_project_id
  returning * into v_proj;
  if not found then
    raise exception 'Project % not found', p_project_id;
  end if;
  perform public.insert_status_log(
    'project',
    v_proj.id,
    v_proj.id,
    null,
    null,
    coalesce(p_message, 'Current kickoff baseline set'),
    jsonb_build_object('kickoff_current_id', p_kickoff_id),
    p_actor_id
  );
  return v_proj;
end $$;

-- Kickoff: create baseline (versioned) + set current optionally
create or replace function public.create_kickoff_baseline(
  p_project_id uuid,
  p_actor_id uuid,
  p_contract_value_baseline numeric default null,
  p_start_date_baseline date default null,
  p_end_date_baseline date default null,
  p_billing_type billing_type default null,
  p_retainage_pct numeric default 0,
  p_schedule_notes text default null,
  p_scope_notes text default null,
  p_exclusions text default null,
  p_assumptions text default null,
  p_risk_flags jsonb default '{}'::jsonb,
  p_set_as_current boolean default true
) returns public.project_kickoff
language plpgsql
security definer
set search_path = public
as $$
declare
  v_proj public.projects;
  v_kick public.project_kickoff;
begin
  perform public.assert_actor_exists(p_actor_id);
  select * into v_proj from public.projects where id = p_project_id for update;
  if not found then
    raise exception 'Project % not found', p_project_id;
  end if;
  insert into public.project_kickoff (
    project_id,
    baseline_version,
    baseline_date,
    contract_value_baseline,
    start_date_baseline,
    end_date_baseline,
    billing_type,
    retainage_pct,
    schedule_notes,
    scope_notes,
    exclusions,
    assumptions,
    risk_flags,
    created_by,
    updated_by,
    updated_at
  ) values (
    p_project_id,
    null,
    current_date,
    coalesce(p_contract_value_baseline, v_proj.contract_value),
    coalesce(p_start_date_baseline, v_proj.start_date),
    coalesce(p_end_date_baseline, v_proj.end_date),
    p_billing_type,
    coalesce(p_retainage_pct, 0),
    p_schedule_notes,
    p_scope_notes,
    p_exclusions,
    p_assumptions,
    coalesce(p_risk_flags, '{}'::jsonb),
    p_actor_id,
    p_actor_id,
    now()
  )
  returning * into v_kick;
  if p_set_as_current then
    update public.projects
    set kickoff_current_id = v_kick.id,
        updated_by = p_actor_id,
        updated_at = now()
    where id = p_project_id;
  end if;
  perform public.insert_status_log(
    'kickoff',
    v_kick.id,
    p_project_id,
    null,
    null,
    case when p_set_as_current then 'Kickoff baseline created and set current'
         else 'Kickoff baseline created'
    end,
    jsonb_build_object('baseline_version', v_kick.baseline_version),
    p_actor_id
  );
  return v_kick;
end $$;

-- SOV: upsert + deactivate
create or replace function public.upsert_sov_item(
  p_project_id uuid,
  p_actor_id uuid,
  p_id uuid default null,
  p_code text default null,
  p_description text default null,
  p_scheduled_value numeric default null,
  p_sort_order integer default 0,
  p_is_active boolean default true
) returns public.sov_items
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item public.sov_items;
  v_exists boolean;
begin
  perform public.assert_actor_exists(p_actor_id);
  if p_description is null or btrim(p_description) = '' then
    raise exception 'SOV description is required';
  end if;
  v_exists := false;
  if p_id is not null then
    select true into v_exists from public.sov_items where id = p_id and project_id = p_project_id;
  end if;
  if v_exists then
    update public.sov_items
    set code = p_code,
        description = p_description,
        scheduled_value = coalesce(p_scheduled_value, scheduled_value),
        sort_order = coalesce(p_sort_order, sort_order),
        is_active = coalesce(p_is_active, is_active),
        updated_by = p_actor_id,
        updated_at = now()
    where id = p_id
    returning * into v_item;
    perform public.insert_status_log(
      'sov_item',
      v_item.id,
      v_item.project_id,
      null,
      null,
      'SOV item updated',
      jsonb_build_object('description', v_item.description, 'scheduled_value', v_item.scheduled_value),
      p_actor_id
    );
  else
    insert into public.sov_items (
      project_id,
      code,
      description,
      scheduled_value,
      sort_order,
      is_active,
      created_by,
      updated_by
    ) values (
      p_project_id,
      p_code,
      p_description,
      coalesce(p_scheduled_value, 0),
      coalesce(p_sort_order, 0),
      coalesce(p_is_active, true),
      p_actor_id,
      p_actor_id
    )
    returning * into v_item;
    perform public.insert_status_log(
      'sov_item',
      v_item.id,
      v_item.project_id,
      null,
      null,
      'SOV item created',
      jsonb_build_object('description', v_item.description, 'scheduled_value', v_item.scheduled_value),
      p_actor_id
    );
  end if;
  return v_item;
end $$;

create or replace function public.deactivate_sov_item(
  p_id uuid,
  p_actor_id uuid,
  p_message text default null
) returns public.sov_items
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item public.sov_items;
begin
  perform public.assert_actor_exists(p_actor_id);
  update public.sov_items
  set is_active = false,
      updated_by = p_actor_id,
      updated_at = now()
  where id = p_id
  returning * into v_item;
  if not found then
    raise exception 'SOV item % not found', p_id;
  end if;
  perform public.insert_status_log(
    'sov_item',
    v_item.id,
    v_item.project_id,
    null,
    null,
    coalesce(p_message, 'SOV item deactivated'),
    jsonb_build_object('description', v_item.description),
    p_actor_id
  );
  return v_item;
end $$;

-- Timeline: upsert + deactivate
create or replace function public.upsert_timeline_task(
  p_project_id uuid,
  p_actor_id uuid,
  p_id uuid default null,
  p_phase text default null,
  p_scope text default null,
  p_name text default null,
  p_status timeline_task_status default 'not_started',
  p_start_date date default null,
  p_end_date date default null,
  p_owner_user_id uuid default null,
  p_sort_order integer default 0,
  p_is_active boolean default true
) returns public.timeline_tasks
language plpgsql
security definer
set search_path = public
as $$
declare
  v_task public.timeline_tasks;
  v_exists boolean;
begin
  perform public.assert_actor_exists(p_actor_id);
  if p_name is null or btrim(p_name) = '' then
    raise exception 'Task name is required';
  end if;
  v_exists := false;
  if p_id is not null then
    select true into v_exists from public.timeline_tasks where id = p_id and project_id = p_project_id;
  end if;
  if v_exists then
    update public.timeline_tasks
    set phase = p_phase,
        scope = p_scope,
        name = p_name,
        status = coalesce(p_status, status),
        start_date = p_start_date,
        end_date = p_end_date,
        owner_user_id = p_owner_user_id,
        sort_order = coalesce(p_sort_order, sort_order),
        is_active = coalesce(p_is_active, is_active),
        updated_by = p_actor_id,
        updated_at = now()
    where id = p_id
    returning * into v_task;
    perform public.insert_status_log(
      'timeline_task',
      v_task.id,
      v_task.project_id,
      null,
      null,
      'Timeline task updated',
      jsonb_build_object('task_name', v_task.name, 'status', v_task.status::text),
      p_actor_id
    );
  else
    insert into public.timeline_tasks (
      project_id,
      phase,
      scope,
      name,
      status,
      start_date,
      end_date,
      owner_user_id,
      sort_order,
      is_active,
      created_by,
      updated_by
    ) values (
      p_project_id,
      p_phase,
      p_scope,
      p_name,
      coalesce(p_status, 'not_started'),
      p_start_date,
      p_end_date,
      p_owner_user_id,
      coalesce(p_sort_order, 0),
      coalesce(p_is_active, true),
      p_actor_id,
      p_actor_id
    )
    returning * into v_task;
    perform public.insert_status_log(
      'timeline_task',
      v_task.id,
      v_task.project_id,
      null,
      null,
      'Timeline task created',
      jsonb_build_object('task_name', v_task.name, 'status', v_task.status::text),
      p_actor_id
    );
  end if;
  return v_task;
end $$;

create or replace function public.deactivate_timeline_task(
  p_id uuid,
  p_actor_id uuid,
  p_message text default null
) returns public.timeline_tasks
language plpgsql
security definer
set search_path = public
as $$
declare
  v_task public.timeline_tasks;
begin
  perform public.assert_actor_exists(p_actor_id);
  update public.timeline_tasks
  set is_active = false,
      updated_by = p_actor_id,
      updated_at = now()
  where id = p_id
  returning * into v_task;
  if not found then
    raise exception 'Timeline task % not found', p_id;
  end if;
  perform public.insert_status_log(
    'timeline_task',
    v_task.id,
    v_task.project_id,
    null,
    null,
    coalesce(p_message, 'Timeline task deactivated'),
    jsonb_build_object('task_name', v_task.name),
    p_actor_id
  );
  return v_task;
end $$;

-- -------------------------------
-- 8) RLS: enable + read policies
-- -------------------------------
alter table public.projects enable row level security;
alter table public.project_kickoff enable row level security;
alter table public.sov_items enable row level security;
alter table public.timeline_tasks enable row level security;
alter table public.status_logs enable row level security;
alter table public.profiles enable row level security;

-- Read for authenticated
drop policy if exists projects_read on public.projects;
create policy projects_read
on public.projects
for select
to authenticated
using (true);

drop policy if exists kickoff_read on public.project_kickoff;
create policy kickoff_read
on public.project_kickoff
for select
to authenticated
using (true);

drop policy if exists sov_read on public.sov_items;
create policy sov_read
on public.sov_items
for select
to authenticated
using (true);

drop policy if exists timeline_read on public.timeline_tasks;
create policy timeline_read
on public.timeline_tasks
for select
to authenticated
using (true);

drop policy if exists status_logs_read on public.status_logs;
create policy status_logs_read
on public.status_logs
for select
to authenticated
using (true);

drop policy if exists profiles_read on public.profiles;
create policy profiles_read
on public.profiles
for select
to authenticated
using (true);

-- Explicit deny direct writes
drop policy if exists projects_no_write on public.projects;
create policy projects_no_write
on public.projects
for all
to authenticated
using (false)
with check (false);

drop policy if exists kickoff_no_write on public.project_kickoff;
create policy kickoff_no_write
on public.project_kickoff
for all
to authenticated
using (false)
with check (false);

drop policy if exists sov_no_write on public.sov_items;
create policy sov_no_write
on public.sov_items
for all
to authenticated
using (false)
with check (false);

drop policy if exists timeline_no_write on public.timeline_tasks;
create policy timeline_no_write
on public.timeline_tasks
for all
to authenticated
using (false)
with check (false);

drop policy if exists status_logs_no_write on public.status_logs;
create policy status_logs_no_write
on public.status_logs
for all
to authenticated
using (false)
with check (false);

drop policy if exists profiles_no_write on public.profiles;
create policy profiles_no_write
on public.profiles
for all
to authenticated
using (false)
with check (false);

-- Revoke direct writes at privilege level too
revoke insert, update, delete on public.projects from authenticated, anon;
revoke insert, update, delete on public.project_kickoff from authenticated, anon;
revoke insert, update, delete on public.sov_items from authenticated, anon;
revoke insert, update, delete on public.timeline_tasks from authenticated, anon;
revoke insert, update, delete on public.status_logs from authenticated, anon;
revoke update on public.profiles from authenticated, anon;

-- Allow executing RPCs
grant execute on function public.set_user_role(uuid, text, uuid, text) to authenticated;
grant execute on function public.create_project(
  text, text, uuid, text, text, text, text, text, text, text,
  numeric, date, date, uuid, uuid
) to authenticated;
grant execute on function public.update_project_core(
  uuid, uuid, text, text, text, text, text, text, text, text, uuid, uuid
) to authenticated;
grant execute on function public.update_project_status(uuid, project_status, uuid, text, jsonb) to authenticated;
grant execute on function public.set_current_kickoff(uuid, uuid, uuid, text) to authenticated;
grant execute on function public.create_kickoff_baseline(
  uuid, uuid, numeric, date, date, billing_type, numeric, text, text, text, text, jsonb, boolean
) to authenticated;
grant execute on function public.upsert_sov_item(uuid, uuid, uuid, text, text, numeric, integer, boolean) to authenticated;
grant execute on function public.deactivate_sov_item(uuid, uuid, text) to authenticated;
grant execute on function public.upsert_timeline_task(
  uuid, uuid, uuid, text, text, text, timeline_task_status, date, date, uuid, integer, boolean
) to authenticated;
grant execute on function public.deactivate_timeline_task(uuid, uuid, text) to authenticated;

-- =========================================================
-- End 0002
-- =========================================================
