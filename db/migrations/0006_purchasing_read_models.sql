-- =========================================================
-- AEGIS_CC • Migration 0006 • Purchasing Read Models (Phase 6)
-- Purpose:
--   - UI-friendly read models for purchasing dashboards
--   - No writes, no security changes
-- Views:
--   - v_pr_dashboard
--   - v_po_master_log
--   - v_po_line_receipt_coverage
--   - v_receiving_board
--   - v_vendor_hot_sheet
-- =========================================================

-- -------------------------------
-- 0) PO Line Receipt Coverage (foundation view)
-- -------------------------------
drop view if exists public.v_po_line_receipt_coverage;

create view public.v_po_line_receipt_coverage as
select
  pol.id as purchase_order_line_id,
  pol.purchase_order_id,
  pol.project_id,

  pol.pr_line_id,
  pol.catalog_item_id,
  pol.description,
  pol.qty as qty_ordered,
  pol.uom,
  pol.unit_cost,
  pol.ext_cost,
  pol.status as po_line_status,
  pol.is_active,
  pol.sort_order,

  coalesce(sum(rl.qty_received) filter (where r.status <> 'cancelled'), 0) as qty_received_total,
  greatest(
    coalesce(pol.qty, 0) - coalesce(sum(rl.qty_received) filter (where r.status <> 'cancelled'), 0),
    0
  ) as qty_open_remaining,

  case
    when coalesce(pol.qty,0) <= 0 then 'unknown'
    when coalesce(sum(rl.qty_received) filter (where r.status <> 'cancelled'), 0) <= 0 then 'not_received'
    when coalesce(sum(rl.qty_received) filter (where r.status <> 'cancelled'), 0) < coalesce(pol.qty,0) then 'partial'
    else 'received'
  end as receipt_coverage,

  min(r.received_at) filter (where r.status <> 'cancelled') as first_received_at,
  max(r.received_at) filter (where r.status <> 'cancelled') as last_received_at

from public.purchase_order_lines pol
left join public.receipt_lines rl
  on rl.purchase_order_line_id = pol.id
left join public.receipts r
  on r.id = rl.receipt_id
group by
  pol.id, pol.purchase_order_id, pol.project_id,
  pol.pr_line_id, pol.catalog_item_id, pol.description,
  pol.qty, pol.uom, pol.unit_cost, pol.ext_cost,
  pol.status, pol.is_active, pol.sort_order;

-- -------------------------------
-- 1) PR Dashboard (header rollup)
-- -------------------------------
drop view if exists public.v_pr_dashboard;

create view public.v_pr_dashboard as
select
  pr.id as purchase_request_id,
  pr.project_id,
  pr.pr_number,
  pr.status as pr_status,
  pr.needed_by_date,
  pr.priority,
  pr.notes,

  pr.requested_by,
  req.full_name as requested_by_name,

  pr.approved_by,
  appr.full_name as approved_by_name,
  pr.approved_at,

  pr.created_at,
  pr.updated_at,

  coalesce(count(prl.id) filter (where prl.is_active = true), 0) as line_count_active,
  coalesce(sum(prl.qty) filter (where prl.is_active = true), 0) as qty_total_active,
  coalesce(sum(prl.est_ext_cost) filter (where prl.is_active = true), 0) as est_total_active,

  -- simple linkage indicator: how many lines are already tied into PO lines
  coalesce(count(pol.id) filter (where prl.is_active = true), 0) as linked_po_line_count

from public.purchase_requests pr
left join public.profiles req on req.id = pr.requested_by
left join public.profiles appr on appr.id = pr.approved_by
left join public.purchase_request_lines prl on prl.purchase_request_id = pr.id
left join public.purchase_order_lines pol on pol.pr_line_id = prl.id
group by
  pr.id, pr.project_id, pr.pr_number, pr.status, pr.needed_by_date, pr.priority, pr.notes,
  pr.requested_by, req.full_name,
  pr.approved_by, appr.full_name, pr.approved_at,
  pr.created_at, pr.updated_at;

-- -------------------------------
-- 2) PO Master Log (header rollup + coverage)
-- -------------------------------
drop view if exists public.v_po_master_log;

