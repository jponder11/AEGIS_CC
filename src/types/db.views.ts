// src/types/db.views.ts
// View row types for Aegis. Keep in sync with db/migrations/0003_read_models_views.sql.

export type UUID = string;

export type ProjectStatus =
  | "prospect"
  | "active"
  | "on_hold"
  | "completed"
  | "closed"
  | string; // allow forward-compatible new statuses without breaking builds

export type BillingType = string | null;

export interface VProjectDashboardRow {
  project_id: UUID;
  project_code: string;
  project_name: string;
  project_status: ProjectStatus;

  client_name: string | null;
  gc_name: string | null;

  site_address1: string | null;
  site_address2: string | null;
  site_city: string | null;
  site_state: string | null;
  site_zip: string | null;

  contract_value: number | null;
  start_date: string | null; // date
  end_date: string | null; // date

  pm_user_id: UUID | null;
  pm_name: string | null;
  super_user_id: UUID | null;
  super_name: string | null;

  kickoff_current_id: UUID | null;
  kickoff_baseline_version: number | null;
  kickoff_baseline_date: string | null; // date
  contract_value_baseline: number | null;
  start_date_baseline: string | null; // date
  end_date_baseline: string | null; // date
  billing_type: BillingType;
  retainage_pct: number | null;

  sov_item_count_active: number;
  sov_scheduled_total: number;

  timeline_start_min: string | null; // date
  timeline_end_max: string | null; // date
  task_count_active: number;
  task_count_not_started: number;
  task_count_in_progress: number;
  task_count_blocked: number;
  task_count_complete: number;

  created_at: string; // timestamptz
  updated_at: string; // timestamptz
}

export interface VProjectActivityFeedRow {
  log_id: UUID;

  project_id: UUID | null;
  project_code: string | null;
  project_name: string | null;

  entity_type: string;
  entity_id: UUID | null;

  from_status: string | null;
  to_status: string | null;

  message: string | null;
  metadata: Record<string, unknown> | null;

  created_by: UUID | null;
  created_by_name: string | null;
  created_by_email: string | null;

  created_at: string; // timestamptz
}
