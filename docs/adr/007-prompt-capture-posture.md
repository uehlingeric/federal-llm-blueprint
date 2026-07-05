# ADR-007: Metadata-Only Prompt Capture by Default

**Status:** Accepted  
**Date:** 2026-07-04

## Context

Bedrock model-invocation logging can capture prompt and response bodies in full, or limit output to invocation metadata. Storing prompts is a **policy decision**, not a technical one: in this architecture, prompts routinely contain Controlled Unclassified Information (CUI) because they include context from CUI-classified documents retrieved via the vector store. Full capture moves CUI from the document plane into the audit logging plane, expanding the CUI boundary to the audit bucket, CloudWatch Logs, and S3 large-data delivery, and changes the access control boundary: readers of logs become readers of CUI.

The default posture must be explicit and defensible. Federal deployments — especially those pursuing ATO assessment — require clear reasoning about what data leaves the application layer and who can see it.

## Decision

**Default `enable_full_content_logging = false` in modules/audit. Metadata-only logging by default; full prompt/response capture is an opt-in flag with documented access-control consequences.**

### Rationale

**Default Metadata-Only Capture:**

When `enable_full_content_logging = false`, the Bedrock invocation logger writes only:
- `schemaType` and `schemaVersion` (log format identifiers)
- `timestamp` (invocation time)
- `accountId` (AWS account)
- `region` (deployment region)
- `requestId` (Bedrock-generated unique invocation ID)
- `operation` (e.g., "InvokeModel", "Converse", "ConverseStream")
- `modelId` (which model was called, e.g., `anthropic.claude-sonnet-4-5-20250929-v1:0`)
- `identity.arn` (the IAM principal calling Bedrock — e.g., the ECS task role ARN)
- `inputTokenCount` and `outputTokenCount` (token usage, not content)

This metadata answers the operational and audit questions: "Who invoked which model, when, and how much compute was consumed?" without storing the text, images, embeddings, or video that passed through the call. Compliance auditors can correlate model invocations to principal identity and time without exposing document contents.

**Full Capture as Opt-In:**

When `enable_full_content_logging = true`, four delivery flags toggle on:
- `text_data_delivery_enabled` (prompt/response text)
- `image_data_delivery_enabled` (image payloads)
- `embedding_data_delivery_enabled` (embedding vectors)
- `video_data_delivery_enabled` (video payloads)

All enabled simultaneously via the single `enable_full_content_logging` flag. Prompts and responses larger than 100 KB overflow automatically to S3 via the `large_data_delivery_s3_config` block, writing under the `bedrock/` prefix of the audit bucket (already wired in the module policy). Enabling full capture does not silently truncate; large payloads are preserved.

**Access Control Consequence:**

With full capture enabled, the audit bucket and the Bedrock CloudWatch Logs group become CUI stores. Readers of these logs become readers of CUI. In minimal deployments, this may be the same audit/observability team; in larger federal agencies, it may require additional control justification:

- Document readers: limited to the application's Bedrock invocation identity and S3 read-only on document prefixes.
- Log readers: broadly the audit/observability team, possibly spanning audit, security, and compliance functions.

These are *different* access boundaries. Full capture blurs them.

**Cost Implication:**

Full content logging multiplies CloudWatch Logs ingestion and storage volume (request/response bodies instead of a small metadata record) and adds S3 request and storage costs for large-payload overflow. Those costs are real but secondary; the primary trade-off is access-control complexity and CUI-boundary expansion.

## Consequences

**Auditors Get Accountability by Default:** With metadata-only logging, every Bedrock call is correlated to a principal, timestamp, and resource usage. Operational incident response ("Which role called the model at 14:35 UTC and how many tokens did it use?") is always possible without access to sensitive content.

**Content Forensics Requires Opt-In and Its Costs:** If insider-threat forensics, DLP review, or other content examination is required, enable full capture explicitly in the composition (e.g., in `examples/minimal/main.tf` or a prod overlay). Document the decision in your runbook and ensure log readers are vetted accordingly.

**Both Postures Use the Same Infrastructure:** The audit bucket, Bedrock log group, and large-data delivery path are always present. Toggling `enable_full_content_logging` does not require infrastructure refactor; it is a per-deployment variable choice.

**Default Aligns with Principle of Least Privilege:** CUI is not logged until there is a specific, documented reason to log it. This posture is defensible in federal assessment and lowers the baseline access-control surface for most deployments.

## Alternatives Considered

### Full Capture Always
- **Strength:** Complete forensic trail for any investigation.
- **Why rejected:** Expands CUI boundary unnecessarily; every log reader becomes a document reader; harder to defend in federal assessment.

### No Logging
- **Strength:** Eliminates CUI boundary expansion entirely.
- **Why rejected:** Loses all invocation audit trail (token use, timing, principal identity). Federal deployments require some level of audit logging; metadata-only is a middle ground.

## Revisit Triggers

1. **Insider-threat investigation requires prompt text:** Enable full capture going forward (logging is not retroactive — content from before the flag flip does not exist). Document the decision and its duration in your incident-response runbook.

2. **Federal assessment requires full content capture:** Discuss with assessors whether metadata-only satisfies the control intent (audit logging) before defaulting to full capture. Many compliance frameworks allow metadata-only logging for operational accountability.

3. **Data-loss-prevention (DLP) review mandated:** Full capture is required. Re-evaluate the log-reader access boundary first: treat the Bedrock log group and the audit bucket's `bedrock/` prefix as CUI stores and scope reader access accordingly.
