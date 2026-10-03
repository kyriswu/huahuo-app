# Digital-twin invariants

- Material, proposal, confirmation and report state is scoped by account and
  Workspace; stale responses are rejected.
- Chat acceptance, service attempt ownership, formal report persistence and
  report readability are separate facts.
- A proposal may be applied only with its current version/ETag, canonical owner,
  source identity and idempotency key.
- A lost response is recovered by reading the same operation or proposal; it is
  not resolved by submitting a duplicate operation.
- Existing formal content remains visible while a later run is processing.
- A candidate, preview, Assistant response or task `accepted` status cannot stand
  in for a formal version or readable report.
- Background resume follows the persisted checkpoint. It must not create a new
  paid run or clear a mismatched local receipt.
