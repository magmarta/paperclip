import { gzipSync } from "node:zlib";
import type { FeedbackTraceBundle } from "@paperclipai/shared";
import type { Config } from "../config.js";

const DEFAULT_FEEDBACK_EXPORT_BACKEND_URL = "https://telemetry.paperclip.ing";

function buildFeedbackShareObjectKey(bundle: FeedbackTraceBundle, exportedAt: Date) {
  const year = String(exportedAt.getUTCFullYear());
  const month = String(exportedAt.getUTCMonth() + 1).padStart(2, "0");
  const day = String(exportedAt.getUTCDate()).padStart(2, "0");
  return `feedback-traces/${bundle.companyId}/${year}/${month}/${day}/${bundle.exportId ?? bundle.traceId}.json`;
}

export interface FeedbackTraceShareClient {
  uploadTraceBundle(bundle: FeedbackTraceBundle): Promise<{ objectKey: string }>;
}

export function createFeedbackTraceShareClientFromConfig(
  config: Pick<Config, "feedbackExportBackendUrl" | "feedbackExportBackendToken">,
): FeedbackTraceShareClient {
  // magmarta fork policy (b): feedback trace bundles carry real work content,
  // so the upload implementation is removed outright rather than gated behind a
  // flag. `server/src/index.ts` also wires no share client at all, which keeps
  // pending traces local instead of queueing them. See .github/FORK-POLICY.md.
  void config;
  return {
    async uploadTraceBundle(): Promise<{ objectKey: string }> {
      throw new Error(
        "Feedback trace sharing is disabled by fork policy (.github/FORK-POLICY.md)",
      );
    },
  };
}
