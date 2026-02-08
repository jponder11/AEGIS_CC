-- =========================================================
-- AEGIS_CC • Migration 0005 • Purchasing Security + RLS + RPC-only Writes (Phase 5)
-- Goals:
--   - Enable RLS on purchasing tables
--   - Allow authenticated read
--   - Block direct writes
--   - Provide SECURITY DEFINER RPCs as the only mutation path
--   - Generic numbering for PR/PO/Receipts
--   - Audit attribution (updated_by) + status_logs entries in RPCs
-- =========================================================

-- -------------------------------
-- 0) Ensure helpers exist (idempotent)
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
    entity_type, entity_id, project_id,
    from_status, to_status, message, metadata,
    created_by
  ) values (
    p_entity_type, p_entity_id, p_project_id,
    p_from_status, p_to_status,
    p_message,
    coalesce(p_metadata, '{}'::jsonb),
    p_created_by
  );
end $$;

-- -------------------------------
-- 1) Safe audit triggers (reuse existing set_updated_at_and_by)
-- -------------------------------
-- Assumes public.set_updated_at_and_by() exists from Phase 2.
-- If not, add it (but you already have it).

drop trigger if exists trg_vendors_updated_at on public.vendors;
create trigger trg_vendors_updated_at
before update on public.vendors
for each row execute function public.set_updated_at_and_by();

drop trigger if exists trg_vendor_contacts_updated_at on public.vendor_contacts;
create trigger trg_vendor_contacts_updated_at
before update on public.vendor_contacts
for each row execute function public.set_updated_at_and_by();

drop trigger if exists trg_catalog_updated_at on public.material_catalog_items;
create trigger trg_catalog_updated_at
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
-- 2) Number sequences + generators (generic)
-- -------------------------------
create table if not exists public.number_sequences (
  name text primary key,
  current_value bigint not null default 0,
  updated_at timestamptz not null default now()
);

create or replace function public.next_number(p_name text)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_next bigint;
begin
  insert into public.number_sequences(name, current_value)
  values (p_name, 0)
  on conflict (name) do nothing;

  update public.number_sequences
  set current_value = current_value + 1,
      updated_at = now()
  where name = p_name
  returning current_value into v_next;

  return v_next;
end $$;

create or replace function public.format_doc_number(p_prefix text, p_seq bigint)
returns text
language sql
stable
as $$
  select p_prefix || '-' || lpad(p_seq::text, 6, '0');
$$;

-- -------------------------------
-- 3) RPCs (blessed write paths)
-- -------------------------------

-- 3A) Vendor upsert (simple PoC)
create or replace function public.upsert_vendor(
  p_actor_id uuid,
  p_id uuid default null,
  p_name text default null,
  p_trade text default null,
  p_phone text default null,
  p_email text default null,
  p_website text default null,
  p_address1 text default null,
  p_address2 text default null,
  p_city text default null,
  p_state text default null,
  p_zip text default null,
  p_payment_terms text default null,
  p_notes text default null,
  p_is_active boolean default true
) returns public.vendors
language plpgsql
security definer
set search_path = public
as $$
declare
  v_vendor public.vendors;
  v_exists boolean;
begin
  perform public.assert_actor_exists(p_actor_id);

  if p_name is null or btrim(p_name) = '' then
    raise exception 'vendor name is required';
  end if;

  v_exists := false;
  if p_id is not null then
    select true into v_exists from public.vendors where id = p_id;
  end if;

  if v_exists then
    update public.vendors
    set name = btrim(p_name),
        trade = p_trade,
        phone = p_phone,
        email = p_email,
        website = p_website,
        address1 = p_address1,
        address2 = p_address2,
        city = p_city,
        state = p_state,
        zip = p_zip,
        payment_terms = p_payment_terms,
        notes = p_notes,
        is_active = coalesce(p_is_active, is_active),
        updated_by = p_actor_id,
        updated_at = now()
    where id = p_id
    returning * into v_vendor;

    perform public.insert_status_log(
      'vendor',
      v_vendor.id,
      null,
      null,
      null,
      'Vendor updated',
      jsonb_build_object('vendor_name', v_vendor.name),
      p_actor_id
    );
  else
    insert into public.vendors (
      name, trade, phone, email, website,
      address1, address2, city, state, zip,
      payment_terms, notes, is_active,
      created_by, updated_by
    ) values (
      btrim(p_name), p_trade, p_phone, p_email, p_website,
      p_address1, p_address2, p_city, p_state, p_zip,
      p_payment_terms, p_notes, coalesce(p_is_active, true),
      p_actor_id, p_actor_id
    )
    returning * into v_vendor;

    perform public.insert_status_log(
      'vendor',
      v_vendor.id,
      null,
      null,
      null,
      'Vendor created',
      jsonb_build_object('vendor_name', v_vendor.name),
      p_actor_id
    );
  end if;

  return v_vendor;
