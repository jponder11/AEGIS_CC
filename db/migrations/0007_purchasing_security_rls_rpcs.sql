-- =========================================================
-- AEGIS_CC • Migration 0007 • Purchasing Security + RLS + RPC-only Writes (Phase 7)
-- Purpose:
--   - Enable RLS on purchasing tables
--   - Allow authenticated read
--   - Block direct writes to core tables
--   - Provide RPC functions (SECURITY DEFINER) as the blessed write path
--   - Add "purchasing" role and role gates
--   - PR approval threshold: >= $1,000 requires Ops/Exec/Accounting/Admin/Commandant
--   - Allow PR edits after submission, log changes, reset approval if edited after approval
--   - Receiving: shop plus foreman/super, allow blind receiving with reconcile flag
-- =========================================================

-- -------------------------------
-- 0) Role expansion (add purchasing)
-- -------------------------------
alter table public.profiles
  drop constraint if exists profiles_role_check;

alter table public.profiles
  add constraint profiles_role_check
  check (role in (
    'user','pm','super','ops','executive','accounting','shop','admin','commandant','purchasing'
  ));

-- -------------------------------
-- 1) Sequences for generic numbering
-- -------------------------------
create sequence if not exists public.pr_number_seq start 1;
create sequence if not exists public.po_number_seq start 1;
create sequence if not exists public.receipt_number_seq start 1;

-- -------------------------------
-- 2) Helpers: role checks + approval threshold
-- -------------------------------
create or replace function public.role_in(p_roles text[])
returns boolean
language sql
stable
as $$
  select coalesce(public.current_user_role() = any(p_roles), false);
$$;

create or replace function public.can_approve_pr(p_pr_id uuid)
returns boolean
language plpgsql
stable
as $$
declare
  v_total numeric;
  v_role text;
begin
  select role into v_role
  from public.profiles
  where id = auth.uid();

  select coalesce(sum(est_ext_cost) filter (where is_active = true), 0)
    into v_total
  from public.purchase_request_lines
  where purchase_request_id = p_pr_id;

  -- threshold is $1,000
  if v_total >= 1000 then
    return coalesce(v_role in ('ops','executive','accounting','admin','commandant'), false);
  else
    return coalesce(v_role in ('purchasing','ops','executive','accounting','admin','commandant'), false);
  end if;
end $$;

create or replace function public.can_issue_po()
returns boolean
language sql
stable
as $$
  select coalesce(public.current_user_role() in ('purchasing','ops','accounting','executive','admin','commandant'), false);
$$;

create or replace function public.can_receive()
returns boolean
language sql
stable
as $$
  select coalesce(public.current_user_role() in ('shop','super','ops','admin','commandant'), false);
$$;

-- -------------------------------
-- 3) Attach updated_at and updated_by triggers (Phase 4 tables)
-- Reuse public.set_updated_at_and_by() from Phase 2
-- -------------------------------
drop trigger if exists trg_vendors_updated_at on public.vendors;
create trigger trg_vendors_updated_at
before update on public.vendors
for each row execute function public.set_updated_at_and_by();

drop trigger if exists trg_vendor_contacts_updated_at on public.vendor_contacts;
create trigger trg_vendor_contacts_updated_at
before update on public.vendor_contacts
for each row execute function public.set_updated_at_and_by();

drop trigger if exists trg_material_catalog_updated_at on public.material_catalog_items;
create trigger trg_material_catalog_updated_at
before update on public.material_catalog_items
for each row execute function public.set_updated_at_and_by();

drop trigger if exists trg_pr_updated_at on public.purchase_requests;
create trigger trg_pr_updated_at
before update on public.purchase_requests
for each row execute function public.set_updated_at_and_by();

drop trigger if exists trg_pr_lines_updated_at on public.purchase_request_lines;
create trigger trg_pr_lines_updated_at
before update on public.purchase_request_lines
for each row execute function public.set_updated_at_and_by();

drop trigger if exists trg_po_updated_at on public.purchase_orders;
create trigger trg_po_updated_at
before update on public.purchase_orders
for each row execute function public.set_updated_at_and_by();

drop trigger if exists trg_po_lines_updated_at on public.purchase_order_lines;
create trigger trg_po_lines_updated_at
before update on public.purchase_order_lines
for each row execute function public.set_updated_at_and_by();

