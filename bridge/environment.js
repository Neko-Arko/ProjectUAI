'use strict';

// What an external MCP harness is told about the runtime.
//
// In the native client, `runtime/script_development_docs` supplies this model as
// part of the system prompt. A harness such as Claude Code, Codex or Cursor brings
// its own system prompt instead and never sees ours, so the same facts have to
// travel with the protocol or the model falls back to its default prior: that it is
// helping someone build a Roblox experience in Studio.

// Sent once per session in the initialize result. Harness support for `instructions`
// varies, so nothing depends on it alone.
const INSTRUCTIONS = [
	'Project UAI tools act on one live Roblox client that the user has already joined.',
	'Roblox Studio is never involved: there is no place file, no edit session and no publish step.',
	"Reads observe this client's replicated DataModel. Writes change this client only, and the game server can overwrite them; server-authoritative rules cannot be changed from here.",
	'Approve permission prompts in Project UAI.',
	'Each MCP connection has its own conversation; no model inference runs in this bridge.',
	'After an uncertain result, inspect the client before repeating an action.',
].join(' ');

// Prepended to every tool description, because descriptions are the one part of the
// protocol every harness reliably puts in front of the model. Repetition is the point.
const DESCRIPTION_PREFIX = 'Live Roblox client, not Studio or a server. ';

module.exports = { INSTRUCTIONS, DESCRIPTION_PREFIX };
