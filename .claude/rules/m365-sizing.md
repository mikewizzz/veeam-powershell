# M365 Sizing Project Rules

## Graph API

- **v1.0 endpoints only** — All Microsoft Graph API calls must use the `v1.0` endpoint, never `beta`. Beta endpoints can change without notice and break production scripts.
- **Graceful permission failures** — When a Graph API call fails due to insufficient permissions, return structured fallback values (`"access_denied"`, `"not_available"`, `"unknown"`) instead of throwing. The script must complete even with partial permissions.
- **Retry with backoff** — All Graph API calls must use exponential backoff retry logic (max 30s between retries, configurable max attempts).

## Data Collection

- **$Full switch gates new collection** — Any new data collection endpoint (mailbox statistics, archive details, etc.) must be gated behind the `-Full` parameter. Quick mode should only use lightweight, fast endpoints.
- **SharePoint is always tenant-wide** — The Graph API does not support group-filtering for SharePoint site enumeration. Document this limitation clearly; never imply group filtering works for SharePoint.

## Sizing Estimates

- **MBS estimates are models** — Microsoft Backup Storage sizing estimates are mathematical models based on observed data patterns. Always label them as "estimated" and never present them as measured or guaranteed values.
- **Show methodology** — Include a methodology note explaining how estimates are derived (growth rates, compression ratios, retention calculations).
- **Conservative defaults** — Use conservative assumptions for growth rates and compression unless the user overrides with parameters.

## Findings Engine

- **Algorithmically derived** — All findings (risks, recommendations, observations) must be generated from actual tenant data through deterministic logic. No hardcoded findings that appear regardless of data.
- **Severity levels** — Use consistent severity levels: Critical, Warning, Info, Positive.
- **Actionable recommendations** — Every finding must include a specific, actionable recommendation.
