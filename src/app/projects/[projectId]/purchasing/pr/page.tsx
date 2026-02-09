"use client";

import { useEffect, useMemo, useState } from "react";
import { useRouter, useParams } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

type PrStatus =
  | "draft"
  | "submitted"
  | "approved"
  | "rejected"
  | "cancelled"
  | "fulfilled";

type PrBoardRow = {
  pr_id: string;
  project_id: string;
  title: string;
  status: PrStatus;
  created_at: string;
  updated_at: string;
  created_by: string;
  submitted_at: string | null;
  subtotal: number;
  can_edit: boolean;
  can_submit: boolean;
  can_approve: boolean;
  can_reject: boolean;
};

export default function PrBoardPage() {
  const supabase = useMemo(() => createClient(), []);
  const router = useRouter();
  const params = useParams<{ projectId: string }>();

  const projectId = params?.projectId ?? "";

  const [rows, setRows] = useState<PrBoardRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function load() {
    if (!projectId) return;

    setLoading(true);
    setErr(null);

    const { data, error } = await supabase.rpc("rpc_pr_board", {
      p_project_id: projectId,
    });

    if (error) {
      setErr(error.message);
      setRows([]);
    } else {
      setRows((data ?? []) as PrBoardRow[]);
    }

    setLoading(false);
  }

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [projectId]);

  async function createDraft() {
    setErr(null);
    setBusyId("create");
    const { data: prId, error } = await supabase.rpc("rpc_pr_create", {
      p_project_id: projectId,
      p_title: "New PR",
      p_need_by: null,
      p_notes: null,
    });

    setBusyId(null);

    if (error) return setErr(error.message);

    const prIdValue = prId as string;
    router.push(`/projects/${projectId}/purchasing/pr/${prIdValue}`);
  }

  async function submit(prId: string) {
    setErr(null);
    setBusyId(prId);
    const { error } = await supabase.rpc("rpc_pr_submit", { p_pr_id: prId });
    setBusyId(null);
    if (error) return setErr(error.message);
    await load();
  }

  async function approve(prId: string) {
    setErr(null);
    setBusyId(prId);
    const { error } = await supabase.rpc("rpc_pr_approve", { p_pr_id: prId });
    setBusyId(null);
    if (error) return setErr(error.message);
    await load();
  }

  async function reject(prId: string) {
    const reason = window.prompt("Reject reason (optional):") ?? "";
    setErr(null);
    setBusyId(prId);
    const { error } = await supabase.rpc("rpc_pr_reject", {
      p_pr_id: prId,
      p_reason: reason,
    });
    setBusyId(null);
    if (error) return setErr(error.message);
    await load();
  }

  function goToDetail(prId: string) {
    router.push(`/projects/${projectId}/purchasing/pr/${prId}`);
  }

  return (
    <div style={{ padding: 16 }}>
      <div style={{ display: "flex", gap: 12, alignItems: "center", marginBottom: 12 }}>
        <h2 style={{ margin: 0 }}>Purchase Requests</h2>
        <button onClick={createDraft} disabled={!projectId || busyId === "create"}>
          {busyId === "create" ? "Creating..." : "Create PR"}
        </button>
        <button onClick={load} disabled={!projectId || loading}>
          Refresh
        </button>
      </div>

      {err && (
        <div style={{ marginBottom: 12, padding: 10, border: "1px solid #ccc" }}>
          <b>Error:</b> {err}
        </div>
      )}

      {loading ? (
        <div>Loading...</div>
      ) : rows.length === 0 ? (
        <div>No PRs found.</div>
      ) : (
        <table style={{ width: "100%", borderCollapse: "collapse" }}>
          <thead>
            <tr>
              <th style={{ textAlign: "left", borderBottom: "1px solid #ddd", padding: 8 }}>
                Title
              </th>
              <th style={{ textAlign: "left", borderBottom: "1px solid #ddd", padding: 8 }}>
                Status
              </th>
              <th style={{ textAlign: "right", borderBottom: "1px solid #ddd", padding: 8 }}>
                Total
              </th>
              <th style={{ textAlign: "left", borderBottom: "1px solid #ddd", padding: 8 }}>
                Updated
              </th>
              <th style={{ textAlign: "left", borderBottom: "1px solid #ddd", padding: 8 }}>
                Actions
              </th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.pr_id}>
                <td style={{ padding: 8, borderBottom: "1px solid #eee" }}>
                  <button onClick={() => goToDetail(r.pr_id)} style={{ textDecoration: "underline" }}>
                    {r.title}
                  </button>
                </td>
                <td style={{ padding: 8, borderBottom: "1px solid #eee" }}>{r.status}</td>
                <td style={{ padding: 8, borderBottom: "1px solid #eee", textAlign: "right" }}>
                  {Number(r.subtotal ?? 0).toFixed(2)}
                </td>
                <td style={{ padding: 8, borderBottom: "1px solid #eee" }}>
                  {new Date(r.updated_at).toLocaleString()}
                </td>
                <td style={{ padding: 8, borderBottom: "1px solid #eee", display: "flex", gap: 8 }}>
                  <button onClick={() => goToDetail(r.pr_id)} disabled={!r.can_edit}>
                    Edit
                  </button>
                  <button onClick={() => submit(r.pr_id)} disabled={!r.can_submit || busyId === r.pr_id}>
                    Submit
                  </button>
                  <button onClick={() => approve(r.pr_id)} disabled={!r.can_approve || busyId === r.pr_id}>
                    Approve
                  </button>
                  <button onClick={() => reject(r.pr_id)} disabled={!r.can_reject || busyId === r.pr_id}>
                    Reject
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
