# Security Policy

Mizzy is an independent open-source POS project under active development. It is not yet approved for production use, and cloud synchronization, payments, and the complete authorization model have not all been validated.

## Reporting a vulnerability

Please do not publish exploit details, active credentials, customer records, database dumps, or other sensitive data in a public issue or pull request.

For a suspected vulnerability, use GitHub's private vulnerability reporting feature for this repository if it is enabled. Otherwise, contact the repository maintainer through their GitHub profile and ask for a private reporting channel. Include the affected commit or file path, impact, and reproducible steps with synthetic/test data only. Do not include real customer data or live secrets in the report.

## Credential exposure

If a secret or credential may have been committed or exposed:

1. Revoke or rotate it immediately at the issuing provider.
2. Review provider audit logs and access activity.
3. Remove the secret from the current files and assess whether Git history also needs remediation.
4. Do not rely on deleting a file or rewriting Git history as a substitute for rotating the credential.

Never commit Supabase service-role keys, secret API keys, database passwords, signing keys, access tokens, production customer data, or production backups. A Supabase publishable/anon key may be used in a client only when appropriate Row Level Security (RLS), grants, and server-side authorization are enforced. A client key is not an authorization boundary.

## Verification and deployment

- Treat migrations and authenticated cloud workflows as drafts until their tests run against an isolated test database and negative authorization tests pass.
- Do not use real customer or payment data in tests, screenshots, bug reports, fixtures, or CI artifacts.
- Do not deploy migrations or production infrastructure as part of an unreviewed pull request.
- CI success is necessary but does not by itself establish production readiness.

## Supported release status

There are currently no production-supported releases. The default branch is a development baseline; validate the exact commit and run the documented checks before testing or deploying it.
