# Contributing

KeepItClean accepts focused changes that make developer-storage review safer, clearer, or more accurate.

Before proposing a cleanup rule, provide:

- measured allocated bytes on a real tool version;
- the exact disposable leaves;
- an explicit list of protected siblings;
- an active-process/reference probe;
- rebuild cost and failure behavior;
- fixture tests proving non-targets remain excluded.

Run:

```bash
swift test
swift build -c release
./scripts/verify-safety.sh
```

Never test a mutation against a real home directory. Use a marker-guarded temporary fixture. Mutation-gateway changes require line-by-line review.
