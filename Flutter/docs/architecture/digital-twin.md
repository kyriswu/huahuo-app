# Digital-twin architecture

Digital-twin material processing separates material intake, synchronization,
proposal discovery, user review, confirmation, formal-version persistence and
report readback. A proposal is a server-side candidate/version object, not a
client-created Markdown document.

All durable operations are scoped by authenticated account and Workspace. A
response or task from another account, Workspace, run or attempt is stale and
must not update the current projection. Confirmation uses the proposal version,
strong ETag and an idempotency key; a successful request still requires formal
version/report evidence before the UI publishes completion.

Long-running work is owned by a persisted task/run checkpoint, not a page
lifecycle. Foreground and background behavior pauses observation or resumes the
same checkpoint; it does not create a second paid run.
