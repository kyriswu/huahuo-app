# Recording-card invariants

- Account scope is part of repository and controller identity; an account switch
  cannot reuse the previous coordinator or callback.
- A card is identified by normalized serial digest. A card switch is distinct
  from an account switch.
- Connection revision, operation generation and operation kind guard every async
  success, failure and cancellation callback.
- A verified, locally registered file is a durable success fact. A late cancel,
  disconnect or later batch failure cannot undo it.
- A byte transfer reaching 100% is not local registration, cloud upload or final
  transcription.
- A cancellation acknowledgement is not operation completion. The owner remains
  held until the original transfer Future settles and cleanup is confirmed.
- A directory snapshot is frozen for planning. Directory drift requires
  re-planning; an old plan cannot be committed to a new card or revision.
- Persistence flush is the checkpoint boundary. Never publish a success time or
  completion checkpoint before the writer confirms it.
- BLE and Wi-Fi handoff is serial: BLE ownership and persistence settle before a
  Wi-Fi batch is created. A stale batch cannot restart BLE or overwrite a later
  batch.
- Local deletion, card absence, cloud processing and final transcription are
  independent facts with independent evidence.
