create table if not exists public.user_roles (
  user_id uuid not null,
  role text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, role)
);

create index if not exists user_roles_user_id_idx on public.user_roles(user_id);

create or replace function public.has_role(p_user uuid, p_role text)
returns boolean
language sql
stable
as $$
  select exists (
    select 1
    from public.user_roles ur
    where ur.user_id = p_user
      and ur.role = p_role
  );
$$;
