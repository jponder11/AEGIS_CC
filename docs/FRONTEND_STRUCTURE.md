# Aegis Frontend Structure (Pinned)

This folder structure is pinned. Do not freestyle new top-level folders.
New UI work must fit into the buckets below.

## Root
AEGIS_CC/
  src/
    app/
      (auth)/
        login/page.tsx
      (app)/
        layout.tsx
        page.tsx
        projects/
          page.tsx
          [projectId]/
            page.tsx
            timeline/page.tsx
            sov/page.tsx
      api/
        health/route.ts
    components/
      layout/
        AppShell.tsx
        TopNav.tsx
        SideNav.tsx
      projects/
        ProjectStatusPill.tsx
        ProjectSummaryCards.tsx
        ActivityFeed.tsx
        ProjectsTable.tsx
      ui/
    lib/
      supabase/
        server.ts
        client.ts
      format/
        money.ts
        dates.ts
      guards/
        rlsNotes.ts
    types/
      db.views.ts
      rpc.ts
  db/
    migrations/
  docs/

## Rules
- Views are read-only. Do not add direct table writes.
- All mutations must call existing Supabase RPCs.
- If a feature needs a new view or RPC, it is a new migration, not a frontend workaround.
