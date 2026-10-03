# Async ownership and recovery invariants

- Every asynchronous callback carries enough identity to prove it belongs to
  the current account, entity, Workspace, operation generation and route intent.
- Cancellation, cleanup and completion are separate phases. Do not clear UI
  state early to pretend native work has stopped.
- Persist the operation intent and idempotency identity before an uncertain
  network or native boundary. Recovery replays or reads the same operation.
- Temporary failure enters a bounded retry state only when the protocol marks it
  recoverable. It must not be shown as a final failure or a success guessed from
  time passing.
- Backgrounding pauses eligible follow-up work, not already committed facts.
  Foreground recovery is bounded and generation-aware.
- A database transaction in memory is not a durable checkpoint until the writer
  flush confirms it.
