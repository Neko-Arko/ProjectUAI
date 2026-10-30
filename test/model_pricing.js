// Normalization regressions: provider identity, zero prices, precision, failure.
const assert = require('node:assert/strict');
const { normalize, render, snapshotText } = require('../tools/sync_pricing');
const raw = { modelsdev: {}, litellm: {}, openrouter: { data: [] }, kilo: { data: [] },
	cline: { free: [{ id: 'vendor/promotion' }], recommended: [{ id: 'vendor/paid' }] } };
for (const provider of ['openai', 'anthropic', 'google', 'deepseek', 'opencode', 'opencode-go', 'groq', 'togetherai', 'mistral', 'xai', 'fireworks-ai', 'cerebras']) {
	raw.modelsdev[provider] = { models: { fixture: { cost: { input: 3, output: 6 }, limit: { context: 10000, output: 2000 }, tool_call: true } } };
}
for (let index = 0; index < 100; index++) raw.openrouter.data.push({ id: 'vendor/model-' + index, pricing: { prompt: '0.000000091', completion: '0.000000182', input_cache_read: '0.0000000182' } });
raw.kilo.data = raw.openrouter.data.map(model => ({ ...model, context_length: 32000 }));
raw.kilo.data.push({ id: 'vendor/free', isFree: true, pricing: { prompt: '0', completion: '0' } });
raw.kilo.data.push({ id: 'vendor/dynamic', context_length: 64000, pricing: { prompt: '0', completion: '0' } });
raw.openrouter.data.push({ id: 'vendor/model-0:free', pricing: { prompt: '0', completion: '0' } });
raw.litellm['openai/fixture'] = { litellm_provider: 'openai', mode: 'chat', input_cost_per_token: 0.000009, output_cost_per_token: 0.000018 };
raw.litellm['anthropic/vendor/retained'] = { litellm_provider: 'anthropic', mode: 'chat', input_cost_per_token: 0.000002, output_cost_per_token: 0.000010 };
const providers = normalize(raw);
assert.equal(providers.openai.fixture.price.input, 3, 'models.dev takes precedence over supplemental rates');
assert.equal(providers['opencode-go'].fixture.price, undefined, 'catalog rates do not establish an additional subscription charge');
assert.equal(providers['opencode-go'].fixture.context, 10000, 'Go retains its own model limits');
assert.equal(providers.anthropic['vendor/retained'].price.input, 2, 'only the known LiteLLM provider prefix is removed');
assert.equal(providers.openrouter['vendor/model-0'].price.input, 0.091);
assert.equal(providers.openrouter['vendor/model-0'].price.cacheRead, 0.0182, 'sub-microtoken prices retain precision');
assert.equal(providers.openrouter['vendor/model-0:free'].price.input, 0);
assert.equal(providers.openrouter['model-0'], undefined, 'model namespaces are not erased');
assert.equal(providers.kilo['vendor/model-0'].price.input, 0.091, 'Kilo uses its own declared token prices');
assert.equal(providers.kilo['vendor/free'].price.input, 0, 'explicit Kilo free models have zero token rates');
assert.equal(providers.kilo['vendor/dynamic'].price, undefined, 'unverified zero placeholders do not imply free access');
assert.equal(providers.kilo['vendor/dynamic'].context, 64000, 'unpriced models retain documented limits');
assert.equal(providers.cline['vendor/promotion'].price.input, 0, 'only exact official Cline promotions are free');
assert.equal(providers.cline['vendor/paid'], undefined, 'recommended models are not implicitly free');
assert.equal(providers.cline['vendor/promotion'].context, undefined, 'promotion names do not invent model limits');
assert.throws(() => normalize({ ...raw, openrouter: { data: [] } }), /incomplete model list/);
assert.throws(() => normalize({ ...raw, kilo: { data: [] } }), /incomplete model list/);
assert.throws(() => normalize({ ...raw, cline: {} }), /Incomplete catalog sources/);
assert.throws(() => normalize({ ...raw, cline: { free: [{ id: 'invalid model' }] } }), /invalid free model ID/);
assert.throws(() => normalize(raw, [{ id: 'paid', cost: [{ input: 1, output: 1 }] }]), /verified free rates/);
const snapshot = { schema: 1, updated: '2026-10-15T00:00:00.000Z', sources: {}, providers };
assert.equal(render(JSON.parse(snapshotText(snapshot))), render(snapshot), 'offline generation is deterministic');
console.log('Model pricing normalization: 21 assertions passed.');
