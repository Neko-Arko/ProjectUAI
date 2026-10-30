# Vercel AI Gateway

Use **Providers > Add a provider > Vercel AI Gateway**. The preset uses
`https://ai-gateway.vercel.sh/v1`, Chat Completions and Bearer authentication.

1. Open AI Gateway in the dashboard for the Vercel team you intend to bill.
2. Create an AI Gateway API key and paste it into UAI's API key field.
3. Fetch models, search for the exact provider/model ID, select it and save.
4. Check that the selected model is included in your team's current tier before
   sending a request. Use a tool-capable model for agent tasks.

The documented free tier grants $5 in monthly credits for a subset of models,
with lower per-model rate limits. The public catalog includes paid models too.
Purchasing credits moves the account to the paid tier and ends the monthly free
credit grant. A catalog price of zero is not proof that your account has access.

UAI keeps catalog entries whose documented `type` is `language`; embedding,
image, speech and other explicit types use different APIs and are omitted.
Streaming and tool calling use the OpenAI-compatible Chat Completions route.
The model's supported parameters still decide which features can be requested.

If discovery succeeds but inference fails, check team ownership of the key,
the Free Tier model list, remaining credits and the model's rate limit. Refresh
models after changing the key or team. UAI never selects a paid model for you
merely because you added this preset.

Official sources:

- [Chat Completions API](https://vercel.com/docs/ai-gateway/sdks-and-apis/openai-chat-completions)
- [Pricing and free tier](https://vercel.com/docs/ai-gateway/pricing)
