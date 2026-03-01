# Security Standards

## HTML Report Safety

- **HTML-encode all user-controlled values** — Use the `Escape-Html` helper function for any value that originated from Graph API, user input, or external data before embedding in HTML reports.
- **No inline script injection** — Never use string interpolation to embed user data directly into `<script>` blocks or HTML attributes like `onclick`.
- **CSP headers** — HTML reports should not load external resources; all CSS/JS must be inline.

## Data Protection

- **No raw PII in ZIP exports** — Never bundle unmasked Graph API CSV files containing UPNs, display names, or email addresses in ZIP deliverables. Aggregate or anonymize first.
- **No secrets in code** — Never hardcode client secrets, certificates, tokens, passwords, or API keys. All credentials must come from parameters, environment variables, or interactive prompts.
- **No secrets in commits** — Commit messages and PR descriptions must not contain credentials, tenant IDs, or other sensitive identifiers.

## File Handling

- **Validate file paths** — Sanitize any user-provided file paths to prevent path traversal.
- **Temp file cleanup** — Remove intermediate files containing sensitive data in the cleanup phase.
- **UTF-8 encoding** — All output files must use UTF-8 encoding without BOM.
