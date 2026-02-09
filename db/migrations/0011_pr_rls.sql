alter table public.purchase_requests enable row level security;
alter table public.purchase_request_lines enable row level security;

-- Read access (tune later to project membership)
drop policy if exists pr_read on public.purchase_requests;
create policy pr_read
on public.purchase_requests
for select
to authenticated
using (true);

drop policy if exists prl_read on public.purchase_request_lines;
create policy prl_read
on public.purchase_request_lines
for select
to authenticated
using (true);

-- No direct writes from clients
drop policy if exists pr_no_write on public.purchase_requests;
create policy pr_no_write
on public.purchase_requests
for all
to authenticated
using (false)
with check (false);

drop policy if exists prl_no_write on public.purchase_request_lines;
create policy prl_no_write
on public.purchase_request_lines
for all
to authenticated
using (false)
with check (false);
