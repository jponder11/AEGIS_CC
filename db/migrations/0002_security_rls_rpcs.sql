-- =========================================================
-- AEGIS_CC • Add updated_by + make audit actor accurate
-- Adds updated_by to key tables and upgrades the updated_at trigger
-- so it also stamps updated_by using:
--   1) auth.uid() (when running under Supabase auth context)
--   2) NEW.updated_by (if your app sets it explicitly)
--   3) OLD.updated_by (fallback)
-- =========================================================

-- 1) Helper: get actor from Supabase auth (best effort)
--    Works in Supabase Postgres where auth.uid() is available.
create or replace function public.current_actor_id()
returns uuid
language plpgsql
stable
as $$
declare
  v_actor uuid;
begin
  begin
    -- Supabase: auth.uid() returns the current user id when using RLS/auth context
    v_actor := auth.uid();
  exception when others then
    v_actor := null;
  end;

  return v_actor;
end $$;

-- 2) Replace updated_at trigger helper to also set updated_by
create or replace function public.set_updated_at_and_by()
returns trigger
language plpgsql
as $$
declare
  v_actor uuid;
begin
  new.updated_at := now();

  -- Prefer Supabase auth context, otherwise allow app-supplied updated_by
  v_actor := public.current_actor_id();

  if v_actor is not null then
    new.updated_by := v_actor;
  else
    -- if app explicitly set updated_by, keep it; otherwise preserve old value
    new.updated_by := coalesce(new.updated_by, old.updated_by);
  end if;

  return new;
end $$;

-- =========================================================
-- 3) Add updated_by columns
-- =========================================================

-- projects
alter table public.projects
  add column if not exists updated_by uuid references public.profiles(id) on delete set null;

-- profiles (optional but useful)
alter table public.profiles
  add column if not exists updated_by uuid references public.profiles(id) on delete set null;

-- project_kickoff (optional: it is insert-heavy, but updated_by is still helpful if edited)
alter table public.project_kickoff
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists updated_by uuid references public.profiles(id) on delete set null;

-- sov_items
alter table public.sov_items
  add column if not exists updated_by uuid references public.profiles(id) on delete set null;

-- timeline_tasks
alter table public.timeline_tasks
  add column if not exists updated_by uuid references public.profiles(id) on delete set null;

-- =========================================================
-- 4) Swap triggers to use the new function
-- =========================================================

-- profiles
drop trigger if exists trg_profiles_updated_at on public.profiles;
create trigger trg_profiles_updated_at
before update on public.profiles
for each row execute function public.set_updated_at_and_by();

-- projects
drop trigger if exists trg_projects_updated_at on public.projects;
create trigger trg_projects_updated_at
before update on public.projects
for each row execute function public.set_updated_at_and_by();

-- project_kickoff (only if you plan to edit kickoff rows)
drop trigger if exists trg_kickoff_updated_at on public.project_kickoff;
create trigger trg_kickoff_updated_at
before update on public.project_kickoff
for each row execute function public.set_updated_at_and_by();

-- sov_items
drop trigger if exists trg_sov_updated_at on public.sov_items;
create trigger trg_sov_updated_at
before update on public.sov_items
for each row execute function public.set_updated_at_and_by();

-- timeline_tasks
drop trigger if exists trg_timeline_updated_at on public.timeline_tasks;
create trigger trg_timeline_updated_at
before update on public.timeline_tasks
for each row execute function public.set_updated_at_and_by();

-- =========================================================
-- 5) Update status log triggers to use updated_by (accurate actor)
-- =========================================================

create or replace function public.log_project_status_change()
returns trigger language plpgsql as $$
declare
  actor uuid;
begin
  if (new.status is distinct from old.status) then
    actor := coalesce(
      new.updated_by,
      public.current_actor_id(),
      old.updated_by,
      new.created_by,
      old.created_by
    );

    perform public.insert_status_log(
      'project',
      new.id,
      new.id,
      old.status::text,
      new.status::text,
      'Project status changed',
      jsonb_build_object(
        'project_code', new.project_code,
        'project_name', new.name
      ),
      actor
    );
  end if;

  return new;
