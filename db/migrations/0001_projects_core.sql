-- Phase 1: Projects Core (spine)
-- Postgres-compatible (Supabase-ready)

create extension if not exists "pgcrypto";

create table if not exists projects (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  description text,
  status text not null default 'draft',
  start_date date,
  target_end_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists project_kickoff (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references projects(id),
  kickoff_date date not null,
  kickoff_owner text,
  kickoff_notes text,
  created_at timestamptz not null default now()
);

create table if not exists sov_items (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references projects(id),
  line_number integer not null,
  title text not null,
  scope text,
  status text not null default 'planned',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (project_id, line_number)
);

create table if not exists timeline_tasks (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references projects(id),
  name text not null,
  description text,
  status text not null default 'planned',
  planned_start date,
  planned_end date,
  actual_start date,
  actual_end date,
  depends_on_task_id uuid references timeline_tasks(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Append-only status/state changes across core project entities.
create table if not exists status_logs (
  id uuid primary key default gen_random_uuid(),
  project_id uuid references projects(id),
  timeline_task_id uuid references timeline_tasks(id),
  sov_item_id uuid references sov_items(id),
  status_from text,
  status_to text not null,
  note text,
  actor_label text,
  created_at timestamptz not null default now(),
  check (
    (project_id is not null)::int +
    (timeline_task_id is not null)::int +
    (sov_item_id is not null)::int = 1
  )
);
