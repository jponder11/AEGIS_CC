import Link from "next/link";
import { supabaseServer } from "@/lib/supabase/server";

type PRStatus =
  | "draft"
  | "submitted"
  | "approved"
  | "rejected"
  | "cancelled"
  | "fulfilled";

type PRRow = {
  id: string;
  project_id: string;
  pr_number: string;
  status: PRStatus;
  needed_by_date: string | null;
  priority: string | null;
  notes: string | null;
  created_at: string;
};

const COLUMNS: { status: PRStatus; title: string }[] = [
  { status: "draft", title: "Draft" },
  { status: "submitted", title: "Submitted" },
  { status: "approved", title: "Approved" },
  { status: "rejected", title: "Rejected" },
  { status: "fulfilled", title: "Fulfilled" },
];

function fmtDate(d: string | null) {
  if (!d) return "–";
  const dt = new Date(d);
  return dt.toLocaleDateString();
}

export default async function PurchasingPRBoardPage() {
  const supabase = supabaseServer();

  const { data: prs, error } = await supabase
    .from("purchase_requests")
    .select(
      "id, project_id, pr_number, status, needed_by_date, priority, notes, created_at",
    )
    .order("created_at", { ascending: false });

  if (error) {
    return (
      <main style={{ padding: 24 }}>
        <h1>Purchasing • PR Board</h1>
        <p style={{ color: "crimson" }}>
          Failed to load PRs: {error.message}
        </p>
        <p>
          If this is an RLS issue, confirm Phase 7 policies allow SELECT on
          purchase_requests for authenticated users.
        </p>
      </main>
    );
  }

  const grouped = new Map<PRStatus, PRRow[]>();
  for (const c of COLUMNS) grouped.set(c.status, []);
  for (const pr of (prs ?? []) as PRRow[]) {
    if (!grouped.has(pr.status)) grouped.set(pr.status, []);
    grouped.get(pr.status)!.push(pr);
  }

  return (
    <main style={{ padding: 24 }}>
      <div
        style={{
          display: "flex",
          alignItems: "baseline",
          justifyContent: "space-between",
          gap: 12,
        }}
      >
        <div>
          <h1 style={{ margin: 0 }}>Purchasing • PR Board</h1>
          <p style={{ marginTop: 8, color: "#666" }}>
            Read-only board. Next we add “New PR” and status actions via RPCs.
          </p>
        </div>

        <div style={{ display: "flex", gap: 10 }}>
          <Link
            href="/purchasing"
            style={{
              padding: "8px 12px",
              border: "1px solid #ddd",
              borderRadius: 10,
              textDecoration: "none",
              color: "inherit",
            }}
          >
            Purchasing Home
          </Link>

          <button
            disabled
            title="Next step: wire create PR RPC"
            style={{
              padding: "8px 12px",
              border: "1px solid #ddd",
              borderRadius: 10,
              background: "#f7f7f7",
              cursor: "not-allowed",
            }}
          >
            New PR
          </button>
        </div>
      </div>

      <div
        style={{
          display: "grid",
          gridTemplateColumns: `repeat(${COLUMNS.length}, minmax(240px, 1fr))`,
          gap: 14,
          marginTop: 18,
        }}
      >
        {COLUMNS.map((col) => {
          const items = grouped.get(col.status) ?? [];
          return (
            <section
              key={col.status}
              style={{
                border: "1px solid #e6e6e6",
                borderRadius: 14,
                padding: 12,
                background: "white",
              }}
            >
              <div
                style={{
                  display: "flex",
                  alignItems: "baseline",
                  justifyContent: "space-between",
                }}
              >
                <h2 style={{ margin: 0, fontSize: 16 }}>{col.title}</h2>
                <span style={{ color: "#666", fontSize: 12 }}>
                  {items.length}
                </span>
              </div>

              <div style={{ display: "grid", gap: 10, marginTop: 10 }}>
                {items.length === 0 ? (
                  <div
                    style={{ color: "#888", fontSize: 13, padding: "8px 6px" }}
                  >
                    No items
                  </div>
                ) : (
                  items.map((pr) => (
                    <Link
                      key={pr.id}
                      href={`/purchasing/pr/${pr.id}`}
                      style={{
                        display: "block",
                        padding: 10,
                        border: "1px solid #eee",
                        borderRadius: 12,
                        textDecoration: "none",
                        color: "inherit",
                        background: "#fcfcfc",
                      }}
                    >
                      <div
                        style={{
                          display: "flex",
                          justifyContent: "space-between",
                          gap: 10,
                        }}
                      >
                        <strong>{pr.pr_number}</strong>
                        <span style={{ fontSize: 12, color: "#666" }}>
                          {fmtDate(pr.needed_by_date)}
                        </span>
                      </div>

                      <div style={{ marginTop: 6, fontSize: 12, color: "#666" }}>
                        Priority: {pr.priority ?? "normal"}
                      </div>

                      {pr.notes ? (
                        <div
                          style={{ marginTop: 6, fontSize: 12, color: "#444" }}
                        >
                          {pr.notes.length > 110
                            ? pr.notes.slice(0, 110) + "…"
                            : pr.notes}
                        </div>
                      ) : null}
                    </Link>
                  ))
                )}
              </div>
            </section>
          );
        })}
      </div>
    </main>
  );
}