end $$;

drop trigger if exists trg_projects_status_log on public.projects;
create trigger trg_projects_status_log
after update of status on public.projects
for each row execute function public.log_project_status_change();

create or replace function public.log_timeline_task_status_change()
returns trigger language plpgsql as $$
declare
  actor uuid;
begin
  if (new.status is distinct from old.status) then
    actor := coalesce(
      new.updated_by,
      public.current_actor_id(),
      old.updated_by,
      new.created_by,
      old.created_by
    );

    perform public.insert_status_log(
      'timeline_task',
      new.id,
      new.project_id,
      old.status::text,
      new.status::text,
      'Timeline task status changed',
      jsonb_build_object(
        'task_name', new.name,
        'phase', new.phase,
        'scope', new.scope
      ),
      actor
    );
  end if;

  return new;
end $$;

drop trigger if exists trg_timeline_tasks_status_log on public.timeline_tasks;
create trigger trg_timeline_tasks_status_log
after update of status on public.timeline_tasks
for each row execute function public.log_timeline_task_status_change();

-- =========================================================
-- NOTE:
-- If your app uses a service role (no auth.uid context), you should
-- explicitly set updated_by in your UPDATE statements, and the trigger
-- will preserve it.
-- =========================================================

-- =========================================================
-- AEGIS_CC • Stored Procedures (explicit actor, no UI discipline required)
-- Pattern:
--   - App calls RPC with actor_id
--   - Function updates row, stamps updated_by, and logs to status_logs
-- Notes:
--   - These functions are designed to be the "blessed path" for state changes
--   - You can keep direct UPDATEs for admin/service use, but prefer these for app workflow
-- =========================================================

-- -------------------------------
-- Utility: ensure actor exists (optional hard guard)
-- -------------------------------
create or replace function public.assert_actor_exists(p_actor_id uuid)
returns void language plpgsql as $$
begin
  if p_actor_id is null then
    raise exception 'actor_id is required';
  end if;

  if not exists (select 1 from public.profiles where id = p_actor_id) then
    raise exception 'actor_id % does not exist in profiles', p_actor_id;
  end if;
end $$;

-- -------------------------------
-- PROJECT: update status (and optionally dates/contract)
-- -------------------------------
create or replace function public.update_project_status(
  p_project_id uuid,
  p_new_status project_status,
  p_actor_id uuid,
  p_message text default null,
  p_metadata jsonb default '{}'::jsonb
) returns public.projects
language plpgsql
as $$
declare
  v_old public.projects;
  v_new public.projects;
begin
  perform public.assert_actor_exists(p_actor_id);

  select * into v_old
  from public.projects
  where id = p_project_id
  for update;

  if not found then
    raise exception 'Project % not found', p_project_id;
  end if;

  if v_old.status = p_new_status then
    -- no-op, return current
    return v_old;
  end if;

  update public.projects
  set status = p_new_status,
      updated_by = p_actor_id,
      updated_at = now()
  where id = p_project_id
  returning * into v_new;

  -- Append-only audit log (explicit actor + optional message/metadata)
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

-- -------------------------------
-- PROJECT: set current kickoff baseline pointer (safe)
-- -------------------------------
create or replace function public.set_current_kickoff(
  p_project_id uuid,
  p_kickoff_id uuid,
  p_actor_id uuid,
  p_message text default null
) returns public.projects
language plpgsql
as $$
declare
  v_proj public.projects;
begin
  perform public.assert_actor_exists(p_actor_id);

  -- validate kickoff belongs to project
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

-- -------------------------------
-- TIMELINE TASK: update status
-- -------------------------------
create or replace function public.update_timeline_task_status(
  p_task_id uuid,
  p_new_status timeline_task_status,
  p_actor_id uuid,
  p_message text default null,
  p_metadata jsonb default '{}'::jsonb
) returns public.timeline_tasks
language plpgsql
as $$
declare
  v_old public.timeline_tasks;
  v_new public.timeline_tasks;
