# Contributing

Small, focused changes are easiest to review. Describe the user-visible behavior, privacy impact, and any migration or release implications in the pull request.

Before submitting a change, run:

```bash
scripts/verify.sh
```

Changes to updates, installation, release packaging, local telemetry, or app-server transport should include focused regression tests in addition to the full verification gate. Never commit credentials, signing material, account identifiers, prompts, messages, tool payloads, or captured raw protocol data.

The repository does not currently declare an open-source license. Contribution or redistribution terms must be established by the repository owner before outside contributions are accepted; public source visibility alone does not grant reuse rights.
