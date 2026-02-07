-- =========================================================
-- AEGIS_CC • Phase 1 Spine (Projects + Kickoff Baselines + SOV + Timeline)
-- Postgres / Supabase-ready SQL
-- Hybrid model:
--   - projects = current operational truth + identity
--   - project_kickoff = versioned baselines (kickoff packets)
--   - projects.kickoff_current_id points to the active baseline
-- Includes:
--   - append-only status_logs for audit trail
--   - triggers to auto-increment kickoff baseline_version per project
--   - optional helper function to set current kickoff safely
-- =========================================================

-- ---------- EXTENSIONS ----------
create extension if not exists pgcrypto;

-- ---------- ENUMS ----------
do $$
begin
  if not exists (select 1 from pg_type where typname = 'project_status') then
    create type project_status as enum ('prospect','active','closeout','closed','on_hold','cancelled');
  end if;

  if not exists (select 1 from pg_type where typname = 'timeline_task_status') then
    create type timeline_task_status as enum ('not_started','in_progress','blocked','complete','cancelled');
  end if;

  if not exists (select 1 from pg_type where typname = 'billing_type') then
    create type billing_type as enum ('lump_sum','time_and_material','gmp','unit_price','cost_plus');
  end if;
end $$;

-- =========================================================
-- USERS / PROFILES (roles)
-- =========================================================
create table if not exists public.profiles (
  id uuid primary key, -- typically auth.users.id
  full_name text,
  email text,
  role text not null default 'user', -- keep flexible; enforce via app or separate role tables later
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_profiles_role on public.profiles(role);

-- updated_at trigger helper
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists trg_profiles_updated_at on public.profiles;
create trigger trg_profiles_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

-- =========================================================
-- PROJECTS (current truth + identity)
-- =========================================================
create table if not exists public.projects (
  id uuid primary key default gen_random_uuid(),

  project_code text not null unique,     -- e.g. "VA408", "HILL_ST"
  name text not null,

  client_name text,
  gc_name text,

  site_address1 text,
  site_address2 text,
  site_city text,
  site_state text,
  site_zip text,

  status project_status not null default 'prospect',

  -- Current operational truth (these can change as the project evolves)
  contract_value numeric(14,2) not null default 0,
  start_date date,
  end_date date,

  pm_user_id uuid references public.profiles(id) on delete set null,
  super_user_id uuid references public.profiles(id) on delete set null,

  -- pointer to the active kickoff baseline
  kickoff_current_id uuid,

  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_projects_status on public.projects(status);
create index if not exists idx_projects_pm on public.projects(pm_user_id);
create index if not exists idx_projects_super on public.projects(super_user_id);

drop trigger if exists trg_projects_updated_at on public.projects;
create trigger trg_projects_updated_at
before update on public.projects
for each row execute function public.set_updated_at();

-- =========================================================
-- PROJECT KICKOFF (versioned baselines)
-- =========================================================
create table if not exists public.project_kickoff (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,

  -- Versioned baseline number per project (auto assigned by trigger)
  baseline_version integer not null,

  baseline_date date not null default current_date,

  -- Baseline values captured at kickoff (do not overwrite; create new version to re-baseline)
  contract_value_baseline numeric(14,2) not null default 0,
  start_date_baseline date,
  end_date_baseline date,

  billing_type billing_type,
  retainage_pct numeric(5,2) default 0,

  -- Narrative packet
  schedule_notes text,
  scope_notes text,
  exclusions text,
  assumptions text,

  -- structured flags (kept flexible early; can normalize later)
  risk_flags jsonb not null default '{}'::jsonb,

  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

-- Each project can only have one baseline_version of a given number
create unique index if not exists uq_kickoff_project_version
  on public.project_kickoff(project_id, baseline_version);

create index if not exists idx_kickoff_project on public.project_kickoff(project_id);
create index if not exists idx_kickoff_created_at on public.project_kickoff(created_at);

-- Add FK from projects.kickoff_current_id -> project_kickoff.id (after both exist)
do $$
begin
  if not exists (
    select 1
    from   pg_constraint
    where  conname = 'fk_projects_kickoff_current'
  ) then
    alter table public.projects
      add constraint fk_projects_kickoff_current
      foreign key (kickoff_current_id)
      references public.project_kickoff(id)
      on delete set null;
  end if;
end $$;

-- =========================================================
-- TRIGGER: auto-increment baseline_version per project
-- =========================================================
create or replace function public.assign_kickoff_baseline_version()
returns trigger language plpgsql as $$
declare
  next_version integer;
begin
  if new.baseline_version is not null then
    -- allow explicit version only if you really want it (not typical)
    return new;
  end if;

  select coalesce(max(baseline_version), 0) + 1
    into next_version
  from public.project_kickoff
  where project_id = new.project_id;

  new.baseline_version := next_version;
  return new;
end $$;

drop trigger if exists trg_kickoff_assign_version on public.project_kickoff;
create trigger trg_kickoff_assign_version
before insert on public.project_kickoff
for each row execute function public.assign_kickoff_baseline_version();

-- =========================================================
-- Helper function: set current kickoff pointer safely
-- Ensures kickoff belongs to project.
-- =========================================================
create or replace function public.set_project_current_kickoff(
  p_project_id uuid,
  p_kickoff_id uuid
) returns void language plpgsql as $$
declare
  belongs boolean;
begin
  select exists(
    select 1 from public.project_kickoff
    where id = p_kickoff_id and project_id = p_project_id
  ) into belongs;

  if not belongs then
    raise exception 'Kickoff % does not belong to project %', p_kickoff_id, p_project_id;
  end if;

  update public.projects
  set kickoff_current_id = p_kickoff_id
  where id = p_project_id;
end $$;

-- Optional trigger: if you insert a kickoff and project has no current kickoff, set it automatically
create or replace function public.auto_set_current_kickoff_if_null()
returns trigger language plpgsql as $$
begin
  update public.projects
  set kickoff_current_id = new.id
  where id = new.project_id
    and kickoff_current_id is null;

  return new;
end $$;

drop trigger if exists trg_kickoff_auto_set_current on public.project_kickoff;
create trigger trg_kickoff_auto_set_current
after insert on public.project_kickoff
for each row execute function public.auto_set_current_kickoff_if_null();

-- =========================================================
-- SOV ITEMS (line items)
-- =========================================================
create table if not exists public.sov_items (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,

  -- optional: tie to a baseline if you want SOV to be baseline-specific later
  -- kickoff_id uuid references public.project_kickoff(id) on delete set null,

  code text, -- e.g. "01-100"
  description text not null,

  scheduled_value numeric(14,2) not null default 0,

  sort_order integer not null default 0,
  is_active boolean not null default true,

  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_sov_project on public.sov_items(project_id);
create index if not exists idx_sov_active on public.sov_items(project_id, is_active);

drop trigger if exists trg_sov_updated_at on public.sov_items;
create trigger trg_sov_updated_at
before update on public.sov_items
for each row execute function public.set_updated_at();

-- =========================================================
-- TIMELINE TASKS (Gantt feed)
-- =========================================================
create table if not exists public.timeline_tasks (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,

  phase text, -- rough, gear, lighting, inverter, finishing, etc.
  scope text, -- optional: "Building 4 - trench", "Panel install", etc.
  name text not null,

  status timeline_task_status not null default 'not_started',

  start_date date,
  end_date date,

  owner_user_id uuid references public.profiles(id) on delete set null,

  sort_order integer not null default 0,
  is_active boolean not null default true,

  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_timeline_project on public.timeline_tasks(project_id);
create index if not exists idx_timeline_status on public.timeline_tasks(project_id, status);

drop trigger if exists trg_timeline_updated_at on public.timeline_tasks;
create trigger trg_timeline_updated_at
before update on public.timeline_tasks
for each row execute function public.set_updated_at();

-- =========================================================
-- STATUS LOGS (append-only audit trail)
-- Generic log that can capture status changes and key events.
-- =========================================================
create table if not exists public.status_logs (
  id uuid primary key default gen_random_uuid(),

  entity_type text not null, -- 'project','timeline_task','sov_item','kickoff', etc.
  entity_id uuid not null,

  project_id uuid references public.projects(id) on delete cascade, -- optional but useful for filtering
  from_status text,
  to_status text,

  message text,
  metadata jsonb not null default '{}'::jsonb,

  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists idx_status_logs_entity on public.status_logs(entity_type, entity_id);
create index if not exists idx_status_logs_project on public.status_logs(project_id, created_at);

-- =========================================================
-- OPTIONAL: Views for dashboard convenience (read-only)
-- =========================================================
create or replace view public.project_overview as
select
  p.id,
  p.project_code,
  p.name,
  p.status,
  p.contract_value,
  p.start_date,
  p.end_date,
  p.client_name,
  p.gc_name,
  p.site_city,
  p.site_state,
  p.pm_user_id,
  p.super_user_id,
  p.kickoff_current_id,
  k.baseline_version as kickoff_baseline_version,
  k.baseline_date as kickoff_baseline_date,
  k.contract_value_baseline,
  k.start_date_baseline,
  k.end_date_baseline,
  k.billing_type,
  k.retainage_pct
from public.projects p
left join public.project_kickoff k
  on k.id = p.kickoff_current_id;

-- =========================================================
-- NOTES:
-- - If you later want SOV baselined per kickoff version, add sov_items.kickoff_id
--   and enforce that it matches project_id via trigger.
-- - Same for timeline_tasks if you want baseline snapshots.
-- =========================================================