begin
  perform public.assert_actor_exists(p_actor_id);

  select * into v_old
  from public.timeline_tasks
  where id = p_task_id
  for update;

  if not found then
    raise exception 'Timeline task % not found', p_task_id;
  end if;

  if v_old.status = p_new_status then
    return v_old;
  end if;

  update public.timeline_tasks
  set status = p_new_status,
      updated_by = p_actor_id,
      updated_at = now()
  where id = p_task_id
  returning * into v_new;

  perform public.insert_status_log(
    'timeline_task',
    v_new.id,
    v_new.project_id,
    v_old.status::text,
    v_new.status::text,
    coalesce(p_message, 'Timeline task status changed'),
    coalesce(p_metadata, '{}'::jsonb),
    p_actor_id
  );

  return v_new;
end $$;

-- -------------------------------
-- OPTIONAL: update project dates (logs an event)
-- -------------------------------
create or replace function public.update_project_dates(
  p_project_id uuid,
  p_start_date date,
  p_end_date date,
  p_actor_id uuid,
  p_message text default null
) returns public.projects
language plpgsql
as $$
declare
  v_old public.projects;
  v_new public.projects;
begin
  perform public.assert_actor_exists(p_actor_id);

  select * into v_old
  from public.projects
  where id = p_project_id
  for update;

  if not found then
    raise exception 'Project % not found', p_project_id;
  end if;

  update public.projects
  set start_date = p_start_date,
      end_date = p_end_date,
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
    coalesce(p_message, 'Project dates updated'),
    jsonb_build_object(
      'from_start_date', v_old.start_date,
      'to_start_date', v_new.start_date,
      'from_end_date', v_old.end_date,
      'to_end_date', v_new.end_date
    ),
    p_actor_id
  );

  return v_new;
end $$;

-- -------------------------------
-- OPTIONAL: update contract value (logs an event)
-- -------------------------------
create or replace function public.update_project_contract_value(
  p_project_id uuid,
  p_contract_value numeric,
  p_actor_id uuid,
  p_message text default null
) returns public.projects
language plpgsql
as $$
declare
  v_old public.projects;
  v_new public.projects;
begin
  perform public.assert_actor_exists(p_actor_id);

  select * into v_old
  from public.projects
  where id = p_project_id
  for update;

  if not found then
    raise exception 'Project % not found', p_project_id;
  end if;

  update public.projects
  set contract_value = p_contract_value,
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
    coalesce(p_message, 'Project contract value updated'),
    jsonb_build_object(
      'from_contract_value', v_old.contract_value,
      'to_contract_value', v_new.contract_value
    ),
    p_actor_id
  );

  return v_new;
end $$;

-- =========================================================
-- Suggested usage:
--   select * from public.update_project_status('<project_uuid>', 'active', '<actor_uuid>', 'Kickoff complete');
--   select * from public.update_timeline_task_status('<task_uuid>', 'in_progress', '<actor_uuid>');
-- =========================================================

-- IMPORTANT: make the RPCs run with elevated privileges
-- Also lock the search_path for safety.

alter function public.update_project_status(uuid, project_status, uuid, text, jsonb)
  security definer
  set search_path = public;

alter function public.set_current_kickoff(uuid, uuid, uuid, text)
  security definer
  set search_path = public;

alter function public.update_timeline_task_status(uuid, timeline_task_status, uuid, text, jsonb)
  security definer
  set search_path = public;

alter function public.update_project_dates(uuid, date, date, uuid, text)
  security definer
  set search_path = public;

alter function public.update_project_contract_value(uuid, numeric, uuid, text)
  security definer
  set search_path = public;

alter table public.projects enable row level security;
alter table public.project_kickoff enable row level security;
alter table public.sov_items enable row level security;
alter table public.timeline_tasks enable row level security;
alter table public.status_logs enable row level security;
alter table public.profiles enable row level security;