drop trigger if exists trg_receipts_updated_at on public.receipts;
create trigger trg_receipts_updated_at
before update on public.receipts
for each row execute function public.set_updated_at_and_by();

drop trigger if exists trg_receipt_lines_updated_at on public.receipt_lines;
create trigger trg_receipt_lines_updated_at
before update on public.receipt_lines
for each row execute function public.set_updated_at_and_by();

-- -------------------------------
-- 4) RLS: enable + read policies
-- -------------------------------
alter table public.vendors enable row level security;
alter table public.vendor_contacts enable row level security;
alter table public.material_catalog_items enable row level security;
alter table public.purchase_requests enable row level security;
alter table public.purchase_request_lines enable row level security;
alter table public.purchase_orders enable row level security;
alter table public.purchase_order_lines enable row level security;
alter table public.receipts enable row level security;
alter table public.receipt_lines enable row level security;

-- Read for authenticated
drop policy if exists vendors_read on public.vendors;
create policy vendors_read on public.vendors
for select to authenticated
using (true);

drop policy if exists vendor_contacts_read on public.vendor_contacts;
create policy vendor_contacts_read on public.vendor_contacts
for select to authenticated
using (true);

drop policy if exists material_catalog_read on public.material_catalog_items;
create policy material_catalog_read on public.material_catalog_items
for select to authenticated
using (true);

drop policy if exists pr_read on public.purchase_requests;
create policy pr_read on public.purchase_requests
for select to authenticated
using (true);

drop policy if exists pr_lines_read on public.purchase_request_lines;
create policy pr_lines_read on public.purchase_request_lines
for select to authenticated
using (true);

drop policy if exists po_read on public.purchase_orders;
create policy po_read on public.purchase_orders
for select to authenticated
using (true);

drop policy if exists po_lines_read on public.purchase_order_lines;
create policy po_lines_read on public.purchase_order_lines
for select to authenticated
using (true);

drop policy if exists receipts_read on public.receipts;
create policy receipts_read on public.receipts
for select to authenticated
using (true);

drop policy if exists receipt_lines_read on public.receipt_lines;
create policy receipt_lines_read on public.receipt_lines
for select to authenticated
using (true);

-- Explicit deny direct writes
drop policy if exists vendors_no_write on public.vendors;
create policy vendors_no_write on public.vendors
for all to authenticated
using (false) with check (false);

drop policy if exists vendor_contacts_no_write on public.vendor_contacts;
create policy vendor_contacts_no_write on public.vendor_contacts
for all to authenticated
using (false) with check (false);

drop policy if exists material_catalog_no_write on public.material_catalog_items;
create policy material_catalog_no_write on public.material_catalog_items
for all to authenticated
using (false) with check (false);

drop policy if exists pr_no_write on public.purchase_requests;
create policy pr_no_write on public.purchase_requests
for all to authenticated
using (false) with check (false);

drop policy if exists pr_lines_no_write on public.purchase_request_lines;
create policy pr_lines_no_write on public.purchase_request_lines
for all to authenticated
using (false) with check (false);

drop policy if exists po_no_write on public.purchase_orders;
create policy po_no_write on public.purchase_orders
for all to authenticated
using (false) with check (false);

drop policy if exists po_lines_no_write on public.purchase_order_lines;
create policy po_lines_no_write on public.purchase_order_lines
for all to authenticated
using (false) with check (false);

drop policy if exists receipts_no_write on public.receipts;
create policy receipts_no_write on public.receipts
for all to authenticated
using (false) with check (false);

drop policy if exists receipt_lines_no_write on public.receipt_lines;
create policy receipt_lines_no_write on public.receipt_lines
for all to authenticated
using (false) with check (false);

-- Revoke direct writes at privilege level too
revoke insert, update, delete on public.vendors from authenticated, anon;
revoke insert, update, delete on public.vendor_contacts from authenticated, anon;
revoke insert, update, delete on public.material_catalog_items from authenticated, anon;
revoke insert, update, delete on public.purchase_requests from authenticated, anon;
revoke insert, update, delete on public.purchase_request_lines from authenticated, anon;
revoke insert, update, delete on public.purchase_orders from authenticated, anon;
revoke insert, update, delete on public.purchase_order_lines from authenticated, anon;
revoke insert, update, delete on public.receipts from authenticated, anon;
revoke insert, update, delete on public.receipt_lines from authenticated, anon;

