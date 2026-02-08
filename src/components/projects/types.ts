export type ProjectDashboardRow = {
  project_id: string;
  project_code?: string | null;
  project_name?: string | null;
  project_status?: string | null;
  pm_name?: string | null;
  super_name?: string | null;
  contract_value?: number | null;
  sov_scheduled_total?: number | null;
  timeline_start_min?: string | null;
  timeline_end_max?: string | null;
  task_count_in_progress?: number | null;
  task_count_blocked?: number | null;
};
