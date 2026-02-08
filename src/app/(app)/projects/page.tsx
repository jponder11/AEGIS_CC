import { createClient } from "@/lib/supabase/server";
import ProjectsTable from "@/components/projects/ProjectsTable";
import type { ProjectDashboardRow } from "@/components/projects/types";

export default async function ProjectsPage() {
  const supabase = createClient();

  const { data, error } = await supabase
    .from("v_project_dashboard")
    .select(
      "project_id, project_code, project_name, project_status, pm_name, super_name, contract_value, sov_scheduled_total, timeline_start_min, timeline_end_max, task_count_in_progress, task_count_blocked",
    )
    .order("project_code", { ascending: true })
    .returns<ProjectDashboardRow[]>();

  if (error) {
    throw new Error("Unable to load projects.");
  }

  return (
    <main className="space-y-6 bg-slate-50 px-6 py-10 text-slate-900">
      <header className="space-y-2">
        <p className="text-sm font-semibold uppercase tracking-wide text-slate-500">
          Projects
        </p>
        <h1 className="text-3xl font-semibold text-slate-900">
          Project portfolio
        </h1>
        <p className="text-sm text-slate-600">
          Browse active projects and review high-level schedule and SOV rollups.
        </p>
      </header>

      <ProjectsTable projects={data ?? []} />
    </main>
  );
}
