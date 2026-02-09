create or replace function public.rpc_pr_approve(p_pr_id uuid)
returns void
language plpgsql
security definer
as $$
declare
  v_uid uuid;
  v_status public.pr_status;
begin
  v_uid := public._require_auth();

  if not (public.has_role(v_uid, 'purchasing_approver') or public.has_role(v_uid, 'purchasing_admin')) then
    raise exception 'Not allowed';
  end if;

  select status into v_status
  from public.purchase_requests
  where id = p_pr_id;

  if not found then
    raise exception 'PR not found';
  end if;

  if v_status <> 'submitted' then
    raise exception 'Only submitted PRs can be approved';
  end if;

  update public.purchase_requests
  set
    status = 'approved'::public.pr_status,
    approved_at = now(),
    approved_by = v_uid,
    updated_at = now()
  where id = p_pr_id;
end;
$$;

alter function public.rpc_pr_approve(uuid) set search_path = public, auth;

create or replace function public.rpc_pr_reject(p_pr_id uuid, p_reason text)
returns void
language plpgsql
security definer
as $$
declare
  v_uid uuid;
  v_status public.pr_status;
begin
  v_uid := public._require_auth();

  if not (public.has_role(v_uid, 'purchasing_approver') or public.has_role(v_uid, 'purchasing_admin')) then
    raise exception 'Not allowed';
  end if;

  select status into v_status
  from public.purchase_requests
  where id = p_pr_id;

  if not found then
    raise exception 'PR not found';
  end if;

  if v_status <> 'submitted' then
    raise exception 'Only submitted PRs can be rejected';
  end if;

  update public.purchase_requests
  set
    status = 'rejected'::public.pr_status,
    rejected_at = now(),
    rejected_by = v_uid,
    reject_reason = nullif(trim(p_reason),''),
    updated_at = now()
  where id = p_pr_id;
end;
$$;

alter function public.rpc_pr_reject(uuid, text) set search_path = public, auth;
