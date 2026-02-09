-- 0021_pr_convert_to_po_rpc.sql

create or replace function public.rpc_pr_convert_to_po(
  p_pr_id uuid,
  p_vendor_id uuid,
  p_ship_to text default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
as $$
declare
  v_uid uuid;
  v_is_admin boolean;
  v_is_approver boolean;
  v_pr_status public.pr_status;
  v_existing_po uuid;
  v_po_id uuid;
  v_line_count int;
begin
  v_uid := public._require_auth();
  v_is_admin := public.has_role(v_uid, 'purchasing_admin');
  v_is_approver := public.has_role(v_uid, 'purchasing_approver');

  if not (v_is_admin or v_is_approver) then
    raise exception 'Not allowed';
  end if;

  select status, po_id
    into v_pr_status, v_existing_po
  from public.purchase_requests
  where id = p_pr_id
  for update;

  if not found then
    raise exception 'PR not found';
  end if;

  if v_pr_status <> 'approved' then
    raise exception 'PR must be approved to convert to PO';
  end if;

  if v_existing_po is not null then
    raise exception 'PR already converted to PO';
  end if;

  if p_vendor_id is null then
    raise exception 'Vendor is required';
  end if;

  select count(*) into v_line_count
  from public.purchase_request_lines
  where pr_id = p_pr_id;

  if v_line_count < 1 then
    raise exception 'PR has no lines';
  end if;

  -- Create PO header
  insert into public.purchase_orders (
    vendor_id,
    ship_to,
    notes,
    status,
    source_pr_id,
    created_by,
    created_at,
    updated_at
  )
  values (
    p_vendor_id,
    p_ship_to,
    p_notes,
    'draft'::public.po_status,
    p_pr_id,
    v_uid,
    now(),
    now()
  )
  returning id into v_po_id;

  -- Copy lines
  insert into public.purchase_order_lines (
    po_id,
    item_name,
    qty,
    unit,
    unit_cost,
    notes,
    source_pr_line_id,
    created_at,
    updated_at
  )
  select
    v_po_id,
    l.item_name,
    l.qty,
    l.unit,
    l.unit_cost,
    l.notes,
    l.id,
    now(),
    now()
  from public.purchase_request_lines l
  where l.pr_id = p_pr_id;

  -- Link PR to PO
  update public.purchase_requests
  set
    po_id = v_po_id,
    converted_at = now(),
    converted_by = v_uid,
    updated_at = now()
  where id = p_pr_id;

  return v_po_id;
end;
$$;

alter function public.rpc_pr_convert_to_po(uuid, uuid, text, text)
  set search_path = public, auth;