end $$;

-- 3B) PR create (generates pr_number)
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
  v_seq bigint;
  v_number text;
begin
  perform public.assert_actor_exists(p_actor_id);

  if not exists (select 1 from public.projects where id = p_project_id) then
    raise exception 'Project % not found', p_project_id;
  end if;

  v_seq := public.next_number('pr');
  v_number := public.format_doc_number('PR', v_seq);

  insert into public.purchase_requests (
    project_id, pr_number, status,
    needed_by_date, priority,
    requested_by, notes,
    created_by, updated_by
  ) values (
    p_project_id, v_number, 'draft',
    p_needed_by_date, p_priority,
    p_actor_id, p_notes,
    p_actor_id, p_actor_id
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

-- 3C) PR line upsert (header project_id wins)
create or replace function public.upsert_pr_line(
  p_purchase_request_id uuid,
  p_actor_id uuid,
  p_id uuid default null,
  p_catalog_item_id uuid default null,
  p_description text default null,
  p_qty numeric default 0,
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
  v_line public.purchase_request_lines;
  v_exists boolean;
  v_project_id uuid;
begin
  perform public.assert_actor_exists(p_actor_id);

  select project_id into v_project_id
  from public.purchase_requests
  where id = p_purchase_request_id;

  if v_project_id is null then
    raise exception 'PR % not found', p_purchase_request_id;
  end if;

  if p_description is null or btrim(p_description) = '' then
    raise exception 'description is required';
  end if;

  if p_qty is null or p_qty < 0 then
    raise exception 'qty must be >= 0';
  end if;

  if p_est_unit_cost is not null and p_est_unit_cost < 0 then
    raise exception 'est_unit_cost must be >= 0';
  end if;

  v_exists := false;
  if p_id is not null then
    select true into v_exists
    from public.purchase_request_lines
    where id = p_id and purchase_request_id = p_purchase_request_id;
  end if;

  if v_exists then
    update public.purchase_request_lines
    set catalog_item_id = p_catalog_item_id,
        description = p_description,
        qty = coalesce(p_qty, qty),
        uom = p_uom,
        est_unit_cost = p_est_unit_cost,
        sov_item_id = p_sov_item_id,
        timeline_task_id = p_timeline_task_id,
        sort_order = coalesce(p_sort_order, sort_order),
        is_active = coalesce(p_is_active, is_active),
        project_id = v_project_id,
        updated_by = p_actor_id,
        updated_at = now()
    where id = p_id
    returning * into v_line;

    perform public.insert_status_log(
      'pr_line',
      v_line.id,
      v_project_id,
      null,
      null,
      'PR line updated',
      jsonb_build_object('purchase_request_id', p_purchase_request_id),
      p_actor_id
    );
  else
    insert into public.purchase_request_lines (
      purchase_request_id, project_id,
      catalog_item_id, description,
      qty, uom,
      est_unit_cost,
      sov_item_id, timeline_task_id,
      sort_order, is_active,
      created_by, updated_by
    ) values (
      p_purchase_request_id, v_project_id,
      p_catalog_item_id, p_description,
      coalesce(p_qty,0), p_uom,
      p_est_unit_cost,
      p_sov_item_id, p_timeline_task_id,
      coalesce(p_sort_order,0), coalesce(p_is_active,true),
      p_actor_id, p_actor_id
    )
    returning * into v_line;

    perform public.insert_status_log(
      'pr_line',
      v_line.id,
      v_project_id,
      null,
      null,
      'PR line created',
      jsonb_build_object('purchase_request_id', p_purchase_request_id),
      p_actor_id
    );
  end if;

  return v_line;
end $$;

-- 3D) PR submit
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
  v_lines_count int;