-- PROJECTS: read for authenticated
drop policy if exists "projects_read" on public.projects;
create policy "projects_read"
on public.projects
for select
to authenticated
using (true);

-- KICKOFF: read for authenticated
drop policy if exists "kickoff_read" on public.project_kickoff;
create policy "kickoff_read"
on public.project_kickoff
for select
to authenticated
using (true);

-- SOV: read for authenticated
drop policy if exists "sov_read" on public.sov_items;
create policy "sov_read"
on public.sov_items
for select
to authenticated
using (true);

-- TIMELINE: read for authenticated
drop policy if exists "timeline_read" on public.timeline_tasks;
create policy "timeline_read"
on public.timeline_tasks
for select
to authenticated
using (true);

-- STATUS LOGS: read for authenticated
drop policy if exists "status_logs_read" on public.status_logs;
create policy "status_logs_read"
on public.status_logs
for select
to authenticated
using (true);

-- PROFILES: read for authenticated (common for assigning PM/Super/Owner)
drop policy if exists "profiles_read" on public.profiles;
create policy "profiles_read"
on public.profiles
for select
to authenticated
using (true);

-- PROJECTS: deny direct writes
drop policy if exists "projects_no_write" on public.projects;
create policy "projects_no_write"
on public.projects
for all
to authenticated
using (false)
with check (false);

-- KICKOFF: deny direct writes
drop policy if exists "kickoff_no_write" on public.project_kickoff;
create policy "kickoff_no_write"
on public.project_kickoff
for all
to authenticated
using (false)
with check (false);

-- SOV: deny direct writes
drop policy if exists "sov_no_write" on public.sov_items;
create policy "sov_no_write"
on public.sov_items
for all
to authenticated
using (false)
with check (false);

-- TIMELINE: deny direct writes
drop policy if exists "timeline_no_write" on public.timeline_tasks;
create policy "timeline_no_write"
on public.timeline_tasks
for all
to authenticated
using (false)
with check (false);

-- STATUS LOGS: deny direct writes (append-only by functions/triggers)
drop policy if exists "status_logs_no_write" on public.status_logs;
create policy "status_logs_no_write"
on public.status_logs
for all
to authenticated
using (false)
with check (false);

grant execute on function public.update_project_status(uuid, project_status, uuid, text, jsonb) to authenticated;
grant execute on function public.set_current_kickoff(uuid, uuid, uuid, text) to authenticated;
grant execute on function public.update_timeline_task_status(uuid, timeline_task_status, uuid, text, jsonb) to authenticated;
grant execute on function public.update_project_dates(uuid, date, date, uuid, text) to authenticated;
grant execute on function public.update_project_contract_value(uuid, numeric, uuid, text) to authenticated;

-- =========================================================
-- AEGIS_CC • Phase 1 CRUD RPCs (explicit actor, RLS-safe)
-- Adds "blessed path" functions so the app never writes tables directly:
--   1) create_project
--   2) update_project_core
--   3) create_kickoff_baseline (versioned)
--   4) upsert_sov_item + deactivate_sov_item
--   5) upsert_timeline_task + deactivate_timeline_task
-- All functions:
--   - require actor_id
--   - stamp updated_by/updated_at
--   - write status_logs where meaningful
--   - run SECURITY DEFINER (privileged, bypasses RLS)
-- =========================================================

-- ---------------------------------------------------------
-- 0) Safety: ensure core helper exists (from earlier block)
--   - assert_actor_exists(actor_id)
--   - insert_status_log(...)
-- ---------------------------------------------------------

-- ---------------------------------------------------------
-- 1) CREATE PROJECT
-- ---------------------------------------------------------
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

grant execute on function public.create_project(
  text, text, uuid, text, text, text, text, text, text, text,
  numeric, date, date, uuid, uuid
) to authenticated;

-- ---------------------------------------------------------
-- 2) UPDATE PROJECT CORE (identity/current truth, not status)
-- ---------------------------------------------------------
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
  v_meta jsonb;
