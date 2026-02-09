"use client";

import { useEffect, useMemo, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

type PrStatus =
  | "draft"
  | "submitted"
  | "approved"
  | "rejected"
  | "cancelled"
  | "fulfilled";

type PrHeader = {
  id: string;
  project_id: string;
  title: string;
  need_by: string | null;
  notes: string | null;
  status: PrStatus;
  created_at: string;
  updated_at: string;
  created_by: string;
  submitted_at: string | null;
  approved_at?: string | null;
  rejected_at?: string | null;
  reject_reason?: string | null;
};

type PrLine = {
  id: string;
  pr_id: string;
  item_name: string;
  qty: number;
  unit: string | null;
  unit_cost: number;
  vendor_id: string | null;
  notes: string | null;
  created_at?: string;
  updated_at?: string;
};

type Totals = {
  subtotal: number;
};

function money(n: number) {
  const v = Number(n ?? 0);
  return v.toFixed(2);
}

export default function PrDetailPage() {
  const supabase = useMemo(() => createClient(), []);
  const router = useRouter();
  const params = useParams<{ projectId: string; prId: string }>();

  const projectId = params?.projectId ?? "";
  const prId = params?.prId ?? "";

  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  const [header, setHeader] = useState<PrHeader | null>(null);
  const [lines, setLines] = useState<PrLine[]>([]);
  const [totals, setTotals] = useState<Totals>({ subtotal: 0 });

  const [title, setTitle] = useState("");
  const [needBy, setNeedBy] = useState<string>("");
  const [notes, setNotes] = useState("");

  const [lineModalOpen, setLineModalOpen] = useState(false);
  const [editingLineId, setEditingLineId] = useState<string | null>(null);

  const [lineItemName, setLineItemName] = useState("");
  const [lineQty, setLineQty] = useState<number>(1);
  const [lineUnit, setLineUnit] = useState<string>("");
  const [lineUnitCost, setLineUnitCost] = useState<number>(0);
  const [lineVendorId, setLineVendorId] = useState<string>("");
  const [lineNotes, setLineNotes] = useState<string>("");

  const isDraft = header?.status === "draft";

  function resetLineForm() {
    setEditingLineId(null);
    setLineItemName("");
    setLineQty(1);
    setLineUnit("");
    setLineUnitCost(0);
    setLineVendorId("");
    setLineNotes("");
  }

  function openAddLine() {
    resetLineForm();
    setLineModalOpen(true);
  }

  function openEditLine(l: PrLine) {
    setEditingLineId(l.id);
    setLineItemName(l.item_name ?? "");
    setLineQty(Number(l.qty ?? 1));
    setLineUnit(l.unit ?? "");
    setLineUnitCost(Number(l.unit_cost ?? 0));
    setLineVendorId(l.vendor_id ?? "");
    setLineNotes(l.notes ?? "");
    setLineModalOpen(true);
  }

  async function load() {
    if (!prId) return;
    setLoading(true);
    setErr(null);

    const headerRes = await supabase
      .from("purchase_requests")
      .select(
        "id, project_id, title, need_by, notes, status, created_at, updated_at, created_by, submitted_at, approved_at, rejected_at, reject_reason",
      )
      .eq("id", prId)
      .single();

    if (headerRes.error) {
      setErr(headerRes.error.message);
      setHeader(null);
      setLines([]);
      setTotals({ subtotal: 0 });
      setLoading(false);
      return;
    }

    const h = headerRes.data as PrHeader;

    if (projectId && h.project_id !== projectId) {
      setErr("PR does not belong to this project route.");
      setHeader(null);
      setLines([]);
      setTotals({ subtotal: 0 });
      setLoading(false);
      return;
    }

    setHeader(h);
    setTitle(h.title ?? "");
    setNeedBy(h.need_by ?? "");
    setNotes(h.notes ?? "");

    const linesRes = await supabase
      .from("purchase_request_lines")
      .select(
        "id, pr_id, item_name, qty, unit, unit_cost, vendor_id, notes, created_at, updated_at",
      )
      .eq("pr_id", prId)
      .order("created_at", { ascending: true });

    if (linesRes.error) {
      setErr(linesRes.error.message);
      setLines([]);
      setTotals({ subtotal: 0 });
      setLoading(false);
      return;
    }

    const ls = (linesRes.data ?? []) as PrLine[];
    setLines(ls);

    const subtotal = ls.reduce(
      (acc, l) => acc + Number(l.qty ?? 0) * Number(l.unit_cost ?? 0),
      0,
    );
    setTotals({ subtotal });

    setLoading(false);
  }

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [prId]);

  async function saveHeader() {
    if (!header) return;
    setErr(null);
    setBusy("saveHeader");

    const { error } = await supabase.rpc("rpc_pr_update_header", {
      p_pr_id: header.id,
      p_title: title,
      p_need_by: needBy ? needBy : null,
      p_notes: notes ? notes : null,
    });

    setBusy(null);

    if (error) return setErr(error.message);

    await load();
  }

  async function saveLine() {
    if (!header) return;

    const qty = Number(lineQty);
    const unitCost = Number(lineUnitCost);

    if (!lineItemName.trim()) return setErr("Item name is required.");
    if (!Number.isFinite(qty) || qty <= 0) return setErr("Qty must be > 0.");
    if (!Number.isFinite(unitCost) || unitCost < 0) {
      return setErr("Unit cost must be >= 0.");
    }

    setErr(null);
    setBusy("saveLine");

    const { error } = await supabase.rpc("rpc_pr_upsert_line", {
      p_pr_id: header.id,
      p_line_id: editingLineId ? editingLineId : null,
      p_item_name: lineItemName,
      p_qty: qty,
      p_unit: lineUnit ? lineUnit : null,
      p_unit_cost: unitCost,
      p_vendor_id: lineVendorId ? lineVendorId : null,
      p_notes: lineNotes ? lineNotes : null,
    });

    setBusy(null);

    if (error) return setErr(error.message);

    setLineModalOpen(false);
    resetLineForm();
    await load();
  }

  async function submit() {
    if (!header) return;
    setErr(null);
    setBusy("submit");

    const { error } = await supabase.rpc("rpc_pr_submit", { p_pr_id: header.id });

    setBusy(null);

    if (error) return setErr(error.message);

    await load();
  }

  async function approve() {
    if (!header) return;
    setErr(null);
    setBusy("approve");

    const { error } = await supabase.rpc("rpc_pr_approve", { p_pr_id: header.id });

    setBusy(null);

    if (error) return setErr(error.message);

    await load();
  }

  async function reject() {
    if (!header) return;
    const reason = window.prompt("Reject reason (optional):") ?? "";

    setErr(null);
    setBusy("reject");

    const { error } = await supabase.rpc("rpc_pr_reject", {
      p_pr_id: header.id,
      p_reason: reason,
    });

    setBusy(null);

    if (error) return setErr(error.message);

    await load();
  }

  return (
    <div style={{ padding: 16, display: "grid", gap: 12 }}>
      <div style={{ display: "flex", gap: 12, alignItems: "center" }}>
        <button onClick={() => router.back()}>Back</button>
        <h2 style={{ margin: 0 }}>PR Detail</h2>
        {header && (
          <span style={{ padding: "2px 8px", border: "1px solid #ddd", borderRadius: 6 }}>
            {header.status}
          </span>
        )}
      </div>

      {err && (
        <div style={{ padding: 10, border: "1px solid #ccc" }}>
          <b>Error:</b> {err}
        </div>
      )}

      {loading ? (
        <div>Loading...</div>
      ) : !header ? (
        <div>PR not found.</div>
      ) : (
        <>
          <div style={{ border: "1px solid #eee", borderRadius: 8, padding: 12 }}>
            <div style={{ display: "grid", gridTemplateColumns: "1fr 220px", gap: 12 }}>
              <div style={{ display: "grid", gap: 8 }}>
                <label style={{ display: "grid", gap: 4 }}>
                  <span>Title</span>
                  <input
                    value={title}
                    onChange={(e) => setTitle(e.target.value)}
                    disabled={!isDraft}
                    placeholder="PR title"
                  />
                </label>

                <label style={{ display: "grid", gap: 4 }}>
                  <span>Notes</span>
                  <textarea
                    value={notes}
                    onChange={(e) => setNotes(e.target.value)}
                    disabled={!isDraft}
                    placeholder="Optional notes"
                    rows={3}
                  />
                </label>
              </div>

              <div style={{ display: "grid", gap: 8 }}>
                <label style={{ display: "grid", gap: 4 }}>
                  <span>Need by</span>
                  <input
                    type="date"
                    value={needBy ?? ""}
                    onChange={(e) => setNeedBy(e.target.value)}
                    disabled={!isDraft}
                  />
                </label>

                <div style={{ display: "grid", gap: 6 }}>
                  <div>
                    <b>Total:</b> {money(totals.subtotal)}
                  </div>
                  {header.submitted_at && (
                    <div>
                      <b>Submitted:</b> {new Date(header.submitted_at).toLocaleString()}
                    </div>
                  )}
                  {header.reject_reason && (
                    <div>
                      <b>Reject reason:</b> {header.reject_reason}
                    </div>
                  )}
                </div>
              </div>
            </div>

            <div style={{ display: "flex", gap: 8, marginTop: 12 }}>
              <button onClick={saveHeader} disabled={!isDraft || busy === "saveHeader"}>
                {busy === "saveHeader" ? "Saving..." : "Save Header"}
              </button>

              <button onClick={submit} disabled={!isDraft || busy === "submit"}>
                {busy === "submit" ? "Submitting..." : "Submit"}
              </button>

              <button
                onClick={approve}
                disabled={header.status !== "submitted" || busy === "approve"}
              >
                {busy === "approve" ? "Approving..." : "Approve"}
              </button>

              <button
                onClick={reject}
                disabled={header.status !== "submitted" || busy === "reject"}
              >
                {busy === "reject" ? "Rejecting..." : "Reject"}
              </button>
            </div>
          </div>

          <div style={{ border: "1px solid #eee", borderRadius: 8, padding: 12 }}>
            <div style={{ display: "flex", gap: 12, alignItems: "center", marginBottom: 8 }}>
              <h3 style={{ margin: 0 }}>Lines</h3>
              <button onClick={openAddLine} disabled={!isDraft}>
                Add Line
              </button>
              <button onClick={load} disabled={loading}>
                Refresh
              </button>
            </div>

            {lines.length === 0 ? (
              <div>No lines yet.</div>
            ) : (
              <table style={{ width: "100%", borderCollapse: "collapse" }}>
                <thead>
                  <tr>
                    <th style={{ textAlign: "left", borderBottom: "1px solid #ddd", padding: 8 }}>
                      Item
                    </th>
                    <th style={{ textAlign: "right", borderBottom: "1px solid #ddd", padding: 8 }}>
                      Qty
                    </th>
                    <th style={{ textAlign: "left", borderBottom: "1px solid #ddd", padding: 8 }}>
                      Unit
                    </th>
                    <th style={{ textAlign: "right", borderBottom: "1px solid #ddd", padding: 8 }}>
                      Unit Cost
                    </th>
                    <th style={{ textAlign: "right", borderBottom: "1px solid #ddd", padding: 8 }}>
                      Line Total
                    </th>
                    <th style={{ textAlign: "left", borderBottom: "1px solid #ddd", padding: 8 }}>
                      Actions
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {lines.map((l) => {
                    const lineTotal = Number(l.qty ?? 0) * Number(l.unit_cost ?? 0);
                    return (
                      <tr key={l.id}>
                        <td style={{ padding: 8, borderBottom: "1px solid #eee" }}>
                          {l.item_name}
                        </td>
                        <td style={{ padding: 8, borderBottom: "1px solid #eee", textAlign: "right" }}>
                          {Number(l.qty ?? 0)}
                        </td>
                        <td style={{ padding: 8, borderBottom: "1px solid #eee" }}>
                          {l.unit ?? ""}
                        </td>
                        <td style={{ padding: 8, borderBottom: "1px solid #eee", textAlign: "right" }}>
                          {money(Number(l.unit_cost ?? 0))}
                        </td>
                        <td style={{ padding: 8, borderBottom: "1px solid #eee", textAlign: "right" }}>
                          {money(lineTotal)}
                        </td>
                        <td style={{ padding: 8, borderBottom: "1px solid #eee" }}>
                          <button onClick={() => openEditLine(l)} disabled={!isDraft}>
                            Edit
                          </button>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            )}
          </div>

          {lineModalOpen && (
            <div
              style={{
                position: "fixed",
                inset: 0,
                background: "rgba(0,0,0,0.3)",
                display: "grid",
                placeItems: "center",
                padding: 16,
              }}
              onClick={() => {
                if (busy) return;
                setLineModalOpen(false);
                resetLineForm();
              }}
            >
              <div
                style={{ background: "#fff", borderRadius: 10, padding: 14, width: "min(720px, 100%)" }}
                onClick={(e) => e.stopPropagation()}
              >
                <h3 style={{ marginTop: 0 }}>{editingLineId ? "Edit Line" : "Add Line"}</h3>

                <div style={{ display: "grid", gridTemplateColumns: "2fr 1fr 1fr 1fr", gap: 10 }}>
                  <label style={{ display: "grid", gap: 4, gridColumn: "1 / span 4" }}>
                    <span>Item name</span>
                    <input value={lineItemName} onChange={(e) => setLineItemName(e.target.value)} />
                  </label>

                  <label style={{ display: "grid", gap: 4 }}>
                    <span>Qty</span>
                    <input
                      type="number"
                      value={lineQty}
                      min={0}
                      step={0.01}
                      onChange={(e) => setLineQty(Number(e.target.value))}
                    />
                  </label>

                  <label style={{ display: "grid", gap: 4 }}>
                    <span>Unit</span>
                    <input
                      value={lineUnit}
                      onChange={(e) => setLineUnit(e.target.value)}
                      placeholder="ea, ft, box"
                    />
                  </label>

                  <label style={{ display: "grid", gap: 4 }}>
                    <span>Unit cost</span>
                    <input
                      type="number"
                      value={lineUnitCost}
                      min={0}
                      step={0.01}
                      onChange={(e) => setLineUnitCost(Number(e.target.value))}
                    />
                  </label>

                  <label style={{ display: "grid", gap: 4 }}>
                    <span>Vendor ID (optional)</span>
                    <input value={lineVendorId} onChange={(e) => setLineVendorId(e.target.value)} />
                  </label>

                  <label style={{ display: "grid", gap: 4, gridColumn: "1 / span 4" }}>
                    <span>Notes (optional)</span>
                    <textarea
                      value={lineNotes}
                      onChange={(e) => setLineNotes(e.target.value)}
                      rows={3}
                    />
                  </label>
                </div>

                <div style={{ display: "flex", gap: 8, marginTop: 12, justifyContent: "flex-end" }}>
                  <button
                    onClick={() => {
                      if (busy) return;
                      setLineModalOpen(false);
                      resetLineForm();
                    }}
                    disabled={!!busy}
                  >
                    Cancel
                  </button>
                  <button onClick={saveLine} disabled={busy === "saveLine"}>
                    {busy === "saveLine" ? "Saving..." : "Save Line"}
                  </button>
                </div>
              </div>
            </div>
          )}
        </>
      )}
    </div>
  );
}
