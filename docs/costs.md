# Costs — Measured Run-Rates

**Measurement basis:** a live deployment of `examples/full-stack` (demo profile: 3 AZs, multi-AZ RDS, object lock off, Insights off) in commercial us-east-1, account id scrubbed to `123456789012`. Rates were pulled from the AWS Pricing API on the deployment date (2026-07-09) for the exact resource inventory Terraform created — not from memory or marketing pages. Usage-driven lines (log ingest, Config items, LCUs) were read back from CloudWatch/billing counters for the measurement window and extrapolated to a 730-hour month. GovCloud rates differ (generally higher); re-run the same itemization there before budgeting.

> The blunt summary: **the compliance envelope, not the LLM, dominates the bill.** Interface endpoints and multi-AZ RDS are the top lines; Bedrock inference is usage-priced and starts near zero.

## Full-Stack (demo profile, 3 AZs)

| Line | Quantity deployed | Rate (us-east-1, on-demand) | Monthly (730 h) |
|---|---|---|---|
| Interface VPC endpoints | 11 endpoints × 3 AZs | $0.01/endpoint-hr/AZ | **$240.90** |
| RDS db.t4g.medium, multi-AZ, PostgreSQL 16 | 1 | $0.129/hr | **$94.17** |
| RDS gp3 storage, multi-AZ | 20 GB | $0.23/GB-mo | $4.60 |
| ECS Fargate (1 vCPU + 2 GB per task) | 2 tasks | $0.04048/vCPU-hr + $0.004445/GB-hr | **$72.08** |
| Internal ALB | 1 | $0.0225/hr + $0.008/LCU-hr | $16.43 + LCU |
| KMS CMKs | 3 | $1/key-mo | $3.00 |
| Secrets Manager | 2 secrets (master key, RDS-managed) | $0.40/secret-mo | $0.80 |
| CloudWatch alarms | ~12 standard | $0.10/alarm-mo | $1.20 |
| CloudWatch dashboard | 1 | first 3 free | $0.00 |
| CloudWatch Logs ingest + storage | usage | $0.50/GB in, $0.03/GB-mo | usage (see window) |
| AWS Config | recorder items + 10 rules | $0.003/item, $0.001/rule-eval | usage (see window) |
| CloudTrail | 1 management trail + data events (documents bucket) | trail free; data events per-event | usage (see window) |
| S3 (documents, access/ALB/audit logs) | 4 buckets | $0.022/GB-mo + requests | usage (see window) |
| Bedrock (Claude Sonnet 4.5 via us. profile) | per-token | $3/M input, $15/M output | usage |
| **Baseline total (steady-state, near-zero traffic)** | | | **≈ $435–450/mo** |

## Minimal (2 AZs, single-AZ RDS, 1 task)

| Line | Delta vs full-stack | Monthly (730 h) |
|---|---|---|
| Interface VPC endpoints | 11 × 2 AZs | **$160.60** |
| RDS db.t4g.medium single-AZ | $0.065/hr | **$47.45** |
| RDS gp3 storage single-AZ | 20 GB × $0.115/GB-mo | $2.30 |
| ECS Fargate | 1 task | $36.04 |
| Internal ALB | same | $16.43 + LCU |
| KMS / Secrets / alarms / dashboard | same shape | ~$5 |
| **Baseline total (steady-state, near-zero traffic)** | | **≈ $270–285/mo** |

## The Four Expensive Toggles

1. **Interface endpoint count × AZs** — the single biggest line. 11 endpoints × 3 AZs = $241/mo before any traffic. Cheap mode: `az_count = 2` (−$80/mo) and prune `interface_endpoints` to what your workload actually calls (each removed endpoint saves $7.30/AZ/mo). The no-egress posture is the *reason* this line exists: every AWS API your VPC can reach is a paid, auditable front door.
2. **CloudTrail data events / Insights** — management events (first trail) are free. Data events on the documents bucket are per-event; at high S3 request volume this line grows linearly. Insights (`enable_cloudtrail_insights`) adds per-100k-events-analyzed pricing. Cheap mode: keep Insights off (the default) and scope data events tightly (the audit module already scopes them to the documents bucket ARN only).
3. **Multi-AZ RDS** — ~2× single-AZ ($94.17 vs $47.45/mo at db.t4g.medium, and $0.23 vs $0.115/GB-mo storage). Cheap mode: single-AZ in sandboxes (`examples/minimal` does this, with the checkov skip documented); production keeps multi-AZ.
4. **ACM Private CA** — not deployed by either example (the demo uses a self-signed cert). Production TLS on the internal ALB wants a private CA: **$400/mo per CA** plus per-certificate fees, ~doubling the demo baseline. Cheap modes: an existing organizational PCA (share via RAM), or short-lived-CA issuance patterns; the modules accept any `certificate_arn`, so the CA strategy stays a deployment decision.

## Measurement Window

The full-stack demo profile ran live on 2026-07-09, 20:08–22:30 UTC (apply → six-finding fix cycle → proofs → destroy). What the window itself measured:

| Counter | Observed (first 2 h) | Monthly extrapolation | Note |
|---|---|---|---|
| CloudTrail → CW Logs ingest | 10.0 MB | ~3.6 GB ≈ $1.80 ingest | Deploy-heavy: the apply itself generates most management events; steady state is lower |
| VPC flow logs ingest | 2.2 MB | ~0.8 GB ≈ $0.40 | Proof traffic only |
| Gateway container logs | 21 KB | negligible | |
| ALB ConsumedLCUs | ~0 | base $16.43/mo dominates | LCUs are invisible at proof-level traffic |
| Bedrock | 115 tokens (15 in / 100 out) | usage-priced | $0.0016 for the proof completion |

Two honest caveats. First, Cost Explorer publishes usage with up to a 24-hour lag, so the window's billed line items could not be read back before the stack was destroyed the same day — the hourly-rate lines in the tables above are exact (fixed inventory × published rate), and the usage lines carry the counters measured above. Second, the deploy/destroy cycle itself has a small one-time cost (Config configuration items for 147 resources ≈ $0.44 at $0.003/item, CloudTrail ingest above) that a steady-state month does not repeat.

## Teardown

`terraform destroy` (deletion protections off — see the example README) followed by `scripts/verify-teardown.sh -p <project> -e <env> -r <region>` confirms nothing billable remains. Expected INFO-level residue: KMS keys in their 30-day pending-deletion window (free), the RDS final snapshot if `skip_final_snapshot` stayed false (billable at snapshot-GB-month — delete it once you've verified you don't need it).