begin
  perform public.assert_actor_exists(p_actor_id);

  select * into v_old
  from public.projects
  where id = p_project_id
  for update;

  if not found then
    raise exception 'Project % not found', p_project_id;
  end if;

  update public.projects
  set
    name = coalesce(p_name, name),
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

  v_meta := jsonb_build_object(
    'from', jsonb_build_object(
      'name', v_old.name,
      'client_name', v_old.client_name,
      'gc_name', v_old.gc_name,
      'site_city', v_old.site_city,
      'site_state', v_old.site_state,
      'pm_user_id', v_old.pm_user_id,
      'super_user_id', v_old.super_user_id
    ),
    'to', jsonb_build_object(
      'name', v_new.name,
      'client_name', v_new.client_name,
      'gc_name', v_new.gc_name,
      'site_city', v_new.site_city,
      'site_state', v_new.site_state,
      'pm_user_id', v_new.pm_user_id,
      'super_user_id', v_new.super_user_id
    )
  );

  perform public.insert_status_log(
    'project',
    v_new.id,
    v_new.id,
    null,
    null,
    'Project core updated',
    v_meta,
    p_actor_id
  );

  return v_new;
end $$;

grant execute on function public.update_project_core(
  uuid, uuid, text, text, text, text, text, text, text, text, uuid, uuid
) to authenticated;

-- ---------------------------------------------------------
-- 3) CREATE KICKOFF BASELINE (versioned, sets current pointer)
-- ---------------------------------------------------------
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

  select * into v_proj
  from public.projects
  where id = p_project_id
  for update;

  if not found then
    raise exception 'Project % not found', p_project_id;
  end if;

  insert into public.project_kickoff (
    project_id,
    baseline_version, -- trigger assigns if null
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
    jsonb_build_object(
      'baseline_version', v_kick.baseline_version,
      'contract_value_baseline', v_kick.contract_value_baseline,
      'start_date_baseline', v_kick.start_date_baseline,
      'end_date_baseline', v_kick.end_date_baseline
    ),
    p_actor_id
  );

  return v_kick;
end $$;

grant execute on function public.create_kickoff_baseline(
  uuid, uuid, numeric, date, date, billing_type, numeric, text, text, text, text, jsonb, boolean
) to authenticated;

