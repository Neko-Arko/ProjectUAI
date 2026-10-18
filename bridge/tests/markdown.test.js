'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const markdown = require('../web/markdown');

test('assistant and tool Markdown render explicit HTTP links with escaped labels and destinations', () => {
  const html = markdown.render('Read [Roblox documentation](https://create.roblox.com/docs?q=one&lang=en) and [local docs](http://127.0.0.1:8790/).');
  assert.match(html, /href="https:\/\/create\.roblox\.com\/docs\?q=one&amp;lang=en"/);
  assert.match(html, /target="_blank" rel="noopener noreferrer">Roblox documentation<\/a>/);
  assert.match(html, /href="http:\/\/127\.0\.0\.1:8790\/"/);
  const escaped = markdown.render('[<img src=x onerror=alert>](https://example.com/"attack)');
  assert.doesNotMatch(escaped, /<img|"attack"/);
  assert.match(escaped, /&lt;img/);
});

test('Markdown never turns executable, relative or malformed destinations into links', () => {
  for (const destination of ['javascript:alert', 'data:text/html,attack', 'file:///private', '/api/command', 'https://', '//example.com']) {
    assert.doesNotMatch(markdown.render('[unsafe](' + destination + ')'), /<a\b/);
  }
  assert.doesNotMatch(markdown.render('`[literal](https://example.com)`'), /<a\b/);
  assert.doesNotMatch(markdown.render('```lua\n[code](https://example.com)\n```'), /<a\b/);
  assert.match(markdown.render('`[literal](https://example.com)`'), /<code>\[literal\]/);
});
