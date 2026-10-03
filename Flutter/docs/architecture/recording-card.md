# Recording-card architecture

Recording-card is a device-to-local-library pipeline with separate facts for
connection, authorization, directory observation, device operation ownership,
BLE/Wi-Fi transfer, local registration, cloud upload, transcription and UI
projection. No single `syncing` or `completed` flag may stand for all of these.

The application controller and auto-sync coordinator own orchestration. Native
ports own device operations. The local recording library and sync ledger own
persistence facts. Upload and transcription are independent remote tasks.

The user-visible projection consumes these facts and cannot create domain
transitions by itself. Use Graphify to discover current symbols and callers;
use `docs/invariants/recording-card.md` for rules that must survive refactors.
