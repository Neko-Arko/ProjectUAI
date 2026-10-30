# Nscale

Use **Providers > Add a provider > Nscale**. The serverless inference base is
`https://inference.api.nscale.com/v1`; keep Chat Completions and Bearer auth.

1. Create an Nscale account, configure billing and add credits.
2. Create an API key in the dashboard and paste it into UAI.
3. Fetch models and select an exact serverless model ID. If your account cannot
   list models, use the exact ID documented in the dashboard's inference example.
4. Save and verify a short request before sending a longer conversation.

Nscale may offer promotional credits to eligible accounts. This preset is in the
paid group because promotional eligibility is not a guaranteed free allowance.
Usage follows the selected model's token pricing and your account's limits.

The documented inference server is `inference.api.nscale.com`; the chat endpoint
is `/v1/chat/completions`. Keep the inference URL instead of a dashboard or
infrastructure-management API URL. Catalog requests require authentication.

The Chat Completions contract accepts OpenAI-style tool definitions, but select
a model whose capabilities support your intended tool workflow. A 401 while
listing models calls for checking the key and auth style. A quota or funding
response calls for checking the account dashboard; repeatedly refreshing models
does not replenish credits.

Official sources:

- [Inference quickstart](https://docs.nscale.com/docs/getting-started/quickstart)
- [Chat Completions reference](https://docs.nscale.com/api-reference/inference/create-chat-completion)
