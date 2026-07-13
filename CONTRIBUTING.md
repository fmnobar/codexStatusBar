# Contributing

Small, focused changes are easiest to review. Describe the user-visible behavior, privacy impact, and any migration or release implications in the pull request.

Before submitting a change, run:

```bash
scripts/verify.sh
```

Changes to updates, installation, release packaging, local telemetry, or app-server transport should include focused regression tests in addition to the full verification gate. Never commit credentials, signing material, account identifiers, prompts, messages, tool payloads, or captured raw protocol data.

The repository is available under the [MIT License](LICENSE). Contributions are accepted under the same terms.
