-- =========================================================
-- AEGIS_CC • Migration 0009 • PR Workflow RPCs (Phase 9)
-- Purpose:
--   - PR numbering (PR-YYYY-####)
--   - PR lifecycle RPCs: create, update header, upsert line, submit, approve, reject
--   - Enforce $1,000 approval threshold via role gating
--   - Reset approval when PR changes after approval
--   - Log lifecycle + resets to status_logs
--   - Add updated_at/updated_by triggers for PR header + lines
-- =========================================================

-- -------------------------------
-- 0) Config
-- -------------------------------
create table if not exists public.app_config (
  key text primary key,
  value text not null
);

insert into public.app_config(key, value)
values ('PR_APPROVAL_THRESHOLD', '1000')
on conflict (key) do nothing;

create or replace function public.get_pr_approval_threshold()
returns numeric
language sql
stable
as $$
  select (value::numeric)
  from public.app_config
  where key = 'PR_APPROVAL_THRESHOLD';
$$;

-- -------------------------------
-- 1) PR numbering (per-year counter)
-- -------------------------------
create table if not exists public.pr_number_counters (
  year int primary key,
  last_seq int not null default 0,
  updated_at timestamptz not null default now()
);

create or replace function public.next_pr_number()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_year int := extract(year from now())::int;
  v_next int;
begin
  -- Lock the year row so increments are safe
  insert into public.pr_number_counters(year, last_seq)
  values (v_year, 0)
  on conflict (year) do nothing;

  update public.pr_number_counters
  set last_seq = last_seq + 1,
      updated_at = now()
  where year = v_year
  returning last_seq into v_next;

  return 'PR-' || v_year::text || '-' || lpad(v_next::text, 4, '0');
end;
$$;

-- -------------------------------
-- 2) Helpers: PR total + approver gates
-- -------------------------------
create or replace function public.pr_est_total(p_pr_id uuid)
returns numeric
language sql
stable
as $$
  select coalesce(sum(coalesce(est_ext_cost, 0)), 0)
  from public.purchase_request_lines
  where purchase_request_id = p_pr_id
    and is_active = true;
$$;

create or replace function public.can_approve_pr(p_actor_id uuid, p_pr_total numeric)
returns boolean
language plpgsql
stable
as $$
declare
  v_role text;
  v_threshold numeric := public.get_pr_approval_threshold();
begin
  select role into v_role
  from public.profiles
  where id = p_actor_id;

  if v_role is null then
    return false;
  end if;

  -- >= threshold: only executive/accounting/admin/commandant
  if coalesce(p_pr_total, 0) >= v_threshold then
    return v_role in ('executive','accounting','admin','commandant');
  end if;

  -- < threshold: ops also allowed
  return v_role in ('ops','executive','accounting','admin','commandant');
end;
$$;

-- -------------------------------
-- 3) Updated triggers for PR header + lines
-- -------------------------------
drop trigger if exists trg_purchase_requests_updated_at on public.purchase_requests;
create trigger trg_purchase_requests_updated_at
before update on public.purchase_requests
for each row execute function public.set_updated_at_and_by();

drop trigger if exists trg_purchase_request_lines_updated_at on public.purchase_request_lines;
create trigger trg_purchase_request_lines_updated_at
before update on public.purchase_request_lines
for each row execute function public.set_updated_at_and_by();

-- -------------------------------
-- 4) RPC: Create PR (draft)
-- -------------------------------
create or replace function public.create_purchase_request(
  p_project_id uuid,
  p_actor_id uuid,
  p_needed_by_date date default null,
  p_priority text default null,
  p_notes text default null
) returns public.purchase_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pr public.purchase_requests;
  v_pr_number text;
begin
  perform public.assert_actor_exists(p_actor_id);

  if p_project_id is null then
    raise exception 'project_id is required';
  end if;

  v_pr_number := public.next_pr_number();

  insert into public.purchase_requests (
    project_id,
    pr_number,
    status,
    needed_by_date,
    priority,
    requested_by,
    notes,
    created_by,
    updated_by
  ) values (
    p_project_id,
    v_pr_number,
    'draft',
    p_needed_by_date,
    p_priority,
    p_actor_id,
    p_notes,
    p_actor_id,
    p_actor_id
  )
  returning * into v_pr;

  perform public.insert_status_log(
    'purchase_request',
    v_pr.id,
    v_pr.project_id,
    null,
    v_pr.status::text,
    'PR created',
    jsonb_build_object('pr_number', v_pr.pr_number),
    p_actor_id
  );

  return v_pr;