-- ---------------------------------------------------------
-- 4) UPSERT SOV ITEM (create/update) + soft delete
-- ---------------------------------------------------------
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
    select true into v_exists
    from public.sov_items
    where id = p_id and project_id = p_project_id;
  end if;

  if v_exists then
    update public.sov_items
    set
      code = p_code,
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
      project_id, code, description, scheduled_value, sort_order, is_active, created_by, updated_by
    ) values (
      p_project_id, p_code, p_description, coalesce(p_scheduled_value, 0), coalesce(p_sort_order, 0),
      coalesce(p_is_active, true), p_actor_id, p_actor_id
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

grant execute on function public.upsert_sov_item(
  uuid, uuid, uuid, text, text, numeric, integer, boolean
) to authenticated;

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

grant execute on function public.deactivate_sov_item(uuid, uuid, text) to authenticated;

-- ---------------------------------------------------------
-- 5) UPSERT TIMELINE TASK (create/update) + soft delete
-- ---------------------------------------------------------
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
    select true into v_exists
    from public.timeline_tasks
    where id = p_id and project_id = p_project_id;
  end if;

  if v_exists then
    update public.timeline_tasks
    set
      phase = p_phase,
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
      project_id, phase, scope, name, status, start_date, end_date,
      owner_user_id, sort_order, is_active, created_by, updated_by
    ) values (
      p_project_id, p_phase, p_scope, p_name, coalesce(p_status,'not_started'),
      p_start_date, p_end_date, p_owner_user_id,
      coalesce(p_sort_order, 0), coalesce(p_is_active, true),
      p_actor_id, p_actor_id
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

grant execute on function public.upsert_timeline_task(
  uuid, uuid, uuid, text, text, text, timeline_task_status, date, date, uuid, integer, boolean
) to authenticated;

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

grant execute on function public.deactivate_timeline_task(uuid, uuid, text) to authenticated;

-- =========================================================
-- OPTIONAL: Lock down direct table writes harder (recommended)
-- Revoke table privileges from authenticated/anon so only RPCs are used.
-- (Supabase typically uses RLS, but explicit revokes reduce confusion.)
-- =========================================================
revoke insert, update, delete on public.projects from authenticated, anon;
revoke insert, update, delete on public.project_kickoff from authenticated, anon;
revoke insert, update, delete on public.sov_items from authenticated, anon;
revoke insert, update, delete on public.timeline_tasks from authenticated, anon;
revoke insert, update, delete on public.status_logs from authenticated, anon;

-- Keep SELECT allowed (RLS policies already grant select to authenticated)

-- =========================================================
-- AEGIS_CC • No-Duplicate Logging Patch
-- Chosen approach: ONLY log status changes through RPC functions.
-- Action:
--   - Drop table-level status-change triggers on:
--       public.projects.status
--       public.timeline_tasks.status
--   - Drop their trigger functions
-- Keep:
--   - public.insert_status_log(...) helper (still used by RPCs)
-- =========================================================

-- Drop triggers (safe if they don't exist)
drop trigger if exists trg_projects_status_log on public.projects;
drop trigger if exists trg_timeline_tasks_status_log on public.timeline_tasks;

-- Drop trigger functions (safe if they don't exist)
drop function if exists public.log_project_status_change();
drop function if exists public.log_timeline_task_status_change();

-- NOTE:
-- Do NOT drop public.insert_status_log(...) because the RPCs call it.
-- Do NOT drop your update_project_status(...) / update_timeline_task_status(...) RPCs.

-- =========================================================
-- AEGIS_CC • Auto-create Profiles on Signup (Supabase)
-- Creates a public.profiles row whenever a new auth.users row is created.
-- Also keeps email and name in sync on auth user updates (optional but useful).
--
-- Assumptions:
--  - public.profiles.id = auth.users.id (uuid)
--  - public.profiles has: id, full_name, email, role, is_active, created_at, updated_at
-- =========================================================

-- 1) Create profile on user signup
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

-- 2) OPTIONAL: keep profile in sync when auth.users is updated
--    (email changes, metadata name changes)
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

-- =========================================================
-- 3) RLS for profiles: users can read all profiles (already set earlier),
--    but should only update their own profile if you ever allow it.
--    (If you prefer profiles to be admin-managed only, skip this.)
-- =========================================================
alter table public.profiles enable row level security;

drop policy if exists "profiles_read" on public.profiles;
create policy "profiles_read"
on public.profiles
for select
to authenticated
using (true);

drop policy if exists profiles_self_insert on public.profiles;
create policy profiles_self_insert
on public.profiles
for insert
to authenticated
with check (id = auth.uid());

-- Optional self-update policy (commented out by default)
-- drop policy if exists "profiles_self_update" on public.profiles;
-- create policy "profiles_self_update"
-- on public.profiles
-- for update
-- to authenticated
-- using (id = auth.uid())
-- with check (id = auth.uid());

-- =========================================================
-- AEGIS_CC • Simple Text Roles (PoC)
-- Goals:
--  - Keep roles as simple text in public.profiles.role
--  - Enforce allowed values with a CHECK constraint
--  - Provide helper functions for role checks
--  - Add a safe admin-only RPC to set roles
-- =========================================================

-- 1) Enforce allowed roles (edit list anytime via migration)
alter table public.profiles
  drop constraint if exists profiles_role_check;

alter table public.profiles
  add constraint profiles_role_check
  check (role in ('user','pm','super','ops','executive','accounting','shop','admin','commandant'));

-- 2) Helper: current user's role
create or replace function public.current_user_role()
returns text
language sql
stable
as $$
  select role
  from public.profiles
  where id = auth.uid();
