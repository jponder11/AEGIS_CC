/**
 * Aegis CC — Purchasing read models (Phase 6)
 * Matches db/migrations/0006_purchasing_read_models_views.sql
 */

export type UUID = string;
export type ISODate = string; // YYYY-MM-DD
export type ISODateTime = string; // timestamptz ISO string

// ===== v_po_line_receipt_coverage =====
export type VPoLineReceiptCoverage = {
  purchase_order_line_id: UUID;
  purchase_order_id: UUID;
  project_id: UUID;

  pr_line_id: UUID | null;
  catalog_item_id: UUID | null;
  description: string;

  qty_ordered: number;
  uom: string | null;

  unit_cost: number;
  ext_cost: number;

  po_line_status: string; // 'open' | 'backordered' | 'cancelled' | 'closed'
  is_active: boolean;
  sort_order: number;

  qty_received_total: number;
  qty_open_remaining: number;

  receipt_coverage: "unknown" | "not_received" | "partial" | "received";

  first_received_at: ISODateTime | null;
  last_received_at: ISODateTime | null;
};

// ===== v_pr_dashboard =====
export type VPrDashboard = {
  purchase_request_id: UUID;
  project_id: UUID;

  pr_number: string;
  pr_status: string; // 'draft' | 'submitted' | 'approved' | 'rejected' | 'cancelled' | 'fulfilled'

  needed_by_date: ISODate | null;
  priority: string | null;
  notes: string | null;

  requested_by: UUID | null;
  requested_by_name: string | null;

  approved_by: UUID | null;
  approved_by_name: string | null;
  approved_at: ISODateTime | null;

  created_at: ISODateTime;
  updated_at: ISODateTime;

  line_count_active: number;
  qty_total_active: number;
  est_total_active: number;

  linked_po_line_count: number;
};

// ===== v_po_master_log =====
export type VPoMasterLog = {
  purchase_order_id: UUID;
  project_id: UUID;

  vendor_id: UUID;
  vendor_name: string | null;

  po_number: string;
  po_status: string; // 'draft' | 'issued' | 'acknowledged' | 'partially_received' | 'received' | 'closed' | 'cancelled'

  issued_at: ISODateTime | null;
  acknowledged_at: ISODateTime | null;

  ship_to_name: string | null;
  ship_to_address1: string | null;
  ship_to_address2: string | null;
  ship_to_city: string | null;
  ship_to_state: string | null;
  ship_to_zip: string | null;

  needed_by_date: ISODate | null;
  freight_est: number;
  tax_est: number;
  notes: string | null;

  created_at: ISODateTime;
  updated_at: ISODateTime;

  line_count_active: number;
  lines_total_active: number;

  qty_received_total: number;
  qty_open_remaining: number;

  lines_fully_received: number;
  lines_partially_received: number;
  lines_not_received: number;

  first_received_at: ISODateTime | null;
  last_received_at: ISODateTime | null;
};

// ===== v_receiving_board =====
export type VReceivingBoard = {
  receipt_id: UUID;
  project_id: UUID;

  vendor_id: UUID | null;
  vendor_name: string | null;

  purchase_order_id: UUID | null;
  po_number: string | null;

  receipt_number: string;
  receipt_status: string; // 'pending' | 'received' | 'reconciled' | 'cancelled'

  received_at: ISODateTime | null;
  received_by: UUID | null;
  received_by_name: string | null;

  location: string | null;
  notes: string | null;

  created_at: ISODateTime;
  updated_at: ISODateTime;

  receipt_line_count: number;
  qty_received_total: number;
};

// ===== v_vendor_hot_sheet =====
export type VVendorHotSheet = {
  vendor_id: UUID;
  vendor_name: string;

  trade: string | null;
  phone: string | null;
  email: string | null;
  website: string | null;
  payment_terms: string | null;

  is_active: boolean;

  po_count: number;
  project_count: number;

  committed_total: number;

  qty_received_total: number;
  qty_open_remaining: number;

  last_po_created_at: ISODateTime | null;
  last_received_at: ISODateTime | null;
};
