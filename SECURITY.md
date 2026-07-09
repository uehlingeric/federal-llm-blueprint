# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in this repository, please report it using GitHub's private vulnerability reporting feature:

1. Go to the **Security** tab of the repository
2. Click **Report a vulnerability**
3. Provide details of the vulnerability

**Do not** open a public issue or pull request for security vulnerabilities.

## Supported Versions

This is a reference architecture in **pre-1.0 phase**. Only the latest minor version receives updates:

| Version | Supported |
|---------|-----------|
| 0.1.x   | Yes (latest minor only) |
| < 0.1.0 | No        |

For release history, see [CHANGELOG.md](CHANGELOG.md).

## Scope

This repository is a **Terraform reference architecture**—not a live service or managed offering. Security findings fall into three categories:

### In Scope

Vulnerabilities in:
- **Terraform module patterns and configuration**: insecure resource defaults, overly-permissive IAM policies, incomplete encryption, missing audit trails
- **Module interactions**: interface contracts that inadvertently create security gaps
- **Checkov policy implementations**: misconfigured security rules or gaps in the policy baseline
- **Documentation and control mapping**: misstatements about what controls are aligned to and how

### Out of Scope

- **Individual deployment misconfigurations**: if you misconfigure a variable or skip a required input, security issues in your deployed stack are your responsibility
- **Application-layer vulnerabilities**: prompt injection, output filtering, model-specific safety (see `agentic-rag` for application concerns)
- **AWS service vulnerabilities**: report those to AWS Security
- **Operational security**: If you store state in an unencrypted bucket or share credentials, that's a deployment issue, not a reference-architecture issue

## Response Expectations

- **Acknowledgment**: We will acknowledge receipt of your report within a few business days
- **Investigation**: We will investigate and assess the finding
- **Communication**: We will keep you informed of progress
- **Timeline**: We aim for best-effort resolution; no guaranteed SLA

We do not offer a bug bounty program.

## Secure Development Practices

This repository adheres to:

- **Version pinning**: All tool versions (Terraform, tflint, checkov, terraform-docs) are pinned in CI to prevent supply-chain surprises
- **Dependency review**: GitHub dependabot monitors Actions and terraform provider versions
- **Code review**: All changes require review before merge
- **Automated testing**: CI gates on formatting, validation, security checks, and tests
- **No repo-wide security skips**: Every Checkov skip is documented inline with justification

## Questions?

For security-related questions (not vulnerability reports), open a GitHub issue with the `security` label.