end;
$$;

-- -------------------------------
-- 5) RPC: Update PR header
--      - Allowed on draft/submitted/approved
--      - If approved and changes occur, reset approval and set status to submitted
-- -------------------------------
create or replace function public.update_purchase_request_header(
  p_pr_id uuid,
  p_actor_id uuid,
  p_needed_by_date date default null,
  p_priority text default null,
  p_notes text default null
) returns public.purchase_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old public.purchase_requests;
  v_new public.purchase_requests;
  v_reset boolean := false;
  v_changed jsonb := '{}'::jsonb;
begin
  perform public.assert_actor_exists(p_actor_id);

  select * into v_old
  from public.purchase_requests
  where id = p_pr_id
  for update;

  if not found then
    raise exception 'PR % not found', p_pr_id;
  end if;

  if v_old.status not in ('draft','submitted','approved') then
    raise exception 'PR % cannot be edited in status %', p_pr_id, v_old.status;
  end if;

  if p_needed_by_date is not null and p_needed_by_date is distinct from v_old.needed_by_date then
    v_changed := v_changed || jsonb_build_object('needed_by_date', jsonb_build_array(v_old.needed_by_date, p_needed_by_date));
    v_reset := true;
  end if;

  if p_priority is not null and p_priority is distinct from v_old.priority then
    v_changed := v_changed || jsonb_build_object('priority', jsonb_build_array(v_old.priority, p_priority));
    v_reset := true;
  end if;

  if p_notes is not null and p_notes is distinct from v_old.notes then
    v_changed := v_changed || jsonb_build_object('notes', jsonb_build_array(v_old.notes, p_notes));
    v_reset := true;
  end if;

  update public.purchase_requests
  set
    needed_by_date = coalesce(p_needed_by_date, needed_by_date),
    priority = coalesce(p_priority, priority),
    notes = coalesce(p_notes, notes),
    updated_by = p_actor_id,
    updated_at = now()
  where id = p_pr_id
  returning * into v_new;

  -- If PR was approved, and something changed, reset approval and status back to submitted
  if v_old.status = 'approved' and v_reset then
    update public.purchase_requests
    set
      status = 'submitted',
      approved_by = null,
      approved_at = null,
      updated_by = p_actor_id,
      updated_at = now()
    where id = p_pr_id
    returning * into v_new;

    perform public.insert_status_log(
      'purchase_request',
      v_new.id,
      v_new.project_id,
      'approved',
      'submitted',
      'Approval reset due to PR header change',
      jsonb_build_object('changed', v_changed),
      p_actor_id
    );
  end if;

  perform public.insert_status_log(
    'purchase_request',
    v_new.id,
    v_new.project_id,
    null,
    null,
    'PR header updated',
    jsonb_build_object('changed', v_changed),
    p_actor_id
  );

  return v_new;
end;
$$;

-- -------------------------------
-- 6) RPC: Upsert PR line
--      - Allowed on draft/submitted/approved
--      - If approved and changes occur, reset approval and set status to submitted
-- -------------------------------
create or replace function public.upsert_purchase_request_line(
  p_purchase_request_id uuid,
  p_actor_id uuid,
  p_id uuid default null,
  p_catalog_item_id uuid default null,
  p_description text default null,
  p_qty numeric default null,
  p_uom text default null,
  p_est_unit_cost numeric default null,
  p_sov_item_id uuid default null,
  p_timeline_task_id uuid default null,
  p_sort_order int default 0,
  p_is_active boolean default true
) returns public.purchase_request_lines
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pr public.purchase_requests;
  v_line public.purchase_request_lines;
  v_exists boolean := false;
  v_changed jsonb := '{}'::jsonb;