$$;

-- 3) Helper: is admin or commandant
create or replace function public.is_admin()
returns boolean
language sql
stable
as $$
  select coalesce(public.current_user_role() in ('admin','commandant'), false);
$$;

-- 4) Admin-only RPC to set a user's role (explicit actor)
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
  -- actor must exist
  perform public.assert_actor_exists(p_actor_id);

  select role into v_actor_role
  from public.profiles
  where id = p_actor_id;

  if v_actor_role not in ('admin','commandant') then
    raise exception 'Only admin/commandant can set roles';
  end if;

  if p_new_role is null or btrim(p_new_role) = '' then
    raise exception 'new role is required';
  end if;

  -- enforce allowed values same as constraint
  if p_new_role not in ('user','pm','super','ops','executive','accounting','shop','admin','commandant') then
    raise exception 'Invalid role: %', p_new_role;
  end if;

  select * into v_old
  from public.profiles
  where id = p_target_user_id
  for update;

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

grant execute on function public.set_user_role(uuid, text, uuid, text) to authenticated;

-- 5) RLS: keep profiles update locked down (no direct updates)
--    Users can read all profiles (already allowed).
--    No update policy means direct updates are denied by RLS.
--    The admin-only RPC runs as SECURITY DEFINER and will work.

-- (Optional extra hardening)
revoke update on public.profiles from authenticated, anon;

-- =========================================================
-- AEGIS_CC • Bootstrap Script (PoC)
-- What it does:
--  1) Promotes a chosen email user to COMMANDANT (creates profile if missing)
--  2) Creates one demo project
--  3) Creates kickoff baseline (sets current)
--  4) Creates 6 SOV lines
--  5) Creates 10 timeline tasks
--
-- HOW TO USE:
--  - Replace p_commandant_email with YOUR login email
--  - Optionally adjust the demo project fields
--  - Run in Supabase SQL editor
-- =========================================================

do $$
declare
  p_commandant_email text := 'YOUR_EMAIL_HERE@example.com';

  v_actor_id uuid;
  v_project public.projects;
  v_kick public.project_kickoff;

  -- SOV and Task temp vars
  v_tmp uuid;