begin
  perform public.assert_actor_exists(p_actor_id);

  select * into v_old
  from public.purchase_requests
  where id = p_purchase_request_id
  for update;

  if not found then
    raise exception 'PR % not found', p_purchase_request_id;
  end if;

  if v_old.status <> 'draft' then
    raise exception 'Only draft PRs can be submitted';
  end if;

  select count(*) into v_lines_count
  from public.purchase_request_lines
  where purchase_request_id = p_purchase_request_id
    and coalesce(is_active,true) = true;

  if v_lines_count <= 0 then
    raise exception 'Cannot submit PR with zero lines';
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

-- 3E) PR approve/reject
create or replace function public.approve_purchase_request(
  p_purchase_request_id uuid,
  p_actor_id uuid,
  p_approve boolean default true,
  p_message text default null
) returns public.purchase_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old public.purchase_requests;
  v_new public.purchase_requests;
  v_to_status public.pr_status;
begin
  perform public.assert_actor_exists(p_actor_id);

  select * into v_old
  from public.purchase_requests
  where id = p_purchase_request_id
  for update;

  if not found then
    raise exception 'PR % not found', p_purchase_request_id;
  end if;

  if v_old.status <> 'submitted' then
    raise exception 'Only submitted PRs can be approved/rejected';
  end if;

  v_to_status := case when p_approve then 'approved' else 'rejected' end;

  update public.purchase_requests
  set status = v_to_status,
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
    coalesce(p_message, case when p_approve then 'PR approved' else 'PR rejected' end),
    jsonb_build_object('pr_number', v_new.pr_number),
    p_actor_id
  );

  return v_new;
end $$;

-- 3F) PO create (generates po_number)
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
  p_freight_est numeric default 0,
  p_tax_est numeric default 0,
  p_notes text default null
) returns public.purchase_orders
language plpgsql
security definer
set search_path = public
as $$
declare
  v_po public.purchase_orders;
  v_seq bigint;
  v_number text;
begin
  perform public.assert_actor_exists(p_actor_id);

  if not exists (select 1 from public.projects where id = p_project_id) then
    raise exception 'Project % not found', p_project_id;
  end if;

  if not exists (select 1 from public.vendors where id = p_vendor_id and is_active = true) then
    raise exception 'Vendor % not found or inactive', p_vendor_id;
  end if;

  v_seq := public.next_number('po');
  v_number := public.format_doc_number('PO', v_seq);

  insert into public.purchase_orders (
    project_id, vendor_id,
    po_number, status,
    ship_to_name, ship_to_address1, ship_to_address2, ship_to_city, ship_to_state, ship_to_zip,
    needed_by_date, freight_est, tax_est, notes,
    created_by, updated_by
  ) values (
    p_project_id, p_vendor_id,
    v_number, 'draft',
    p_ship_to_name, p_ship_to_address1, p_ship_to_address2, p_ship_to_city, p_ship_to_state, p_ship_to_zip,
    p_needed_by_date, coalesce(p_freight_est,0), coalesce(p_tax_est,0), p_notes,
    p_actor_id, p_actor_id
  )
  returning * into v_po;

  perform public.insert_status_log(
    'purchase_order',
    v_po.id,
    v_po.project_id,
    null,
    v_po.status::text,
    'PO created',
    jsonb_build_object('po_number', v_po.po_number, 'vendor_id', v_po.vendor_id),
    p_actor_id
  );

  return v_po;
end $$;

-- 3G) PO line upsert (header project_id wins)
create or replace function public.upsert_po_line(
  p_purchase_order_id uuid,
  p_actor_id uuid,
  p_id uuid default null,
  p_pr_line_id uuid default null,
  p_catalog_item_id uuid default null,
  p_description text default null,
  p_qty numeric default 0,
  p_uom text default null,
  p_unit_cost numeric default 0,
  p_status public.po_line_status default 'open',
  p_sov_item_id uuid default null,
  p_timeline_task_id uuid default null,
  p_sort_order int default 0,
  p_is_active boolean default true
) returns public.purchase_order_lines
language plpgsql
security definer
set search_path = public
as $$
declare
  v_line public.purchase_order_lines;
  v_exists boolean;
  v_project_id uuid;
