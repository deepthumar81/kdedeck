import assert from 'node:assert/strict';
import test from 'node:test';

class FakeClassList {
    constructor() { this.values = new Set(); }
    add(...values) { values.forEach((value) => this.values.add(value)); }
    remove(...values) { values.forEach((value) => this.values.delete(value)); }
    contains(value) { return this.values.has(value); }
}

class FakeElement {
    constructor(id = '') {
        this.id = id;
        this.children = [];
        this.listeners = new Map();
        this.classList = new FakeClassList();
        this.style = {};
        this.attributes = {};
        this.options = [];
        this.value = '';
        this.checked = true;
        this.disabled = false;
        this.textContent = '';
        this.src = '';
    }
    addEventListener(type, listener) { this.listeners.set(type, listener); }
    dispatch(type, event = {}) {
        return this.listeners.get(type)?.({ target: this, preventDefault() {}, ...event });
    }
    appendChild(child) { this.children.push(child); return child; }
    append(...children) { children.forEach((child) => this.appendChild(child)); }
    replaceChildren(...children) { this.children = children; }
    setAttribute(name, value) { this.attributes[name] = String(value); }
    getAttribute(name) { return this.attributes[name] ?? null; }
    focus() {}
    remove() {}
    cloneNode() { return new FakeElement(); }
    querySelectorAll() { return []; }
}

class FakeStorage {
    #values = new Map();
    getItem(key) { return this.#values.get(key) ?? null; }
    setItem(key, value) { this.#values.set(key, String(value)); }
    removeItem(key) { this.#values.delete(key); }
}

class FakeWebSocket {
    static OPEN = 1;
    static instances = [];
    constructor(url) {
        this.url = url;
        this.readyState = FakeWebSocket.OPEN;
        this.sent = [];
        FakeWebSocket.instances.push(this);
    }
    send(payload) { this.sent.push(JSON.parse(payload)); }
    receive(message) { this.onmessage?.({ data: JSON.stringify(message) }); }
    open() { this.onopen?.(); }
    close() { this.onclose?.(); }
}

const elements = new Map();
const document = {
    body: new FakeElement('body'),
    getElementById(id) {
        if (!elements.has(id)) elements.set(id, new FakeElement(id));
        return elements.get(id);
    },
    createElement(tag) { return new FakeElement(tag); },
    createTextNode(text) { return new FakeElement(String(text)); },
    addEventListener() {},
};

const reloads = [];
globalThis.document = document;
globalThis.window = {
    sessionStorage: new FakeStorage(),
    localStorage: new FakeStorage(),
    location: {
        protocol: 'http:',
        host: 'localhost:8484',
        reload: () => reloads.push(true),
    },
    setTimeout,
    clearTimeout,
};
globalThis.WebSocket = FakeWebSocket;

await import(`./app.js?browser-e2e=${Date.now()}`);

function socket() {
    assert.equal(FakeWebSocket.instances.length, 1);
    return FakeWebSocket.instances[0];
}

test('browser pairing handles capacity and rate-limit errors without storing credentials', () => {
    const ws = socket();
    ws.open();
    ws.receive({ type: 'auth_required' });
    assert.equal(elements.get('connection-status').textContent, 'Pairing required');
    assert.equal(elements.get('auth-modal').classList.contains('show'), true);

    ws.receive({ type: 'auth_error', code: 'session_capacity' });
    assert.match(elements.get('auth-error').textContent, /session limit/);
    assert.equal(window.sessionStorage.getItem('kdedeck.authToken'), null);

    ws.receive({ type: 'auth_error', code: 'rate_limited' });
    assert.match(elements.get('auth-error').textContent, /Too many attempts/);
    assert.equal(window.sessionStorage.getItem('kdedeck.authToken'), null);
});

test('browser authenticated errors preserve bounded recovery state', () => {
    const ws = socket();
    ws.receive({ type: 'auth_success', token: 'browser-e2e-token' });
    assert.equal(elements.get('connection-status').textContent, 'Online');
    assert.equal(window.sessionStorage.getItem('kdedeck.authToken'), 'browser-e2e-token');

    ws.receive({
        type: 'init_state',
        config: { boards: [{ id: 'board', items: [] }] },
        revision: 4,
        state: {},
    });
    ws.receive({ type: 'action_error', action: 'open_url' });
    assert.equal(elements.get('connection-status').textContent, 'Action failed: open_url');

    ws.receive({ type: 'config_error', code: 'invalid_config' });
    assert.match(elements.get('connection-status').textContent, /rejected this configuration/);
    assert.equal(elements.get('reload-config-btn').style.display, 'none');

    ws.receive({ type: 'config_error', code: 'config_conflict' });
    assert.equal(elements.get('reload-config-btn').style.display, 'block');
    assert.equal(elements.get('reload-config-btn').disabled, false);
    assert.equal(reloads.length, 0);
});
