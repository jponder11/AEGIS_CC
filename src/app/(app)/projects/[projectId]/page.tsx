import { notFound } from "next/navigation";

import { createClient } from "@/lib/supabase/server";

type ProjectDashboardRow = {
  project_id: string;
  project_code?: string | null;
  project_name?: string | null;
  project_status?: string | null;
  client_name?: string | null;
  gc_name?: string | null;
  contract_value?: number | null;
  start_date?: string | null;
  end_date?: string | null;
  sov_item_count_active?: number | null;
  sov_scheduled_total?: number | null;
  task_count_active?: number | null;
  task_count_not_started?: number | null;
  task_count_in_progress?: number | null;
  task_count_blocked?: number | null;
  task_count_complete?: number | null;
};

type ActivityFeedRow = {
  log_id?: string | number;
  project_id?: string | null;
  entity_type?: string | null;
  message?: string | null;
  created_by_name?: string | null;
  created_at?: string | null;
};

const currencyFormatter = new Intl.NumberFormat("en-US", {
  style: "currency",
  currency: "USD",
  maximumFractionDigits: 0,
});

const dateFormatter = new Intl.DateTimeFormat("en-US", {
  month: "short",
  day: "2-digit",
  year: "numeric",
});

const formatCurrency = (value?: number | null) => {
  if (value === null || value === undefined) return "—";
  return currencyFormatter.format(value);
};

const formatDate = (value?: string | null) => {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "—";
  return dateFormatter.format(date);
};

type FactItemProps = {
  label: string;
  value: React.ReactNode;
};

const FactItem = ({ label, value }: FactItemProps) => (
  <div className="rounded-lg border border-slate-200 bg-white p-4 shadow-sm">
    <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">
      {label}
    </p>
    <p className="mt-2 text-sm text-slate-900">{value}</p>
  </div>
);

type CountCardProps = {
  label: string;
  value: number | string;
};

const CountCard = ({ label, value }: CountCardProps) => (
  <div className="rounded-lg border border-slate-200 bg-white p-4 shadow-sm">
    <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">
      {label}
    </p>
    <p className="mt-2 text-2xl font-semibold text-slate-900">{value}</p>
  </div>
);

export default async function ProjectPage({
  params,
}: {
  params: { projectId: string };
}) {
  const supabase = createClient();

  const { data: project, error: projectError } = await supabase
    .from("v_project_dashboard")
    .select("*")
    .eq("project_id", params.projectId)
    .single<ProjectDashboardRow>();

  if (projectError || !project) {
    notFound();
  }

  const { data: activity = [] } = await supabase
    .from("v_project_activity_feed")
    .select("*")
    .eq("project_id", params.projectId)
    .order("created_at", { ascending: false })
    .limit(8)
    .returns<ActivityFeedRow[]>();

  return (
    <main className="space-y-10 bg-slate-50 px-6 py-10 text-slate-900">
      <section className="space-y-3">
        <p className="text-sm font-semibold uppercase tracking-wide text-slate-500">
          Project {project.project_code || ""}
        </p>
        <h1 className="text-3xl font-semibold text-slate-900">
          {project.project_name || "Untitled project"}
        </h1>
        <div className="inline-flex items-center gap-2 rounded-full border border-slate-200 bg-white px-3 py-1 text-sm text-slate-600">
          <span className="h-2 w-2 rounded-full bg-emerald-400" />
          <span>{project.project_status || "Status unknown"}</span>
        </div>
      </section>

      <section className="space-y-4">
        <h2 className="text-lg font-semibold text-slate-800">Key facts</h2>
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <FactItem label="Client" value={project.client_name || "—"} />
          <FactItem label="General contractor" value={project.gc_name || "—"} />
          <FactItem
            label="Contract value"
            value={formatCurrency(project.contract_value)}
          />
          <FactItem
            label="Project dates"
            value={`${formatDate(project.start_date)} → ${formatDate(
              project.end_date,
            )}`}
          />
        </div>
      </section>

      <section className="grid gap-6 lg:grid-cols-3">
        <div className="space-y-4">
          <h2 className="text-lg font-semibold text-slate-800">SOV summary</h2>
          <div className="grid gap-4 sm:grid-cols-2">
            <CountCard
              label="Line items"
              value={project.sov_item_count_active ?? "—"}
            />
            <CountCard
              label="Total"
              value={formatCurrency(project.sov_scheduled_total)}
            />
          </div>
        </div>

        <div className="space-y-4 lg:col-span-2">
          <h2 className="text-lg font-semibold text-slate-800">
            Timeline summary
          </h2>
          <div className="grid gap-4 sm:grid-cols-3">
            <CountCard
              label="Total milestones"
              value={project.task_count_active ?? "—"}
            />
            <CountCard
              label="In progress"
              value={project.task_count_in_progress ?? "—"}
            />
            <CountCard
              label="Completed"
              value={project.task_count_complete ?? "—"}
            />
          </div>
        </div>
      </section>

      <section className="space-y-4">
        <h2 className="text-lg font-semibold text-slate-800">
          Recent activity
        </h2>
        <div className="space-y-3">
          {activity.length === 0 ? (
            <p className="rounded-lg border border-dashed border-slate-200 bg-white p-6 text-sm text-slate-500">
              No recent activity yet.
            </p>
          ) : (
            activity.map((item, index) => (
              <div
                key={item.log_id ?? `${item.created_at}-${index}`}
                className="rounded-lg border border-slate-200 bg-white p-4 shadow-sm"
              >
                <div className="flex flex-wrap items-center justify-between gap-2 text-xs font-semibold uppercase tracking-wide text-slate-500">
                  <span>{item.entity_type || "Update"}</span>
                  <span>{formatDate(item.created_at)}</span>
                </div>
                <p className="mt-2 text-sm text-slate-900">
                  {item.message || "Activity logged."}
                </p>
                {item.created_by_name ? (
                  <p className="mt-2 text-xs text-slate-500">
                    By {item.created_by_name}
                  </p>
                ) : null}
              </div>
            ))
          )}
        </div>
      </section>
    </main>
  );
}
