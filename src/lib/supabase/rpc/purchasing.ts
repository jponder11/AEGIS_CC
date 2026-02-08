export type PurchasingRpcResult<T> = {
  data: T | null;
  error: Error | null;
};

export const purchasingRpcNote =
  "Phase 8 scaffold: wire these to Supabase RPCs in Phase 9.";
