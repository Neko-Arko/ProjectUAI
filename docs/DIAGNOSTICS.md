# Finding a failed request

Open **Logs & traces > Requests**. Search for a provider hostname, HTTP status,
tool tag or transport. Several words can match different fields: `kilo 429`
narrows the list to quota responses from Kilo. Clear the search to restore all
retained requests. Filtering never deletes evidence.

Select a row for its duration, response size, transport, request identity and
bounded error details. Requests with no HTTP response may be network failures or
cancelled work; an HTTP status describes a response received from the endpoint.
Use **Log** for application events. Its search includes source, level, message
and detail, so a request ID or status in the detail can be found directly.

**Copy** exports retained diagnostics, including rows outside the current
filter. **Copy details** exports only the selected row. A clipboard operation
that returns failure is shown as **Retry**. Provider request bodies and raw
headers are excluded from the request export; recognized credentials are
redacted. Review any diagnostic text before sharing your own application data.

Application logs retain at most 400 entries and drop old entries in batches.
Each stored source, message and detail is bounded, with a visible omission
marker for long values. Redaction runs before trimming, including retained
tails. Bursts are coalesced for display while retaining the latest event.
These limits bound diagnostic storage; they do not truncate model context or
tool source files.