create view public.v_po_master_log as
select
  po.id as purchase_order_id,
  po.project_id,
  po.vendor_id,
  v.name as vendor_name,

  po.po_number,
  po.status as po_status,

  po.issued_at,
  po.acknowledged_at,

  po.ship_to_name,
  po.ship_to_address1,
  po.ship_to_address2,
  po.ship_to_city,
  po.ship_to_state,
  po.ship_to_zip,

  po.needed_by_date,
  coalesce(po.freight_est, 0) as freight_est,
  coalesce(po.tax_est, 0) as tax_est,
  po.notes,

  po.created_at,
  po.updated_at,

  coalesce(count(pol.id) filter (where pol.is_active = true), 0) as line_count_active,
  coalesce(sum(pol.ext_cost) filter (where pol.is_active = true), 0) as lines_total_active,

  -- receipt coverage rollups
  coalesce(sum(cov.qty_received_total) filter (where pol.is_active = true), 0) as qty_received_total,
  coalesce(sum(cov.qty_open_remaining) filter (where pol.is_active = true), 0) as qty_open_remaining,

  coalesce(count(*) filter (where pol.is_active = true and cov.receipt_coverage = 'received'), 0) as lines_fully_received,
  coalesce(count(*) filter (where pol.is_active = true and cov.receipt_coverage = 'partial'), 0) as lines_partially_received,
  coalesce(count(*) filter (where pol.is_active = true and cov.receipt_coverage = 'not_received'), 0) as lines_not_received,

  min(cov.first_received_at) as first_received_at,
  max(cov.last_received_at) as last_received_at

from public.purchase_orders po
left join public.vendors v on v.id = po.vendor_id
left join public.purchase_order_lines pol on pol.purchase_order_id = po.id
left join public.v_po_line_receipt_coverage cov on cov.purchase_order_line_id = pol.id
group by
  po.id, po.project_id, po.vendor_id, v.name,
  po.po_number, po.status,
  po.issued_at, po.acknowledged_at,
  po.ship_to_name, po.ship_to_address1, po.ship_to_address2, po.ship_to_city, po.ship_to_state, po.ship_to_zip,
  po.needed_by_date, po.freight_est, po.tax_est, po.notes,
  po.created_at, po.updated_at;

-- -------------------------------
-- 3) Receiving Board (what arrived, where, tied to PO/vendor)
-- -------------------------------
drop view if exists public.v_receiving_board;

create view public.v_receiving_board as
select
  r.id as receipt_id,
  r.project_id,
  r.vendor_id,
  v.name as vendor_name,
  r.purchase_order_id,
  po.po_number,

  r.receipt_number,
  r.status as receipt_status,

  r.received_at,
  r.received_by,
  rb.full_name as received_by_name,

  r.location,
  r.notes,

  r.created_at,
  r.updated_at,

  coalesce(count(rl.id), 0) as receipt_line_count,
  coalesce(sum(rl.qty_received), 0) as qty_received_total

from public.receipts r
left join public.vendors v on v.id = r.vendor_id
left join public.purchase_orders po on po.id = r.purchase_order_id
left join public.profiles rb on rb.id = r.received_by
left join public.receipt_lines rl on rl.receipt_id = r.id
group by
  r.id, r.project_id, r.vendor_id, v.name, r.purchase_order_id, po.po_number,
  r.receipt_number, r.status, r.received_at, r.received_by, rb.full_name,
  r.location, r.notes, r.created_at, r.updated_at;

-- -------------------------------
-- 4) Vendor Hot Sheet (spend + activity summary)
-- -------------------------------
drop view if exists public.v_vendor_hot_sheet;

create view public.v_vendor_hot_sheet as
select
  v.id as vendor_id,
  v.name as vendor_name,
  v.trade,
  v.phone,
  v.email,
  v.website,
  v.payment_terms,
  v.is_active,

  coalesce(count(distinct po.id), 0) as po_count,
  coalesce(count(distinct po.project_id), 0) as project_count,

  -- totals based on PO lines (commitments)
  coalesce(sum(pol.ext_cost) filter (where pol.is_active = true), 0) as committed_total,

  -- receipt signal (qty-based, not dollars)
  coalesce(sum(cov.qty_received_total) filter (where pol.is_active = true), 0) as qty_received_total,
  coalesce(sum(cov.qty_open_remaining) filter (where pol.is_active = true), 0) as qty_open_remaining,

  max(po.created_at) as last_po_created_at,
  max(r.received_at) as last_received_at

from public.vendors v
left join public.purchase_orders po on po.vendor_id = v.id
left join public.purchase_order_lines pol on pol.purchase_order_id = po.id
left join public.v_po_line_receipt_coverage cov on cov.purchase_order_line_id = pol.id
left join public.receipts r on r.purchase_order_id = po.id and r.status <> 'cancelled'
group by
  v.id, v.name, v.trade, v.phone, v.email, v.website, v.payment_terms, v.is_active;

-- =========================================================
-- End 0006
-- =========================================================