begin
  perform public.assert_actor_exists(p_actor_id);

  select project_id into v_project_id
  from public.purchase_orders
  where id = p_purchase_order_id;

  if v_project_id is null then
    raise exception 'PO % not found', p_purchase_order_id;
  end if;

  if p_description is null or btrim(p_description) = '' then
    raise exception 'description is required';
  end if;

  if p_qty is null or p_qty < 0 then
    raise exception 'qty must be >= 0';
  end if;

  if p_unit_cost is null or p_unit_cost < 0 then
    raise exception 'unit_cost must be >= 0';
  end if;

  v_exists := false;
  if p_id is not null then
    select true into v_exists
    from public.purchase_order_lines
    where id = p_id and purchase_order_id = p_purchase_order_id;
  end if;

  if v_exists then
    update public.purchase_order_lines
    set pr_line_id = p_pr_line_id,
        catalog_item_id = p_catalog_item_id,
        description = p_description,
        qty = coalesce(p_qty, qty),
        uom = p_uom,
        unit_cost = coalesce(p_unit_cost, unit_cost),
        status = coalesce(p_status, status),
        sov_item_id = p_sov_item_id,
        timeline_task_id = p_timeline_task_id,
        sort_order = coalesce(p_sort_order, sort_order),
        is_active = coalesce(p_is_active, is_active),
        project_id = v_project_id,
        updated_by = p_actor_id,
        updated_at = now()
    where id = p_id
    returning * into v_line;

    perform public.insert_status_log(
      'po_line',
      v_line.id,
      v_project_id,
      null,
      null,
      'PO line updated',
      jsonb_build_object('purchase_order_id', p_purchase_order_id),
      p_actor_id
    );
  else
    insert into public.purchase_order_lines (
      purchase_order_id, project_id,
      pr_line_id,
      catalog_item_id, description,
      qty, uom,
      unit_cost,
      status,
      sov_item_id, timeline_task_id,
      sort_order, is_active,
      created_by, updated_by
    ) values (
      p_purchase_order_id, v_project_id,
      p_pr_line_id,
      p_catalog_item_id, p_description,
      coalesce(p_qty,0), p_uom,
      coalesce(p_unit_cost,0),
      coalesce(p_status,'open'),
      p_sov_item_id, p_timeline_task_id,
      coalesce(p_sort_order,0), coalesce(p_is_active,true),
      p_actor_id, p_actor_id
    )
    returning * into v_line;

    perform public.insert_status_log(
      'po_line',
      v_line.id,
      v_project_id,
      null,
      null,
      'PO line created',
      jsonb_build_object('purchase_order_id', p_purchase_order_id),
      p_actor_id
    );
  end if;

  return v_line;
end $$;

-- 3H) PO issue/acknowledge
create or replace function public.set_po_status(
  p_purchase_order_id uuid,
  p_new_status public.po_status,
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

  select * into v_old
  from public.purchase_orders
  where id = p_purchase_order_id
  for update;

  if not found then
    raise exception 'PO % not found', p_purchase_order_id;
  end if;

  update public.purchase_orders
  set status = p_new_status,
      issued_at = case when p_new_status = 'issued' then now() else issued_at end,
      acknowledged_at = case when p_new_status = 'acknowledged' then now() else acknowledged_at end,
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
    coalesce(p_message, 'PO status updated'),
    jsonb_build_object('po_number', v_new.po_number),
    p_actor_id
  );

  return v_new;
end $$;

-- 3I) Receipt create (generates receipt_number)
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
  v_seq bigint;
  v_number text;
  v_po_project uuid;
