-- 0020_pr_po_linkage.sql

alter table public.purchase_requests
  add column if not exists po_id uuid null,
  add column if not exists converted_at timestamptz null,
  add column if not exists converted_by uuid null;

alter table public.purchase_request_lines
  add column if not exists po_line_id uuid null;

alter table public.purchase_orders
  add column if not exists source_pr_id uuid null;

alter table public.purchase_order_lines
  add column if not exists source_pr_line_id uuid null;

-- Prevent duplicate conversion
do $$
begin
  if not exists (
    select 1 from pg_indexes where schemaname='public' and indexname='purchase_orders_source_pr_id_uq'
  ) then
    create unique index purchase_orders_source_pr_id_uq
      on public.purchase_orders(source_pr_id)
      where source_pr_id is not null;
  end if;
end $$;

-- FK links (optional but recommended)
alter table public.purchase_requests
  add constraint if not exists purchase_requests_po_fk
  foreign key (po_id) references public.purchase_orders(id);

alter table public.purchase_orders
  add constraint if not exists purchase_orders_source_pr_fk
  foreign key (source_pr_id) references public.purchase_requests(id);

alter table public.purchase_order_lines
  add constraint if not exists pol_source_pr_line_fk
  foreign key (source_pr_line_id) references public.purchase_request_lines(id);