-- -------------------------------
-- 5) RPC: PR create/update/submit/approve/reject
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

  v_pr_number :=
    'PR-' || to_char(now(), 'YYYYMMDD') || '-' || lpad(nextval('public.pr_number_seq')::text, 5, '0');

  insert into public.purchase_requests (
    project_id, pr_number, status, needed_by_date, priority, notes,
    requested_by, created_by, updated_by
  ) values (
    p_project_id, v_pr_number, 'draft', p_needed_by_date, p_priority, p_notes,
    p_actor_id, p_actor_id, p_actor_id
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
end $$;

create or replace function public.update_purchase_request_header(
  p_purchase_request_id uuid,
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
begin
  perform public.assert_actor_exists(p_actor_id);

  select * into v_old
  from public.purchase_requests
  where id = p_purchase_request_id
  for update;

  if not found then
    raise exception 'PR % not found', p_purchase_request_id;
  end if;

  if v_old.status in ('cancelled','fulfilled') then
    raise exception 'PR % is not editable in status %', v_old.pr_number, v_old.status;
  end if;

  update public.purchase_requests
  set
    needed_by_date = coalesce(p_needed_by_date, needed_by_date),
    priority = coalesce(p_priority, priority),
    notes = coalesce(p_notes, notes),
    updated_by = p_actor_id,
    updated_at = now()
  where id = p_purchase_request_id
  returning * into v_new;

  perform public.insert_status_log(
    'purchase_request',
    v_new.id,
    v_new.project_id,
    null,
    null,
    'PR header updated',
    jsonb_build_object(
      'status_at_edit', v_old.status::text,
      'needed_by_date_old', v_old.needed_by_date,
      'needed_by_date_new', v_new.needed_by_date,
      'priority_old', v_old.priority,
      'priority_new', v_new.priority
    ),
    p_actor_id
  );

  return v_new;
end $$;

create or replace function public.submit_purchase_request(
  p_purchase_request_id uuid,
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
  where id = p_purchase_request_id
  for update;

  if not found then
    raise exception 'PR % not found', p_purchase_request_id;
  end if;

  if v_old.status in ('cancelled','fulfilled') then
    raise exception 'PR % cannot be submitted in status %', v_old.pr_number, v_old.status;
  end if;

  update public.purchase_requests
  set status = 'submitted',
      updated_by = p_actor_id,
      updated_at = now()
  where id = p_purchase_request_id
  returning * into v_new;

  perform public.insert_status_log(
    'purchase_request',
    v_new.id,
    v_new.project_id,
    v_old.status::text,
    v_new.status::text,
    coalesce(p_message, 'PR submitted'),
    jsonb_build_object('pr_number', v_new.pr_number),
    p_actor_id
  );

  return v_new;
end $$;

create or replace function public.approve_purchase_request(
  p_purchase_request_id uuid,
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

  if not public.can_approve_pr(p_purchase_request_id) then
    raise exception 'PR approval not permitted for this user or threshold rules';
  end if;

  select * into v_old
  from public.purchase_requests
  where id = p_purchase_request_id
  for update;

  if not found then
    raise exception 'PR % not found', p_purchase_request_id;
  end if;

  if v_old.status not in ('submitted','draft') then
    raise exception 'PR % cannot be approved from status %', v_old.pr_number, v_old.status;
  end if;

  update public.purchase_requests
  set status = 'approved',
      approved_by = p_actor_id,
      approved_at = now(),
      updated_by = p_actor_id,
      updated_at = now()
  where id = p_purchase_request_id
  returning * into v_new;

  perform public.insert_status_log(
    'purchase_request',
    v_new.id,
    v_new.project_id,
    v_old.status::text,
    v_new.status::text,
    coalesce(p_message, 'PR approved'),
    jsonb_build_object('pr_number', v_new.pr_number),
    p_actor_id
  );

  return v_new;
end $$;

create or replace function public.reject_purchase_request(
  p_purchase_request_id uuid,
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

  if not public.role_in(array['purchasing','ops','executive','accounting','admin','commandant']) then
    raise exception 'Only purchasing, ops, executive, accounting, admin, commandant can reject PRs';
  end if;

  select * into v_old
  from public.purchase_requests
  where id = p_purchase_request_id
  for update;

  if not found then
    raise exception 'PR % not found', p_purchase_request_id;
  end if;

  if v_old.status in ('cancelled','fulfilled') then
    raise exception 'PR % cannot be rejected in status %', v_old.pr_number, v_old.status;
  end if;

  update public.purchase_requests
  set status = 'rejected',
      updated_by = p_actor_id,
      updated_at = now()
  where id = p_purchase_request_id
  returning * into v_new;

  perform public.insert_status_log(
    'purchase_request',
    v_new.id,
    v_new.project_id,
    v_old.status::text,
    v_new.status::text,
    coalesce(p_message, 'PR rejected'),
    jsonb_build_object('pr_number', v_new.pr_number),
    p_actor_id
  );

  return v_new;
end $$;

-- -------------------------------
-- 6) RPC: PR line upsert (log changes, reset approval if PR was approved)
-- -------------------------------
create or replace function public.upsert_purchase_request_line(
  p_purchase_request_id uuid,
  p_project_id uuid,
  p_actor_id uuid,
  p_id uuid default null,
  p_catalog_item_id uuid default null,
  p_description text default null,
  p_qty numeric default null,
  p_uom text default null,
  p_est_unit_cost numeric default null,
  p_sov_item_id uuid default null,
  p_timeline_task_id uuid default null,
  p_is_active boolean default true,
  p_sort_order int default 0
) returns public.purchase_request_lines
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pr public.purchase_requests;
  v_old_line public.purchase_request_lines;
  v_new_line public.purchase_request_lines;
  v_exists boolean;
begin
  perform public.assert_actor_exists(p_actor_id);

  select * into v_pr
  from public.purchase_requests
  where id = p_purchase_request_id
  for update;

  if not found then
    raise exception 'PR % not found', p_purchase_request_id;
  end if;

  if v_pr.status in ('cancelled','fulfilled') then
    raise exception 'PR % is not editable in status %', v_pr.pr_number, v_pr.status;
  end if;

  if p_description is null or btrim(p_description) = '' then
    raise exception 'PR line description is required';
  end if;

  v_exists := false;
  if p_id is not null then
    select true into v_exists
    from public.purchase_request_lines
    where id = p_id and purchase_request_id = p_purchase_request_id;
  end if;

  if v_exists then
    select * into v_old_line
    from public.purchase_request_lines
    where id = p_id
    for update;

    update public.purchase_request_lines
    set
      catalog_item_id = p_catalog_item_id,
      description = p_description,
      qty = coalesce(p_qty, qty),
      uom = coalesce(p_uom, uom),
      est_unit_cost = p_est_unit_cost,
      sov_item_id = p_sov_item_id,
      timeline_task_id = p_timeline_task_id,
      is_active = coalesce(p_is_active, is_active),
      sort_order = coalesce(p_sort_order, sort_order),
      updated_by = p_actor_id,
      updated_at = now()
    where id = p_id
    returning * into v_new_line;

    perform public.insert_status_log(
      'purchase_request_line',
      v_new_line.id,
      v_pr.project_id,
      null,
      null,
      'PR line updated',
      jsonb_build_object(
        'status_at_edit', v_pr.status::text,
        'old', jsonb_build_object(
          'description', v_old_line.description,
          'qty', v_old_line.qty,
          'uom', v_old_line.uom,
          'est_unit_cost', v_old_line.est_unit_cost,
          'is_active', v_old_line.is_active
        ),
        'new', jsonb_build_object(
          'description', v_new_line.description,
          'qty', v_new_line.qty,
          'uom', v_new_line.uom,
          'est_unit_cost', v_new_line.est_unit_cost,
          'is_active', v_new_line.is_active
        )
      ),
      p_actor_id
    );
  else
    insert into public.purchase_request_lines (
      purchase_request_id, project_id, catalog_item_id, description,
      qty, uom, est_unit_cost, sov_item_id, timeline_task_id,
      is_active, sort_order, created_by, updated_by
    ) values (
      p_purchase_request_id, p_project_id, p_catalog_item_id, p_description,
      coalesce(p_qty, 0), p_uom, p_est_unit_cost, p_sov_item_id, p_timeline_task_id,
      coalesce(p_is_active, true), coalesce(p_sort_order, 0), p_actor_id, p_actor_id
    )
    returning * into v_new_line;

    perform public.insert_status_log(
      'purchase_request_line',
      v_new_line.id,
      v_pr.project_id,
      null,
      null,
      'PR line created',
      jsonb_build_object(
        'status_at_create', v_pr.status::text,
        'description', v_new_line.description,
        'qty', v_new_line.qty
      ),
      p_actor_id
    );
  end if;

  -- If PR was approved and someone edits a line, reset approval
  if v_pr.status = 'approved' then
    update public.purchase_requests
    set status = 'submitted',
        approved_by = null,
        approved_at = null,
        updated_by = p_actor_id,
        updated_at = now()
    where id = p_purchase_request_id;

    perform public.insert_status_log(
      'purchase_request',
      v_pr.id,
      v_pr.project_id,
      'approved',
      'submitted',
      'PR edited after approval, approval reset',
      jsonb_build_object('pr_number', v_pr.pr_number),
      p_actor_id
    );
  end if;

  return v_new_line;
end $$;

-- -------------------------------
-- 7) RPC: PO create and issue
-- -------------------------------
create or replace function public.create_purchase_order(
  p_project_id uuid,
  p_vendor_id uuid,
  p_actor_id uuid,
  p_needed_by_date date default null,
  p_ship_to_name text default null,
  p_ship_to_address1 text default null,
  p_ship_to_address2 text default null,
  p_ship_to_city text default null,
  p_ship_to_state text default null,
  p_ship_to_zip text default null,
  p_notes text default null
) returns public.purchase_orders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_po public.purchase_orders;
  v_po_number text;
begin
  perform public.assert_actor_exists(p_actor_id);

  if not public.can_issue_po() then
    raise exception 'Only purchasing, ops, accounting, executive, admin, commandant can create POs';
  end if;

  v_po_number :=
    'PO-' || to_char(now(), 'YYYYMMDD') || '-' || lpad(nextval('public.po_number_seq')::text, 5, '0');

  insert into public.purchase_orders (
    project_id, vendor_id, po_number, status,
    needed_by_date,
    ship_to_name, ship_to_address1, ship_to_address2, ship_to_city, ship_to_state, ship_to_zip,
    notes,
    created_by, updated_by
  ) values (
    p_project_id, p_vendor_id, v_po_number, 'draft',
    p_needed_by_date,
    p_ship_to_name, p_ship_to_address1, p_ship_to_address2, p_ship_to_city, p_ship_to_state, p_ship_to_zip,
    p_notes,
    p_actor_id, p_actor_id
  )
  returning * into v_po;

  perform public.insert_status_log(
    'purchase_order',
    v_po.id,
    v_po.project_id,
    null,
    v_po.status::text,
    'PO created (draft)',
    jsonb_build_object('po_number', v_po.po_number, 'vendor_id', v_po.vendor_id),
    p_actor_id
  );

  return v_po;
end $$;

create or replace function public.issue_purchase_order(
  p_purchase_order_id uuid,
  p_actor_id uuid,
  p_message text default null
) returns public.purchase_orders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old public.purchase_orders;
  v_new public.purchase_orders;
begin
  perform public.assert_actor_exists(p_actor_id);

  if not public.can_issue_po() then
    raise exception 'Only purchasing, ops, accounting, executive, admin, commandant can issue POs';
  end if;

  select * into v_old
  from public.purchase_orders
  where id = p_purchase_order_id
  for update;

  if not found then
    raise exception 'PO % not found', p_purchase_order_id;
  end if;

  if v_old.status in ('cancelled','closed') then
    raise exception 'PO % cannot be issued in status %', v_old.po_number, v_old.status;
  end if;

  update public.purchase_orders
  set status = 'issued',
      issued_at = now(),
      updated_by = p_actor_id,
      updated_at = now()
  where id = p_purchase_order_id
  returning * into v_new;

  perform public.insert_status_log(
    'purchase_order',
    v_new.id,
    v_new.project_id,
    v_old.status::text,
    v_new.status::text,
    coalesce(p_message, 'PO issued'),
    jsonb_build_object('po_number', v_new.po_number),
    p_actor_id
  );

  return v_new;
end $$;

-- -------------------------------
-- 8) RPC: PO line upsert (allow freehand, prefer PR linkage)
-- -------------------------------
create or replace function public.upsert_purchase_order_line(
  p_purchase_order_id uuid,
  p_project_id uuid,
  p_actor_id uuid,
  p_id uuid default null,
  p_pr_line_id uuid default null,
  p_catalog_item_id uuid default null,
  p_description text default null,
  p_qty numeric default null,
  p_uom text default null,
  p_unit_cost numeric default null,
  p_sov_item_id uuid default null,
  p_timeline_task_id uuid default null,
  p_is_active boolean default true,
  p_sort_order int default 0
) returns public.purchase_order_lines
language plpgsql
security definer
set search_path = public
as $$
declare
  v_po public.purchase_orders;
  v_old public.purchase_order_lines;
  v_new public.purchase_order_lines;
  v_exists boolean;
begin
  perform public.assert_actor_exists(p_actor_id);

  if not public.can_issue_po() then
    raise exception 'Only purchasing, ops, accounting, executive, admin, commandant can edit PO lines';
  end if;

  select * into v_po
  from public.purchase_orders
  where id = p_purchase_order_id
  for update;

  if not found then
    raise exception 'PO % not found', p_purchase_order_id;
  end if;

  if v_po.status in ('cancelled','closed') then
    raise exception 'PO % is not editable in status %', v_po.po_number, v_po.status;
  end if;

  if v_po.status in ('issued','acknowledged','partially_received','received') then
    -- Keep edits possible, but log that this was post-issue adjustment
    null;
  end if;

  if p_description is null or btrim(p_description) = '' then
    raise exception 'PO line description is required';
  end if;

  v_exists := false;
  if p_id is not null then
    select true into v_exists
    from public.purchase_order_lines
    where id = p_id and purchase_order_id = p_purchase_order_id;
  end if;

  if v_exists then
    select * into v_old
    from public.purchase_order_lines
    where id = p_id
    for update;

    update public.purchase_order_lines
    set
      pr_line_id = p_pr_line_id,
      catalog_item_id = p_catalog_item_id,
      description = p_description,
      qty = coalesce(p_qty, qty),
      uom = coalesce(p_uom, uom),
      unit_cost = coalesce(p_unit_cost, unit_cost),
      sov_item_id = p_sov_item_id,
      timeline_task_id = p_timeline_task_id,
      is_active = coalesce(p_is_active, is_active),
      sort_order = coalesce(p_sort_order, sort_order),
      updated_by = p_actor_id,
      updated_at = now()
    where id = p_id
    returning * into v_new;

    perform public.insert_status_log(
      'purchase_order_line',
      v_new.id,
      v_new.project_id,
      null,
      null,
      'PO line updated',
      jsonb_build_object(
        'po_status_at_edit', v_po.status::text,
        'old', jsonb_build_object('description', v_old.description, 'qty', v_old.qty, 'unit_cost', v_old.unit_cost, 'pr_line_id', v_old.pr_line_id),
        'new', jsonb_build_object('description', v_new.description, 'qty', v_new.qty, 'unit_cost', v_new.unit_cost, 'pr_line_id', v_new.pr_line_id)
      ),
      p_actor_id
    );
  else
    insert into public.purchase_order_lines (
      purchase_order_id, project_id, pr_line_id, catalog_item_id, description,
      qty, uom, unit_cost, sov_item_id, timeline_task_id,
      is_active, sort_order, created_by, updated_by
    ) values (
      p_purchase_order_id, p_project_id, p_pr_line_id, p_catalog_item_id, p_description,
      coalesce(p_qty, 0), p_uom, coalesce(p_unit_cost, 0), p_sov_item_id, p_timeline_task_id,
      coalesce(p_is_active, true), coalesce(p_sort_order, 0), p_actor_id, p_actor_id
    )
    returning * into v_new;

    perform public.insert_status_log(
      'purchase_order_line',
      v_new.id,
      v_new.project_id,
      null,
      null,
      'PO line created',
      jsonb_build_object('po_status_at_create', v_po.status::text, 'pr_line_id', v_new.pr_line_id),
      p_actor_id
    );
  end if;

  return v_new;
end $$;

-- -------------------------------
-- 9) Receiving: create receipt, add lines, receive, reconcile
-- -------------------------------
create or replace function public.create_receipt(
  p_project_id uuid,
  p_actor_id uuid,
  p_vendor_id uuid default null,
  p_purchase_order_id uuid default null,
  p_location text default null,
  p_notes text default null
) returns public.receipts
language plpgsql
security definer
set search_path = public
as $$
declare
  v_r public.receipts;
  v_receipt_number text;
begin
  perform public.assert_actor_exists(p_actor_id);

  if not public.can_receive() then
    raise exception 'Only shop, super, ops, admin, commandant can create receipts';
  end if;

  v_receipt_number :=
    'RCV-' || to_char(now(), 'YYYYMMDD') || '-' || lpad(nextval('public.receipt_number_seq')::text, 5, '0');

  insert into public.receipts (
    project_id, vendor_id, purchase_order_id,
    receipt_number, status,
    location, notes,
    received_by,
    created_by, updated_by
  ) values (
    p_project_id, p_vendor_id, p_purchase_order_id,
    v_receipt_number, 'pending',
    p_location, p_notes,
    p_actor_id,
    p_actor_id, p_actor_id
  )
  returning * into v_r;

  perform public.insert_status_log(
    'receipt',
    v_r.id,
    v_r.project_id,
    null,
    v_r.status::text,
    'Receipt created',
    jsonb_build_object('receipt_number', v_r.receipt_number, 'purchase_order_id', v_r.purchase_order_id),
    p_actor_id
  );

  return v_r;
end $$;

create or replace function public.upsert_receipt_line(
  p_receipt_id uuid,
  p_project_id uuid,
  p_actor_id uuid,
  p_id uuid default null,
  p_purchase_order_line_id uuid default null,
  p_description text default null,
  p_qty_received numeric default null,
  p_uom text default null,
  p_condition text default null,
  p_notes text default null
) returns public.receipt_lines
language plpgsql
security definer
set search_path = public
as $$
declare
  v_r public.receipts;
  v_old public.receipt_lines;
  v_new public.receipt_lines;
  v_exists boolean;
begin
  perform public.assert_actor_exists(p_actor_id);

  if not public.can_receive() then
    raise exception 'Only shop, super, ops, admin, commandant can edit receipt lines';
  end if;

  select * into v_r
  from public.receipts
  where id = p_receipt_id
  for update;

  if not found then
    raise exception 'Receipt % not found', p_receipt_id;
  end if;

  if v_r.status = 'cancelled' then
    raise exception 'Receipt % is cancelled', v_r.receipt_number;
  end if;

  if p_description is null or btrim(p_description) = '' then
    raise exception 'Receipt line description is required';
  end if;

  v_exists := false;
  if p_id is not null then
    select true into v_exists
    from public.receipt_lines
    where id = p_id and receipt_id = p_receipt_id;
  end if;

  if v_exists then
    select * into v_old
    from public.receipt_lines
    where id = p_id
    for update;

    update public.receipt_lines
    set
      purchase_order_line_id = p_purchase_order_line_id,
      description = p_description,
      qty_received = coalesce(p_qty_received, qty_received),
      uom = coalesce(p_uom, uom),
      condition = p_condition,
      notes = p_notes,
      updated_by = p_actor_id,
      updated_at = now()
    where id = p_id
    returning * into v_new;

    perform public.insert_status_log(
      'receipt_line',
      v_new.id,
      v_new.project_id,
      null,
      null,
      'Receipt line updated',
      jsonb_build_object(
        'old', jsonb_build_object('qty_received', v_old.qty_received, 'po_line_id', v_old.purchase_order_line_id),
        'new', jsonb_build_object('qty_received', v_new.qty_received, 'po_line_id', v_new.purchase_order_line_id)
      ),
      p_actor_id
    );
  else
    insert into public.receipt_lines (
      receipt_id, project_id, purchase_order_line_id,
      description, qty_received, uom, condition, notes,
      created_by, updated_by
    ) values (
      p_receipt_id, p_project_id, p_purchase_order_line_id,
      p_description, coalesce(p_qty_received, 0), p_uom, p_condition, p_notes,
      p_actor_id, p_actor_id
    )
    returning * into v_new;

    perform public.insert_status_log(
      'receipt_line',
      v_new.id,
      v_new.project_id,
      null,
      null,
      'Receipt line created',
      jsonb_build_object('po_line_id', v_new.purchase_order_line_id),
      p_actor_id
    );
  end if;

  return v_new;
end $$;

create or replace function public.mark_receipt_received(
  p_receipt_id uuid,
  p_actor_id uuid,
  p_message text default null
) returns public.receipts
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old public.receipts;
  v_new public.receipts;
  v_unlinked int;
begin
  perform public.assert_actor_exists(p_actor_id);

  if not public.can_receive() then
    raise exception 'Only shop, super, ops, admin, commandant can mark receipts received';
  end if;

  select * into v_old
  from public.receipts
  where id = p_receipt_id
  for update;

  if not found then
    raise exception 'Receipt % not found', p_receipt_id;
  end if;

  if v_old.status = 'cancelled' then
    raise exception 'Receipt % is cancelled', v_old.receipt_number;
  end if;

  select count(*) into v_unlinked
  from public.receipt_lines
  where receipt_id = p_receipt_id
    and purchase_order_line_id is null;

  update public.receipts
  set status = case when v_unlinked > 0 then 'received' else 'reconciled' end,
      received_at = now(),
      received_by = p_actor_id,
      updated_by = p_actor_id,
      updated_at = now()
  where id = p_receipt_id
  returning * into v_new;

  perform public.insert_status_log(
    'receipt',
    v_new.id,
    v_new.project_id,
    v_old.status::text,
    v_new.status::text,
    coalesce(p_message, 'Receipt marked received'),
    jsonb_build_object('unlinked_lines', v_unlinked, 'receipt_number', v_new.receipt_number),
    p_actor_id
  );

  return v_new;
end $$;

create or replace function public.reconcile_receipt(
  p_receipt_id uuid,
  p_actor_id uuid,
  p_message text default null
) returns public.receipts
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old public.receipts;
  v_new public.receipts;
  v_unlinked int;
begin
  perform public.assert_actor_exists(p_actor_id);

  if not public.role_in(array['purchasing','ops','accounting','executive','admin','commandant']) then
    raise exception 'Only purchasing, ops, accounting, executive, admin, commandant can reconcile receipts';
  end if;

  select * into v_old
  from public.receipts
  where id = p_receipt_id
  for update;

  if not found then
    raise exception 'Receipt % not found', p_receipt_id;
  end if;

  select count(*) into v_unlinked
  from public.receipt_lines
  where receipt_id = p_receipt_id
    and purchase_order_line_id is null;

  if v_unlinked > 0 then
    raise exception 'Receipt still has % unlinked lines, cannot reconcile', v_unlinked;
  end if;

  update public.receipts
  set status = 'reconciled',
      updated_by = p_actor_id,
      updated_at = now()
  where id = p_receipt_id
  returning * into v_new;

  perform public.insert_status_log(
    'receipt',
    v_new.id,
    v_new.project_id,
    v_old.status::text,
    v_new.status::text,
    coalesce(p_message, 'Receipt reconciled'),
    jsonb_build_object('receipt_number', v_new.receipt_number),
    p_actor_id
  );

  return v_new;
end $$;

-- -------------------------------
-- 10) Grant execute on RPCs
-- -------------------------------
grant execute on function public.create_purchase_request(uuid, uuid, date, text, text) to authenticated;
grant execute on function public.update_purchase_request_header(uuid, uuid, date, text, text) to authenticated;
grant execute on function public.submit_purchase_request(uuid, uuid, text) to authenticated;
grant execute on function public.approve_purchase_request(uuid, uuid, text) to authenticated;
grant execute on function public.reject_purchase_request(uuid, uuid, text) to authenticated;

grant execute on function public.upsert_purchase_request_line(
  uuid, uuid, uuid, uuid, uuid, text, numeric, text, numeric, uuid, uuid, boolean, int
) to authenticated;

grant execute on function public.create_purchase_order(
  uuid, uuid, uuid, date, text, text, text, text, text, text, text
) to authenticated;

grant execute on function public.issue_purchase_order(uuid, uuid, text) to authenticated;

grant execute on function public.upsert_purchase_order_line(
  uuid, uuid, uuid, uuid, uuid, uuid, text, numeric, text, numeric, uuid, uuid, boolean, int
) to authenticated;

grant execute on function public.create_receipt(uuid, uuid, uuid, uuid, text, text) to authenticated;

grant execute on function public.upsert_receipt_line(
  uuid, uuid, uuid, uuid, uuid, text, numeric, text, text, text
) to authenticated;

grant execute on function public.mark_receipt_received(uuid, uuid, text) to authenticated;
grant execute on function public.reconcile_receipt(uuid, uuid, text) to authenticated;

-- =========================================================
-- End 0007
-- =========================================================
