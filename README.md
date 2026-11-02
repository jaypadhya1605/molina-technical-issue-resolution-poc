# Molina KMS architecture proof

**Internal Microsoft/Molina PoC. Keep this repository private.** The articles are synthetic; the meeting notes and environment identifiers are internal.

## Run one script

From this repository root, after signing in to the configured PoC tenant/subscription:

```powershell
az login --tenant 16b3c013-d300-468d-ac64-7eda0820b6d3
az account set --subscription 2852c4f9-8fcc-47c1-8e96-c4142a9ae463
.\final-demo.ps1
```

Use `.\final-demo.ps1 -Pause` for a presentation. Allow approximately 20-30 minutes: Azure VM Run Command, indexer runs, private-link propagation and audit ingestion are asynchronous. Prerequisites: Windows PowerShell 5.1 or PowerShell 7, Azure CLI, the existing running PoC VM, ARM/Graph read access, VM Run Command permission, Log Analytics query access and the presenter's `KMS.Ingest` / `KMS.Search` gateway roles. The current CLI subscription must match [the configuration](kms-oauth-poc/scripts/kms-poc.config.json).

The script is the **single entry point**, not a standalone copy: keep the complete repository together. It reuses the existing demo scripts, publisher, policies and synthetic corpus.

### Proof presented to Security and Applications

| Scene | Evidence / ask covered |
|---|---|
| Preflight and 01 | Correct tenant/subscription; Search public access disabled; live keyless posture, managed identities, app roles, RBAC, approved private links, VM without a public IP |
| 02-03 | Automatic corpus baseline; OAuth positive/negative matrix: missing, wrong-audience and tampered tokens; direct-backend denial |
| 04-05 | Private DNS from the KMS VM; OAuth ADLS access; publisher cannot search; only Search identity can use the embedding API |
| 06 | Measured vector-payload versus pointer size; HTTP 413, invalid-pointer 400 and accepted-pointer 202 |
| 07 | Hybrid + BM25 + semantic search; LOB, State and Effective Date filters; hidden draft/future/expired articles demonstrably present in the index |
| 08-09 | v3/four chunks becomes v4/two chunks without stale chunks; unpublish removes chunks; agent sees v4 and cannot ingest |
| 10 | SDK-shaped search/count/indexer-status calls; default-deny for disallowed operations |
| 11 | Valid public OAuth caller rejected with private-only enabled; private agent retrieval still works |
| Audit | **Current-run**, resource-scoped accepted/rejected gateway records; Search identity/private embedding calls; publisher OAuth storage access; APIM identity calling OpenAI |
| Cleanup | Synthetic lifecycle baseline restored; original gateway private-link setting restored and re-read |

Timestamped scene logs and machine-readable `summary.json` are written under `demo-evidence`, excluded from Git. Missing evidence, assertion failures, terminated scenes and failed cleanup produce **FAIL**, not a reassuring success message. Audit polling defaults to up to 180 seconds; use `-AuditWaitSeconds 600` for a slower workspace. Empty audit tables are not proof.

The consolidated runner has passed PowerShell 5.1 syntax and offline failure-handling/argument-forwarding checks. A fresh live end-to-end acceptance run still requires working Azure connectivity and permission to execute workspace scripts; no successful consolidated live-run result is included in this repository.

### Changes made during a run

- Republishes the **15 synthetic PoC articles**, then exercises republish/unpublish on KA-1003 and KA-1012. Finally restores their fixture baseline.
- Temporarily permits **OAuth-authenticated public APIM traffic** so the laptop demos run, then enables private-link-only for its proof. Restores the original switch even after a failure. Do not run if this temporary PoC-only change is not permitted.
- Never enables Search public access, deploys resources, changes keys/RBAC, or creates certificate/private-key files. Tokens are obtained just-in-time and never intentionally persisted.
- The SDK default-deny scene uses a nonexistent target for its delete-denial probe; it does not try to delete the actual KMS index.

### Honest boundaries / production decisions

The ingest API carries pointers, not article/vector batches. **Embedding responses still carry vectors through the AI gateway.** This avoids the large ingestion-push request; it does not eliminate model throttling or indexer limits. The 8 KB pointer cap is a PoC policy, not a reproduction of Molina's gateway limit.

This verifies the deployed architecture, **not Molina production approval**. The original SDK demo tests URL protocol, not the SDK binary. The small synthetic chunks preserve KMS boundaries but do not validate the actual 700-token algorithm or 12,000-chunk capacity. Pinning the new deployment does not establish which model built a legacy index; production must re-embed consistently.

Storage `allowSharedKeyAccess=false` blocks Shared Key and account/service SAS; it does **not** disable user-delegation SAS. The demonstrated application path uses OAuth.

Production gates remain: Molina gateway tier/private-endpoint compatibility; dedicated production Search service and sizing (do not disable keys on the shared dev service); network/DNS and tenant role assignments; actual KMS/on-prem identity integration; SDK-binary integration; load/retry testing; portal TLS; and Security sign-off. VM-first is retained. AKS, OCR/PDFs and SQL/PostgreSQL evaluation remain separate phase-two work. RBAC-only without a gateway is an approval decision, not a bypass this script enables.

## Supporting material

- [Full architecture, all 26 asks, production plan and Microsoft documentation](kms-oauth-poc/demo.md)
- [Presentation](demo-slides.pptx)
- [Meeting notes](Meeting-notes)
- [Diagrams and animations](visuals)
- [Infrastructure](kms-oauth-poc/infra), [gateway policies](kms-oauth-poc/apim/policies), [Search definitions](kms-oauth-poc/search)

The original individual scripts remain available for focused troubleshooting.
