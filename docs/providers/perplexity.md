# Perplexity Orchestrator

Use **Providers > Add a provider > Perplexity Orchestrator**. Keep the base URL
`https://api.perplexity.ai/orchestrator/v1`, Chat Completions and Bearer auth.
The `orchestrator` path is required for this catalog and API.

1. Create a Perplexity API key and confirm that its API account has credits.
2. Paste the key into the preset, then fetch models.
3. Select an exact ID from the Orchestrator catalog and save.
4. Start with a short request before enabling a longer tool workflow.

This route serves open-weight chat models through a standard Chat Completions
interface. Perplexity's Agent, Search and legacy Sonar APIs have separate routes
and request contracts. A model ID from one of those APIs cannot be assumed to
work on Orchestrator. A Perplexity web-app subscription does not establish API
credit availability.

The model catalog requires authentication. A 401 while fetching usually means
the key is absent or rejected; check the API dashboard and the Bearer auth style.
If a listed model cannot run, inspect the account balance and current model
availability. Refreshing the catalog does not test inference capacity.

Use the model's documented tool support when choosing it for UAI's agent.
The preset does not add Perplexity's separate hosted web-search tools to UAI.

Official sources:

- [Orchestrator quickstart](https://docs.perplexity.ai/docs/router/quickstart)
- [Orchestrator models](https://docs.perplexity.ai/docs/router/models)
