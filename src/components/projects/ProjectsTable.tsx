"use client";

import Link from "next/link";
import { useMemo, useState } from "react";

import type { ProjectDashboardRow } from "./types";

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

type ProjectsTableProps = {
  projects: ProjectDashboardRow[];
};

const normalize = (value: string) => value.trim().toLowerCase();

export default function ProjectsTable({ projects }: ProjectsTableProps) {
  const [search, setSearch] = useState("");
  const [status, setStatus] = useState("all");

  const statusOptions = useMemo(() => {
    const uniqueStatuses = new Set<string>();
    projects.forEach((project) => {
      if (project.project_status) {
        uniqueStatuses.add(project.project_status);
      }
    });
    return ["all", ...Array.from(uniqueStatuses).sort((a, b) => a.localeCompare(b))];
  }, [projects]);

  const filteredProjects = useMemo(() => {
    const query = normalize(search);

    return projects
      .filter((project) => {
        if (status !== "all" && project.project_status !== status) {
          return false;
        }

        if (!query) return true;

        const code = project.project_code ?? "";
        const name = project.project_name ?? "";
        return (
          normalize(code).includes(query) || normalize(name).includes(query)
        );
      })
      .sort((a, b) =>
        (a.project_code ?? "").localeCompare(b.project_code ?? ""),
      );
  }, [projects, search, status]);

  return (
    <section className="space-y-4">
      <div className="flex flex-wrap items-end gap-4">
        <label className="flex flex-col gap-2 text-sm font-medium text-slate-600">
          Search
          <input
            className="w-64 rounded-md border border-slate-200 px-3 py-2 text-sm text-slate-900"
            placeholder="Project code or name"
            value={search}
            onChange={(event) => setSearch(event.target.value)}
          />
        </label>
        <label className="flex flex-col gap-2 text-sm font-medium text-slate-600">
          Status
          <select
            className="w-48 rounded-md border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900"
            value={status}
            onChange={(event) => setStatus(event.target.value)}
          >
            {statusOptions.map((option) => (
              <option key={option} value={option}>
                {option === "all" ? "All" : option}
              </option>
            ))}
          </select>
        </label>
      </div>

      <div className="overflow-x-auto rounded-lg border border-slate-200 bg-white">
        <table className="min-w-full divide-y divide-slate-200 text-sm">
          <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
            <tr>
              <th className="px-4 py-3 text-left">Code</th>
              <th className="px-4 py-3 text-left">Name</th>
              <th className="px-4 py-3 text-left">Status</th>
              <th className="px-4 py-3 text-left">PM</th>
              <th className="px-4 py-3 text-left">Super</th>
              <th className="px-4 py-3 text-left">Contract value</th>
              <th className="px-4 py-3 text-left">SOV scheduled</th>
              <th className="px-4 py-3 text-left">Timeline start</th>
              <th className="px-4 py-3 text-left">Timeline end</th>
              <th className="px-4 py-3 text-left">In progress</th>
              <th className="px-4 py-3 text-left">Blocked</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {filteredProjects.length === 0 ? (
              <tr>
                <td
                  className="px-4 py-6 text-center text-sm text-slate-500"
                  colSpan={11}
                >
                  No projects match the current filters.
                </td>
              </tr>
            ) : (
              filteredProjects.map((project) => (
                <tr key={project.project_id} className="hover:bg-slate-50">
                  <td className="px-4 py-3 font-semibold text-slate-900">
                    <Link
                      className="text-blue-600 hover:text-blue-800"
                      href={`/projects/${project.project_id}`}
                    >
                      {project.project_code || "—"}
                    </Link>
                  </td>
                  <td className="px-4 py-3 text-slate-700">
                    {project.project_name || "—"}
                  </td>
                  <td className="px-4 py-3 text-slate-700">
                    {project.project_status || "—"}
                  </td>
                  <td className="px-4 py-3 text-slate-700">
                    {project.pm_name || "—"}
                  </td>
                  <td className="px-4 py-3 text-slate-700">
                    {project.super_name || "—"}
                  </td>
                  <td className="px-4 py-3 text-slate-700">
                    {formatCurrency(project.contract_value)}
                  </td>
                  <td className="px-4 py-3 text-slate-700">
                    {formatCurrency(project.sov_scheduled_total)}
                  </td>
                  <td className="px-4 py-3 text-slate-700">
                    {formatDate(project.timeline_start_min)}
                  </td>
                  <td className="px-4 py-3 text-slate-700">
                    {formatDate(project.timeline_end_max)}
                  </td>
                  <td className="px-4 py-3 text-slate-700">
                    {project.task_count_in_progress ?? "—"}
                  </td>
                  <td className="px-4 py-3 text-slate-700">
                    {project.task_count_blocked ?? "—"}
                  </td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
    </section>
  );
}
