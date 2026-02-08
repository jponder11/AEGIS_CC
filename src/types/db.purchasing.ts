export type UUID = string;

export type PrStatus =
  | "draft"
  | "submitted"
  | "approved"
  | "rejected"
  | "cancelled"
  | "fulfilled";

export type PoStatus =
  | "draft"
  | "issued"
  | "acknowledged"
  | "partially_received"
  | "received"
  | "closed"
  | "cancelled";

export type ReceiptStatus = "pending" | "received" | "reconciled" | "cancelled";
