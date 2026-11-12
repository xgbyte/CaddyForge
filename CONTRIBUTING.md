# Contributing

Keep building and deployment independent. A build must never invoke systemctl or
write managed server paths. Do not overwrite existing release binaries or user
configuration. Retain the failure recovery path when editing deployment code.

For a script change run `bash tests/run.sh` and
`shellcheck -x scripts/*.sh tests/*.sh` from the repository root. Extend the isolated
transaction tests for deployment behavior changes. Use an isolated Debian 13 VM
for systemd integration checks; never use a production server for CI testing.

For dependency updates follow docs/compatibility.md, build both profiles, run
`python3 tests/http_smoke.py ARTIFACT`, and include actual compiler/architecture
results in the change description. Do not describe unexecuted checks as passed.

Do not submit credentials, generated binaries, `.tools/`, or `dist/`. Keep upstream
license notices when distributing compiled artifacts.