begin
  -- -------------------------------------------------------
  -- 1) Find auth user by email
  -- -------------------------------------------------------
  select id into v_actor_id
  from auth.users
  where lower(email) = lower(p_commandant_email)
  limit 1;

  if v_actor_id is null then
    raise exception 'No auth.users found for email % (sign up first, then re-run)', p_commandant_email;
  end if;

  -- Ensure profile exists (in case trigger wasn't present when user signed up)
  insert into public.profiles (id, full_name, email, role, is_active)
  values (v_actor_id, '', p_commandant_email, 'commandant', true)
  on conflict (id) do update
    set email = excluded.email,
        role = 'commandant',
        is_active = true;

  -- Optional: log bootstrap promotion
  perform public.insert_status_log(
    'bootstrap',
    v_actor_id,
    null,
    null,
    null,
    'Bootstrap: set commandant role',
    jsonb_build_object('email', p_commandant_email),
    v_actor_id
  );

  -- -------------------------------------------------------
  -- 2) Create demo project (via RPC so it matches your rules)
  -- -------------------------------------------------------
  v_project := public.create_project(
    'DEMO-001',
    'Demo Project • Aegis Proof of Concept',
    v_actor_id,
    'MG Electric (Internal Demo)',
    'Demo GC',
    '123 Demo St',
    null,
    'Lancaster',
    'CA',
    '93534',
    1250000,
    current_date,
    current_date + 120,
    v_actor_id,  -- PM
    v_actor_id   -- Super
  );

  -- -------------------------------------------------------
  -- 3) Create kickoff baseline (versioned) and set current
  -- -------------------------------------------------------
  v_kick := public.create_kickoff_baseline(
    v_project.id,
    v_actor_id,
    1250000,
    current_date,
    current_date + 120,
    'lump_sum',
    10.00,
    'Baseline schedule for PoC. Rough → Gear → Lighting → Inverter → Finish.',
    'PoC scope: demonstrate kickoff + SOV + timeline + audit.',
    'Excludes external integrations and advanced permissions.',
    'Assumes stable staffing and normal lead times for demo purposes.',
    jsonb_build_object('risk','low','notes','PoC dataset'),
    true
  );

  -- -------------------------------------------------------
  -- 4) Create SOV items (6 lines)
  -- -------------------------------------------------------
  perform public.upsert_sov_item(v_project.id, v_actor_id, null, '01-100', 'Mobilization / Startup',  50000,  10, true);
  perform public.upsert_sov_item(v_project.id, v_actor_id, null, '02-200', 'Underground / Rough',     350000, 20, true);
  perform public.upsert_sov_item(v_project.id, v_actor_id, null, '03-300', 'Switchgear / Gear',       300000, 30, true);
  perform public.upsert_sov_item(v_project.id, v_actor_id, null, '04-400', 'Lighting / Devices',      250000, 40, true);
  perform public.upsert_sov_item(v_project.id, v_actor_id, null, '05-500', 'Inverter / Controls',     200000, 50, true);
  perform public.upsert_sov_item(v_project.id, v_actor_id, null, '06-600', 'Finish / Closeout',       100000, 60, true);

  -- -------------------------------------------------------
  -- 5) Create Timeline tasks (10 tasks)
  -- -------------------------------------------------------
  perform public.upsert_timeline_task(v_project.id, v_actor_id, null, 'Kickoff',  'Admin', 'Kickoff Complete', 'complete',
    current_date, current_date, v_actor_id, 10, true);

  perform public.upsert_timeline_task(v_project.id, v_actor_id, null, 'Rough', 'UG', 'Underground trenching and sleeves', 'in_progress',
    current_date + 1, current_date + 14, v_actor_id, 20, true);

  perform public.upsert_timeline_task(v_project.id, v_actor_id, null, 'Rough', 'Rough-in', 'Rough-in conduit and boxes', 'not_started',
    current_date + 7, current_date + 28, v_actor_id, 30, true);

  perform public.upsert_timeline_task(v_project.id, v_actor_id, null, 'Gear', 'Electrical Room', 'Gear delivery and staging', 'not_started',
    current_date + 21, current_date + 35, v_actor_id, 40, true);

  perform public.upsert_timeline_task(v_project.id, v_actor_id, null, 'Gear', 'Electrical Room', 'Gear set and terminations', 'not_started',
    current_date + 30, current_date + 50, v_actor_id, 50, true);

  perform public.upsert_timeline_task(v_project.id, v_actor_id, null, 'Lighting', 'Buildings', 'Lighting rough & trims', 'not_started',
    current_date + 35, current_date + 80, v_actor_id, 60, true);

  perform public.upsert_timeline_task(v_project.id, v_actor_id, null, 'Inverter', 'Systems', 'Inverter install and commissioning', 'not_started',
    current_date + 60, current_date + 95, v_actor_id, 70, true);

  perform public.upsert_timeline_task(v_project.id, v_actor_id, null, 'Finish', 'Punch', 'Punchlist and corrective work', 'not_started',
    current_date + 85, current_date + 110, v_actor_id, 80, true);

  perform public.upsert_timeline_task(v_project.id, v_actor_id, null, 'Finish', 'Closeout', 'As-builts, O&M, turnover', 'not_started',
    current_date + 100, current_date + 120, v_actor_id, 90, true);

  perform public.upsert_timeline_task(v_project.id, v_actor_id, null, 'Admin', 'Finance', 'SOV loaded and validated', 'complete',
    current_date, current_date, v_actor_id, 100, true);

  -- -------------------------------------------------------
  -- Done: echo useful output
  -- -------------------------------------------------------
  raise notice 'Bootstrap complete. Actor=% Project=% KickoffBaselineVersion=%',
    v_actor_id, v_project.id, v_kick.baseline_version;

end $$;