begin
  perform public.assert_actor_exists(p_actor_id);

  if not exists (select 1 from public.projects where id = p_project_id) then
    raise exception 'Project % not found', p_project_id;
  end if;

  if p_purchase_order_id is not null then
    select project_id into v_po_project
    from public.purchase_orders
    where id = p_purchase_order_id;

    if v_po_project is null then
      raise exception 'PO % not found', p_purchase_order_id;
    end if;

    if v_po_project <> p_project_id then
      raise exception 'Receipt project_id must match PO project_id';
    end if;
  end if;

  v_seq := public.next_number('rcv');
  v_number := public.format_doc_number('RCV', v_seq);

  insert into public.receipts (
    project_id, vendor_id, purchase_order_id,
    receipt_number, status,
    received_at, received_by,
    location, notes,
    created_by, updated_by
  ) values (
    p_project_id, p_vendor_id, p_purchase_order_id,
    v_number, 'pending',
    null, null,
    p_location, p_notes,
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
    jsonb_build_object('receipt_number', v_r.receipt_number),
    p_actor_id
  );

  return v_r;
end $$;

-- 3J) Receipt line add/upsert
create or replace function public.upsert_receipt_line(
  p_receipt_id uuid,
  p_actor_id uuid,
  p_id uuid default null,
  p_purchase_order_line_id uuid default null,
  p_description text default null,
  p_qty_received numeric default 0,
  p_uom text default null,
  p_condition text default null,
  p_notes text default null
) returns public.receipt_lines
language plpgsql
security definer
set search_path = public
as $$
declare
  v_line public.receipt_lines;
  v_exists boolean;
  v_project_id uuid;
begin
  perform public.assert_actor_exists(p_actor_id);

  select project_id into v_project_id
  from public.receipts
  where id = p_receipt_id;

  if v_project_id is null then
    raise exception 'Receipt % not found', p_receipt_id;
  end if;

  if p_description is null or btrim(p_description) = '' then
    raise exception 'description is required';
  end if;

  if p_qty_received is null or p_qty_received < 0 then
    raise exception 'qty_received must be >= 0';
  end if;

  v_exists := false;
  if p_id is not null then
    select true into v_exists
    from public.receipt_lines
    where id = p_id and receipt_id = p_receipt_id;
  end if;

  if v_exists then
    update public.receipt_lines
    set purchase_order_line_id = p_purchase_order_line_id,
        description = p_description,
        qty_received = coalesce(p_qty_received, qty_received),
        uom = p_uom,
        condition = p_condition,
        notes = p_notes,
        project_id = v_project_id,
        updated_by = p_actor_id,
        updated_at = now()
    where id = p_id
    returning * into v_line;

    perform public.insert_status_log(
      'receipt_line',
      v_line.id,
      v_project_id,
      null,
      null,
      'Receipt line updated',
      jsonb_build_object('receipt_id', p_receipt_id),
      p_actor_id
    );
  else
    insert into public.receipt_lines (
      receipt_id, project_id,
      purchase_order_line_id,
      description, qty_received, uom,
      condition, notes,
      created_by, updated_by
    ) values (
      p_receipt_id, v_project_id,
      p_purchase_order_line_id,
      p_description, coalesce(p_qty_received,0), p_uom,
      p_condition, p_notes,
      p_actor_id, p_actor_id
    )
    returning * into v_line;

    perform public.insert_status_log(
      'receipt_line',
      v_line.id,
      v_project_id,
      null,
      null,
      'Receipt line created',
      jsonb_build_object('receipt_id', p_receipt_id),
      p_actor_id
    );
  end if;

  return v_line;
end $$;

-- 3K) Mark receipt received/reconciled/cancelled
create or replace function public.set_receipt_status(
  p_receipt_id uuid,
  p_new_status public.receipt_status,
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
begin
  perform public.assert_actor_exists(p_actor_id);

  select * into v_old
  from public.receipts
  where id = p_receipt_id
  for update;

  if not found then
    raise exception 'Receipt % not found', p_receipt_id;
  end if;

  update public.receipts
  set status = p_new_status,
      received_at = case when p_new_status = 'received' and received_at is null then now() else received_at end,
      received_by = case when p_new_status = 'received' and received_by is null then p_actor_id else received_by end,
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
    coalesce(p_message, 'Receipt status updated'),
    jsonb_build_object('receipt_number', v_new.receipt_number),
    p_actor_id
  );

  return v_new;