begin
  perform public.assert_actor_exists(p_actor_id);

  select * into v_pr
  from public.purchase_requests
  where id = p_purchase_request_id
  for update;

  if not found then
    raise exception 'PR % not found', p_purchase_request_id;
  end if;

  if v_pr.status not in ('draft','submitted','approved') then
    raise exception 'PR % lines cannot be edited in status %', p_purchase_request_id, v_pr.status;
  end if;

  if p_description is null or btrim(p_description) = '' then
    raise exception 'Line description is required';
  end if;

  if p_qty is null then
    raise exception 'qty is required';
  end if;

  if p_id is not null then
    select true into v_exists
    from public.purchase_request_lines
    where id = p_id and purchase_request_id = p_purchase_request_id;
  end if;

  if v_exists then
    update public.purchase_request_lines
    set
      catalog_item_id = p_catalog_item_id,
      description = p_description,
      qty = p_qty,
      uom = p_uom,
      est_unit_cost = p_est_unit_cost,
      sov_item_id = p_sov_item_id,
      timeline_task_id = p_timeline_task_id,
      sort_order = coalesce(p_sort_order, sort_order),
      is_active = coalesce(p_is_active, is_active),
      updated_by = p_actor_id,
      updated_at = now()
    where id = p_id
    returning * into v_line;

    perform public.insert_status_log(
      'purchase_request_line',
      v_line.id,
      v_pr.project_id,
      null,
      null,
      'PR line updated',
      jsonb_build_object('pr_id', v_pr.id, 'description', v_line.description, 'qty', v_line.qty, 'est_unit_cost', v_line.est_unit_cost),
      p_actor_id
    );
  else
    insert into public.purchase_request_lines (
      purchase_request_id,
      project_id,
      catalog_item_id,
      description,
      qty,
      uom,
      est_unit_cost,
      sov_item_id,
      timeline_task_id,
      sort_order,
      is_active,
      created_by,
      updated_by
    ) values (
      v_pr.id,
      v_pr.project_id,
      p_catalog_item_id,
      p_description,
      p_qty,
      p_uom,
      p_est_unit_cost,
      p_sov_item_id,
      p_timeline_task_id,
      coalesce(p_sort_order, 0),
      coalesce(p_is_active, true),
      p_actor_id,
      p_actor_id
    )
    returning * into v_line;

    perform public.insert_status_log(
      'purchase_request_line',
      v_line.id,
      v_pr.project_id,
      null,
      null,
      'PR line created',
      jsonb_build_object('pr_id', v_pr.id, 'description', v_line.description, 'qty', v_line.qty, 'est_unit_cost', v_line.est_unit_cost),
      p_actor_id
    );
  end if;

  -- If PR was approved, any line edit resets approval
  if v_pr.status = 'approved' then
    update public.purchase_requests
    set
      status = 'submitted',
      approved_by = null,
      approved_at = null,
      updated_by = p_actor_id,
      updated_at = now()
    where id = v_pr.id;

    perform public.insert_status_log(
      'purchase_request',
      v_pr.id,
      v_pr.project_id,
      'approved',
      'submitted',
      'Approval reset due to PR line change',
      jsonb_build_object('pr_id', v_pr.id),
      p_actor_id
    );
  end if;

  return v_line;
end;
$$;

-- -------------------------------
-- 7) RPC: Submit PR
-- -------------------------------
create or replace function public.submit_purchase_request(
  p_pr_id uuid,
  p_actor_id uuid,
  p_message text default null
) returns public.purchase_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old public.purchase_requests;
  v_new public.purchase_requests;
begin
  perform public.assert_actor_exists(p_actor_id);

  select * into v_old
  from public.purchase_requests
  where id = p_pr_id
  for update;

  if not found then
    raise exception 'PR % not found', p_pr_id;
  end if;

  if v_old.status = 'draft' then
    update public.purchase_requests
    set
      status = 'submitted',
      updated_by = p_actor_id,
      updated_at = now()
    where id = p_pr_id
    returning * into v_new;

    perform public.insert_status_log(
      'purchase_request',
      v_new.id,
      v_new.project_id,
      'draft',
      'submitted',
      coalesce(p_message, 'PR submitted'),
      jsonb_build_object('pr_number', v_new.pr_number),
      p_actor_id
    );

    return v_new;
  end if;

  if v_old.status = 'submitted' then
    return v_old;
  end if;

  raise exception 'PR % cannot be submitted from status %', p_pr_id, v_old.status;
