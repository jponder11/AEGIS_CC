create or replace function public.rpc_pr_create(
  p_project_id uuid,
  p_title text default null,
  p_need_by date default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
as $$
declare
  v_uid uuid;
  v_pr_id uuid;
begin
  v_uid := public._require_auth();

  insert into public.purchase_requests (
    project_id, title, need_by, notes,
    status, created_by, created_at, updated_at
  )
  values (
    p_project_id,
    coalesce(nullif(trim(p_title), ''), 'New PR'),
    p_need_by,
    p_notes,
    'draft'::public.pr_status,
    v_uid,
    now(),
    now()
  )
  returning id into v_pr_id;

  return v_pr_id;
end;
$$;

alter function public.rpc_pr_create(uuid, text, date, text) set search_path = public, auth;
