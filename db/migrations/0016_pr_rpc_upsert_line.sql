create or replace function public.rpc_pr_upsert_line(
  p_pr_id uuid,
  p_line_id uuid default null,
  p_item_name text,
  p_qty numeric,
  p_unit text default null,
  p_unit_cost numeric default 0,
  p_vendor_id uuid default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
as $$
declare
  v_uid uuid;
  v_status public.pr_status;
  v_created_by uuid;
  v_line_id uuid;
begin
  v_uid := public._require_auth();

  select status, created_by
    into v_status, v_created_by
  from public.purchase_requests
  where id = p_pr_id;

  if not found then
    raise exception 'PR not found';
  end if;

  if v_status <> 'draft' then
    raise exception 'Only draft PRs can be edited';
  end if;

  if v_created_by <> v_uid and not public.has_role(v_uid, 'purchasing_admin') then
    raise exception 'Not allowed';
  end if;

  if p_qty is null or p_qty <= 0 then
    raise exception 'Qty must be > 0';
  end if;

  if p_item_name is null or length(trim(p_item_name)) = 0 then
    raise exception 'Item name is required';
  end if;

  if p_line_id is null then
    insert into public.purchase_request_lines (
      pr_id, item_name, qty, unit, unit_cost, vendor_id, notes, created_at, updated_at
    )
    values (
      p_pr_id, trim(p_item_name), p_qty, p_unit, coalesce(p_unit_cost,0), p_vendor_id, p_notes, now(), now()
    )
    returning id into v_line_id;
  else
    update public.purchase_request_lines
    set
      item_name = trim(p_item_name),
      qty = p_qty,
      unit = p_unit,
      unit_cost = coalesce(p_unit_cost,0),
      vendor_id = p_vendor_id,
      notes = p_notes,
      updated_at = now()
    where id = p_line_id
      and pr_id = p_pr_id
    returning id into v_line_id;

    if v_line_id is null then
      raise exception 'Line not found';
    end if;
  end if;

  update public.purchase_requests
  set updated_at = now()
  where id = p_pr_id;

  return v_line_id;
end;
$$;

alter function public.rpc_pr_upsert_line(uuid, uuid, text, numeric, text, numeric, uuid, text) set search_path = public, auth;
