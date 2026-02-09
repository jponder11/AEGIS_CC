create or replace view public.v_pr_totals as
select
  pr.id as pr_id,
  coalesce(sum(prl.qty * prl.unit_cost), 0)::numeric(12,2) as subtotal
from public.purchase_requests pr
left join public.purchase_request_lines prl
  on prl.pr_id = pr.id
group by pr.id;