end;
$$;

-- -------------------------------
-- 8) RPC: Approve PR (threshold + role gating)
-- -------------------------------
create or replace function public.approve_purchase_request(
  p_pr_id uuid,
  p_actor_id uuid,
  p_message text default null
) returns public.purchase_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old public.purchase_requests;
  v_new public.purchase_requests;
  v_total numeric;
  v_threshold numeric;
begin
  perform public.assert_actor_exists(p_actor_id);

  select * into v_old
  from public.purchase_requests
  where id = p_pr_id
  for update;

  if not found then
    raise exception 'PR % not found', p_pr_id;
  end if;

  if v_old.status <> 'submitted' then
    raise exception 'PR % must be submitted before approval (current: %)', p_pr_id, v_old.status;
  end if;

  v_total := public.pr_est_total(p_pr_id);
  v_threshold := public.get_pr_approval_threshold();

  if not public.can_approve_pr(p_actor_id, v_total) then
    raise exception 'Not authorized to approve PR % (total: %, threshold: %)', p_pr_id, v_total, v_threshold;
  end if;

  update public.purchase_requests
  set
    status = 'approved',
    approved_by = p_actor_id,
    approved_at = now(),
    updated_by = p_actor_id,
    updated_at = now()
  where id = p_pr_id
  returning * into v_new;

  perform public.insert_status_log(
    'purchase_request',
    v_new.id,
    v_new.project_id,
    'submitted',
    'approved',
    coalesce(p_message, 'PR approved'),
    jsonb_build_object('pr_number', v_new.pr_number, 'est_total', v_total, 'threshold', v_threshold),
    p_actor_id
  );

  return v_new;
end;
$$;

-- -------------------------------
-- 9) RPC: Reject PR
-- -------------------------------
create or replace function public.reject_purchase_request(
  p_pr_id uuid,
  p_actor_id uuid,
  p_message text default null
) returns public.purchase_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old public.purchase_requests;
  v_new public.purchase_requests;
  v_total numeric;
begin
  perform public.assert_actor_exists(p_actor_id);

  select * into v_old
  from public.purchase_requests
  where id = p_pr_id
  for update;

  if not found then
    raise exception 'PR % not found', p_pr_id;
  end if;

  if v_old.status not in ('submitted','approved') then
    raise exception 'PR % cannot be rejected from status %', p_pr_id, v_old.status;
  end if;

  v_total := public.pr_est_total(p_pr_id);

  -- Same approver gate as approval
  if not public.can_approve_pr(p_actor_id, v_total) then
    raise exception 'Not authorized to reject PR % (total: %)', p_pr_id, v_total;
  end if;

  update public.purchase_requests
  set
    status = 'rejected',
    approved_by = null,
    approved_at = null,
    updated_by = p_actor_id,
    updated_at = now()
  where id = p_pr_id
  returning * into v_new;

  perform public.insert_status_log(
    'purchase_request',
    v_new.id,
    v_new.project_id,
    v_old.status::text,
    'rejected',
    coalesce(p_message, 'PR rejected'),
    jsonb_build_object('pr_number', v_new.pr_number, 'est_total', v_total),
    p_actor_id
  );

  return v_new;
end;
$$;

-- -------------------------------
-- 10) Grants (authenticated executes RPCs)
-- -------------------------------
grant execute on function public.get_pr_approval_threshold() to authenticated;
grant execute on function public.pr_est_total(uuid) to authenticated;

grant execute on function public.create_purchase_request(uuid, uuid, date, text, text) to authenticated;
grant execute on function public.update_purchase_request_header(uuid, uuid, date, text, text) to authenticated;
grant execute on function public.upsert_purchase_request_line(uuid, uuid, uuid, uuid, text, numeric, text, numeric, uuid, uuid, int, boolean) to authenticated;
grant execute on function public.submit_purchase_request(uuid, uuid, text) to authenticated;
grant execute on function public.approve_purchase_request(uuid, uuid, text) to authenticated;
grant execute on function public.reject_purchase_request(uuid, uuid, text) to authenticated;

-- =========================================================
-- End 0009
-- =========================================================
