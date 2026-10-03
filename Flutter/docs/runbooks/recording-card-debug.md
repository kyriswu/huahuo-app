# Recording-card debugging runbook

Start with Graphify `explain`, `path` or `affected` for the target symbol, then
verify the result in source and focused tests. Record the account scope, card
serial digest, connection revision, operation generation, batch ID, task IDs
and UTC timestamps without exposing credentials.

For a physical-device issue, follow `ios-real-device-debug.md`. Inspect the
local recording database copy and distinguish connection, directory, transfer,
local registration, upload and transcription facts. A UI label or native byte
percentage is not proof of a durable stage.

For code changes, add a focused regression for the race or invariant first when
practical. Do not change backend data while debugging. Keep the runbook about
procedure and evidence, not a copy of controller methods.

For FW920 frame handling and device log collection, see the dated
[Wi-Fi debugging guide](FW920_WIFI_TRANSFER_DEBUGGING_20260715.md).
Its historical device results do not establish acceptance for a new build.
