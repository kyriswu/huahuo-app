# iOS physical-device debugging runbook

This runbook is read-only with respect to the server and device application
container. It is for a connected physical iPhone; a Simulator is not equivalent.

1. From `Flutter/src`, run `flutter devices` and choose an iOS device whose
   description does not contain `simulator`. Confirm it is unlocked and has
   Developer Mode enabled.
2. Attach with `flutter attach -d <UDID>`. Reproduce the issue, then type `d` to
   detach while leaving the app running. Do not type `q`.
3. If console output is insufficient, copy `Documents/recordings` to a fresh
   temporary directory with `xcrun devicectl device copy from`. Preserve the
   SQLite main file plus `-wal` and `-shm`; query the copy with `sqlite3 -readonly`.
4. Inspect diagnostic logs, upload drafts, transcription receipts and chat
   checkpoints. Use `json_extract` for JSON fields.
5. Correlate only by recorded IDs, user scope and UTC timestamps with read-only
   server access. Do not edit, redeploy, migrate or requeue server data.

Always state whether evidence came from a physical device, Simulator, local
SQLite copy, app console or server logs. Missing logs are an observability gap,
not evidence that a state-machine phase did not execute.
