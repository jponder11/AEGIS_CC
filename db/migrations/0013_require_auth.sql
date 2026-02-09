create or replace function public._require_auth()
returns uuid
language plpgsql
security definer
as $$
declare v_uid uuid;
begin
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;
  return v_uid;
end;
$$;

-- lock down search_path for security definer functions
alter function public._require_auth() set search_path = public, auth;
