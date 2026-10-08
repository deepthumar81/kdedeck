import test from 'node:test';
import assert from 'node:assert/strict';
import {
    authErrorMessage,
    configErrorMessage,
    hasUsableRevision,
    shouldPreserveLocalDraft,
} from './ui_policy.mjs';

test('maps bounded authentication failures to actionable messages', () => {
    assert.match(authErrorMessage('rate_limited'), /Too many attempts/);
    assert.match(authErrorMessage('session_capacity'), /session limit/);
    assert.match(authErrorMessage('insufficient_permissions'), /not allowed/);
    assert.match(authErrorMessage('unknown'), /not accepted/);
});

test('maps config failures without discarding the local draft', () => {
    assert.match(configErrorMessage('config_conflict'), /preserved/);
    assert.match(configErrorMessage('invalid_config'), /preserved/);
    assert.match(configErrorMessage('unknown'), /preserved/);
    assert.equal(shouldPreserveLocalDraft({ boards: [] }, true), true);
    assert.equal(shouldPreserveLocalDraft({ boards: [] }, false), false);
    assert.equal(shouldPreserveLocalDraft(null, true), false);
});

test('accepts only non-negative safe integer revisions', () => {
    assert.equal(hasUsableRevision(0), true);
    assert.equal(hasUsableRevision(4), true);
    assert.equal(hasUsableRevision(-1), false);
    assert.equal(hasUsableRevision(1.5), false);
    assert.equal(hasUsableRevision(Number.MAX_SAFE_INTEGER + 1), false);
});
