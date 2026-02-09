create or replace function public.rpc_pr_submit(p_pr_id uuid)
returns void
language plpgsql
security definer
as $$
declare
  v_uid uuid;
  v_status public.pr_status;
  v_created_by uuid;
  v_line_count int;
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
    raise exception 'Only draft PRs can be submitted';
  end if;

  if v_created_by <> v_uid and not public.has_role(v_uid, 'purchasing_admin') then
    raise exception 'Not allowed';
  end if;

  select count(*) into v_line_count
  from public.purchase_request_lines
  where pr_id = p_pr_id;

  if v_line_count < 1 then
    raise exception 'Add at least one line before submitting';
  end if;

  update public.purchase_requests
  set
    status = 'submitted'::public.pr_status,
    submitted_at = now(),
    updated_at = now()
  where id = p_pr_id;
end;
$$;

alter function public.rpc_pr_submit(uuid) set search_path = public, auth;