end $$;

-- -------------------------------
-- 4) RLS: enable on purchasing tables
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
alter table public.number_sequences enable row level security;

-- -------------------------------
-- 5) Policies: authenticated read
-- -------------------------------
-- Vendors
drop policy if exists vendors_read on public.vendors;
create policy vendors_read on public.vendors
for select to authenticated
using (true);

drop policy if exists vendor_contacts_read on public.vendor_contacts;
create policy vendor_contacts_read on public.vendor_contacts
for select to authenticated
using (true);

drop policy if exists catalog_read on public.material_catalog_items;
create policy catalog_read on public.material_catalog_items
for select to authenticated
using (true);

-- PR / PO / Receiving
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

-- Sequences: allow read (optional)
drop policy if exists number_sequences_read on public.number_sequences;
create policy number_sequences_read on public.number_sequences
for select to authenticated
using (true);

-- -------------------------------
-- 6) Policies: explicit deny direct writes
-- -------------------------------
drop policy if exists vendors_no_write on public.vendors;
create policy vendors_no_write on public.vendors
for all to authenticated
using (false) with check (false);

drop policy if exists vendor_contacts_no_write on public.vendor_contacts;
create policy vendor_contacts_no_write on public.vendor_contacts
for all to authenticated
using (false) with check (false);

drop policy if exists catalog_no_write on public.material_catalog_items;
create policy catalog_no_write on public.material_catalog_items
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

drop policy if exists number_sequences_no_write on public.number_sequences;
create policy number_sequences_no_write on public.number_sequences
for all to authenticated
using (false) with check (false);

-- -------------------------------
-- 7) Revoke direct writes at privilege level too
-- -------------------------------
revoke insert, update, delete on public.vendors from authenticated, anon;
revoke insert, update, delete on public.vendor_contacts from authenticated, anon;
revoke insert, update, delete on public.material_catalog_items from authenticated, anon;
revoke insert, update, delete on public.purchase_requests from authenticated, anon;
revoke insert, update, delete on public.purchase_request_lines from authenticated, anon;
revoke insert, update, delete on public.purchase_orders from authenticated, anon;
revoke insert, update, delete on public.purchase_order_lines from authenticated, anon;
revoke insert, update, delete on public.receipts from authenticated, anon;
revoke insert, update, delete on public.receipt_lines from authenticated, anon;
revoke insert, update, delete on public.number_sequences from authenticated, anon;

-- -------------------------------
-- 8) Grant execute on RPCs (authenticated)
-- -------------------------------
grant execute on function public.next_number(text) to authenticated;
grant execute on function public.format_doc_number(text, bigint) to authenticated;

grant execute on function public.upsert_vendor(
  uuid, uuid, text, text, text, text, text, text, text, text, text, text, text, text, boolean
) to authenticated;

grant execute on function public.create_purchase_request(uuid, uuid, date, text, text) to authenticated;
grant execute on function public.upsert_pr_line(uuid, uuid, uuid, uuid, text, numeric, text, numeric, uuid, uuid, int, boolean) to authenticated;
grant execute on function public.submit_purchase_request(uuid, uuid, text) to authenticated;
grant execute on function public.approve_purchase_request(uuid, uuid, boolean, text) to authenticated;

grant execute on function public.create_purchase_order(
  uuid, uuid, uuid, date, text, text, text, text, text, text, numeric, numeric, text
) to authenticated;
grant execute on function public.upsert_po_line(
  uuid, uuid, uuid, uuid, uuid, text, numeric, text, numeric, public.po_line_status, uuid, uuid, int, boolean
) to authenticated;
grant execute on function public.set_po_status(uuid, public.po_status, uuid, text) to authenticated;

grant execute on function public.create_receipt(uuid, uuid, uuid, uuid, text, text) to authenticated;
grant execute on function public.upsert_receipt_line(uuid, uuid, uuid, uuid, text, numeric, text, text, text) to authenticated;
grant execute on function public.set_receipt_status(uuid, public.receipt_status, uuid, text) to authenticated;

-- =========================================================
-- End 0005
-- =========================================================
