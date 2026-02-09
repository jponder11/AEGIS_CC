create or replace function public.rpc_pr_update_header(
  p_pr_id uuid,
  p_title text,
  p_need_by date,
  p_notes text
)
returns void
language plpgsql
security definer
as $$
declare
  v_uid uuid;
  v_status public.pr_status;
  v_created_by uuid;
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

  -- optional: only creator can edit drafts
  if v_created_by <> v_uid and not public.has_role(v_uid, 'purchasing_admin') then
    raise exception 'Not allowed';
  end if;

  update public.purchase_requests
  set
    title = coalesce(nullif(trim(p_title), ''), title),
    need_by = p_need_by,
    notes = p_notes,
    updated_at = now()
  where id = p_pr_id;
end;
$$;

alter function public.rpc_pr_update_header(uuid, text, date, text) set search_path = public, auth;
