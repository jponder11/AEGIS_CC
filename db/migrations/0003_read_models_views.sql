-- =========================================================
-- AEGIS_CC • Migration 0003 • Read Models and Views (Phase 3)
-- Purpose:
--   - Read-only views for dashboards and timelines
--   - Zero write paths introduced
-- =========================================================

-- -------------------------------
-- Helper: task progress mapping
-- -------------------------------
create or replace view public.v_timeline_task_progress as
select
  t.id as task_id,
  t.project_id,
  t.status::text as status,
  case
    when t.status::text in ('complete', 'completed', 'done') then 100
    when t.status::text in ('in_progress', 'active') then 50
    when t.status::text in ('blocked', 'on_hold') then 25
    else 0
  end as progress_pct
from public.timeline_tasks t
where coalesce(t.is_active, true) = true;

-- -------------------------------
-- 1) SOV Summary by project
-- -------------------------------
create or replace view public.v_project_sov_summary as
select
  s.project_id,
  count(*) filter (where coalesce(s.is_active, true) = true) as sov_item_count_active,
  coalesce(sum(s.scheduled_value) filter (where coalesce(s.is_active, true) = true), 0) as sov_scheduled_total
from public.sov_items s
group by s.project_id;

-- -------------------------------
-- 2) Timeline Summary by project
-- -------------------------------
create or replace view public.v_project_timeline_summary as
select
  t.project_id,
  min(t.start_date) filter (where coalesce(t.is_active, true) = true) as timeline_start_min,
  max(t.end_date) filter (where coalesce(t.is_active, true) = true) as timeline_end_max,
  count(*) filter (where coalesce(t.is_active, true) = true) as task_count_active,

  count(*) filter (
    where coalesce(t.is_active, true) = true
      and t.status::text in ('not_started')
  ) as task_count_not_started,

  count(*) filter (
    where coalesce(t.is_active, true) = true
      and t.status::text in ('in_progress', 'active')
  ) as task_count_in_progress,

  count(*) filter (
    where coalesce(t.is_active, true) = true
      and t.status::text in ('blocked', 'on_hold')
  ) as task_count_blocked,

  count(*) filter (
    where coalesce(t.is_active, true) = true
      and t.status::text in ('complete', 'completed', 'done')
  ) as task_count_complete

from public.timeline_tasks t
group by t.project_id;

-- -------------------------------
-- 3) Project Dashboard (single row per project)
-- -------------------------------
create or replace view public.v_project_dashboard as
select
  p.id as project_id,
  p.project_code,
  p.name as project_name,
  p.status::text as project_status,

  p.client_name,
  p.gc_name,

  p.site_address1,
  p.site_address2,
  p.site_city,
  p.site_state,
  p.site_zip,

  p.contract_value,
  p.start_date,
  p.end_date,

  p.pm_user_id,
  pm.full_name as pm_name,
  p.super_user_id,
  su.full_name as super_name,

  p.kickoff_current_id,
  kc.baseline_version as kickoff_baseline_version,
  kc.baseline_date as kickoff_baseline_date,
  kc.contract_value_baseline,
  kc.start_date_baseline,
  kc.end_date_baseline,
  kc.billing_type,
  kc.retainage_pct,

  coalesce(sov.sov_item_count_active, 0) as sov_item_count_active,
  coalesce(sov.sov_scheduled_total, 0) as sov_scheduled_total,

  tl.timeline_start_min,
  tl.timeline_end_max,
  coalesce(tl.task_count_active, 0) as task_count_active,
  coalesce(tl.task_count_not_started, 0) as task_count_not_started,
  coalesce(tl.task_count_in_progress, 0) as task_count_in_progress,
  coalesce(tl.task_count_blocked, 0) as task_count_blocked,
  coalesce(tl.task_count_complete, 0) as task_count_complete,

  p.created_at,
  p.updated_at

from public.projects p
left join public.project_kickoff kc
  on kc.id = p.kickoff_current_id
left join public.profiles pm
  on pm.id = p.pm_user_id
left join public.profiles su
  on su.id = p.super_user_id
left join public.v_project_sov_summary sov
  on sov.project_id = p.id
left join public.v_project_timeline_summary tl
  on tl.project_id = p.id;

-- -------------------------------
-- 4) Project Timeline Gantt (task rows, UI ready)
-- -------------------------------
create or replace view public.v_project_timeline_gantt as
select
  p.id as project_id,
  p.project_code,
  p.name as project_name,
  p.status::text as project_status,

  t.id as task_id,
  t.phase,
  t.scope,
  t.name as task_name,
  t.status::text as task_status,

  t.start_date,
  t.end_date,
  case
    when t.start_date is not null and t.end_date is not null
      then (t.end_date - t.start_date)
    else null
  end as duration_days,

  t.owner_user_id,
  o.full_name as owner_name,

  pr.progress_pct,

  t.sort_order,
  t.is_active,

  t.created_at,
  t.updated_at

from public.timeline_tasks t
join public.projects p
  on p.id = t.project_id
left join public.profiles o
  on o.id = t.owner_user_id
left join public.v_timeline_task_progress pr
  on pr.task_id = t.id
where coalesce(t.is_active, true) = true;

-- -------------------------------
-- 5) Aegis Master Timeline (all projects, all tasks)
-- -------------------------------
create or replace view public.v_aegis_master_timeline as
select
  g.project_id,
  g.project_code,
  g.project_name,
  g.project_status,

  g.task_id,
  g.phase,
  g.scope,
  g.task_name,
  g.task_status,

  g.start_date,
  g.end_date,
  g.duration_days,
  g.progress_pct,

  g.owner_user_id,
  g.owner_name,

  g.sort_order,
  g.created_at,
  g.updated_at
from public.v_project_timeline_gantt g;

-- -------------------------------
-- 6) Project Activity Feed (status logs enriched)
-- -------------------------------
create or replace view public.v_project_activity_feed as
select
  l.id as log_id,
  l.project_id,
  p.project_code,
  p.name as project_name,

  l.entity_type,
  l.entity_id,
  l.from_status,
  l.to_status,
  l.message,
  l.metadata,

  l.created_by,
  u.full_name as created_by_name,
  u.email as created_by_email,

  l.created_at
from public.status_logs l
left join public.projects p
  on p.id = l.project_id
left join public.profiles u
  on u.id = l.created_by;

-- =========================================================
-- End 0003
-- =========================================================
