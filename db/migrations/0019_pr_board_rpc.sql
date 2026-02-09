create or replace function public.rpc_pr_board(p_project_id uuid default null)
returns table (
  pr_id uuid,
  project_id uuid,
  title text,
  status public.pr_status,
  created_at timestamptz,
  updated_at timestamptz,
  created_by uuid,
  submitted_at timestamptz,
  subtotal numeric(12,2),
  can_edit boolean,
  can_submit boolean,
  can_approve boolean,
  can_reject boolean
)
language plpgsql
security definer
as $$
declare
  v_uid uuid;
  v_is_admin boolean;
  v_is_approver boolean;
begin
  v_uid := public._require_auth();
  v_is_admin := public.has_role(v_uid, 'purchasing_admin');
  v_is_approver := public.has_role(v_uid, 'purchasing_approver');

  return query
  select
    pr.id,
    pr.project_id,
    pr.title,
    pr.status,
    pr.created_at,
    pr.updated_at,
    pr.created_by,
    pr.submitted_at,
    coalesce(t.subtotal, 0)::numeric(12,2) as subtotal,

    -- can_edit
    (pr.status = 'draft' and (pr.created_by = v_uid or v_is_admin)) as can_edit,

    -- can_submit
    (pr.status = 'draft'
      and (pr.created_by = v_uid or v_is_admin)
      and exists (select 1 from public.purchase_request_lines l where l.pr_id = pr.id)
    ) as can_submit,

    -- can_approve / can_reject
    (pr.status = 'submitted' and (v_is_admin or v_is_approver)) as can_approve,
    (pr.status = 'submitted' and (v_is_admin or v_is_approver)) as can_reject
  from public.purchase_requests pr
  left join public.v_pr_totals t on t.pr_id = pr.id
  where (p_project_id is null or pr.project_id = p_project_id)
  order by pr.updated_at desc;
end;
$$;

alter function public.rpc_pr_board(uuid) set search_path = public, auth;
