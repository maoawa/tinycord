const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync(process.argv[2], 'utf8');

function input(attributes) {
    const values = {...attributes};
    return {
        getAttribute: name => values[name] ?? null,
        setAttribute: (name, value) => { values[name] = value; },
        get value() { throw new Error('Login support must never read credential values'); },
        values,
    };
}
function fixture({origin = 'https://discord.com', child = false, path = '/login', parser = 'available', bridgeThrows = false} = {}) {
    let observer, focus;
    const listeners = {};
    const fields = [], events = [];
    const originalError = Object.assign(new Error('Expected rejection'), {name: 'SecurityError'});
    let nextError = originalError, synchronous = false, parserError = null;
    const userActivation = {isActive: false};
    const parsed = {synthetic: true};
    const publicKey = {};
    if (parser === 'available') publicKey.parseRequestOptionsFromJSON = function() {
        assert.equal(this, publicKey);
        if (parserError) throw parserError;
        return parsed;
    };
    const credential = {id: 'synthetic-credential'};
    const credentials = {get: function(options) {
        assert.equal(this, credentials, 'Preserve CredentialsContainer receiver');
        if (synchronous && nextError) throw nextError;
        return nextError ? Promise.reject(nextError) : Promise.resolve(credential);
    }};
    const originalGet = credentials.get;
    const window = {webkit: {messageHandlers: {discordLoginEvent: {postMessage: value => { if (bridgeThrows) throw new Error('Bridge missing'); events.push(value); }}}}};
    window.PublicKeyCredential = publicKey;
    window.top = child ? {} : window;
    const context = {
        window, location: {origin, pathname: path}, navigator: {credentials, userActivation},
        document: {
            querySelectorAll: selector => { assert.equal(selector, 'input'); return fields; },
            addEventListener: (event, handler) => { listeners[event] = handler; if (event === 'focusin') focus = handler; },
        },
        MutationObserver: class {
            constructor(callback) { observer = callback; }
            observe() {}
        },
        queueMicrotask, setTimeout,
    };
    vm.runInNewContext(source, context);
    return {fields, events, credentials, publicKey, userActivation, parsed,
        interact: (isTrusted = true) => listeners.click({isTrusted}),
        sync: () => { synchronous = true; }, parserError: value => { parserError = value; }, originalGet, originalError, credential,
        mutate: () => observer(), focus: () => focus(), error: value => { nextError = value; }};
}
(async () => {
    for (const options of [{origin: 'https://discord.com.evil.example'}, {origin: 'http://discord.com'}, {child: true}]) {
        const f = fixture(options);
        assert.equal(f.credentials.get, f.originalGet, 'Do not hook foreign origins or child frames');
    }
    const f = fixture();
    const username = input({name: 'email', type: 'text', autocomplete: 'off'});
    const password = input({type: 'password'});
    const hidden = input({name: 'email', type: 'hidden'});
    const newPassword = input({type: 'password', autocomplete: 'new-password'});
    f.fields.push(username, password, hidden, newPassword);
    await Promise.resolve();
    assert.equal(username.values.autocomplete, 'username');
    assert.equal(username.values.autocapitalize, 'none');
    assert.equal(password.values.autocomplete, 'current-password');
    assert.equal(newPassword.values.autocomplete, 'new-password');
    assert.equal(hidden.values.autocomplete, undefined);
    const code = input({name: 'mfa_code', type: 'text'});
    f.fields.splice(0, f.fields.length, code);
    f.mutate();
    await Promise.resolve();
    assert.equal(code.values.autocomplete, 'one-time-code', 'Annotate dynamically replaced MFA forms');

    await assert.rejects(f.credentials.get({publicKey: {challenge: 'not-forwarded'}}),
        error => error === f.originalError, 'Keep the original WebAuthn rejection');
    assert.deepEqual(f.events, ['passkey-unavailable'], 'No challenge/credential data sent in help events');
    for (const options of [{password: true}, {publicKey: {}, mediation: 'conditional'}, {publicKey: {}, mediation: 'silent'}]) {
        await assert.rejects(f.credentials.get(options));
    }
    f.error(Object.assign(new Error('Cancelled'), {name: 'AbortError'}));
    await assert.rejects(f.credentials.get({publicKey: {}}));
    assert.equal(f.events.length, 1, 'Do not show passkey errors for passive requests or user cancellation');
    f.error(null);
    assert.equal(await f.credentials.get({publicKey: {}}), f.credential, 'Preserve successful credentials');
    assert.equal(f.events.length, 1);

    // Localized error messages never participate in detection.
    for (const message of ['An error occurred.', '发生错误，请重试。', 'Une erreur est survenue.']) {
        const sync = fixture();
        const error = Object.assign(new Error(message), {name: 'NotSupportedError'});
        sync.error(error);
        sync.sync();
        assert.throws(() => sync.credentials.get({publicKey: {}}), e => e === error);
        assert.deepEqual(sync.events, ['passkey-unavailable']);
        assert.throws(() => sync.credentials.get({publicKey: {}}));
        assert.equal(sync.events.length, 1, 'Do not repeatedly interrupt the same login document');
    }
    for (const name of ['AbortError']) {
        const unrelated = fixture();
        unrelated.error(Object.assign(new Error('An error occurred. Please try again.'), {name}));
        await assert.rejects(unrelated.credentials.get({publicKey: {}}));
        assert.deepEqual(unrelated.events, [], 'Generic error text is not a passkey signal');
    }
    const unknownFailure = fixture();
    unknownFailure.error(Object.assign(new Error('发生错误'), {name: 'UnknownError'}));
    await assert.rejects(unknownFailure.credentials.get({publicKey: {}}));
    assert.deepEqual(unknownFailure.events, ['passkey-unavailable'], 'WebKit can use generic error names');

    const preparation = fixture();
    assert.equal(preparation.publicKey.parseRequestOptionsFromJSON({}), preparation.parsed);
    preparation.userActivation.isActive = true;
    const parseError = new TypeError('Synthetic unsupported request');
    preparation.parserError(parseError);
    assert.throws(() => preparation.publicKey.parseRequestOptionsFromJSON({}), e => e === parseError);
    await assert.rejects(preparation.credentials.get({publicKey: {}}));
    assert.deepEqual(preparation.events, ['passkey-unavailable'], 'Preparation and get failures are deduplicated');

    const missing = fixture({parser: 'missing'});
    assert.equal(typeof missing.publicKey.parseRequestOptionsFromJSON, 'undefined');
    await new Promise(resolve => setTimeout(resolve, 0));
    assert.deepEqual(missing.events, [], 'Passive feature detection does not show help');
    missing.userActivation.isActive = true;
    assert.throws(() => missing.publicKey.parseRequestOptionsFromJSON({}), TypeError);
    await new Promise(resolve => setTimeout(resolve, 0));
    assert.deepEqual(missing.events, ['passkey-unavailable'], 'Detect preflight failure without reading page text');

    const delayed = fixture({parser: 'missing'});
    delayed.interact();
    delayed.userActivation.isActive = false;
    assert.throws(() => delayed.publicKey.parseRequestOptionsFromJSON({}), TypeError);
    await new Promise(resolve => setTimeout(resolve, 0));
    assert.deepEqual(delayed.events, ['passkey-unavailable'], 'Delayed MFA preparation survives expired transient activation');

    const noActivationAPI = fixture({parser: 'missing'});
    noActivationAPI.interact();
    delete noActivationAPI.userActivation.isActive;
    assert.throws(() => noActivationAPI.publicKey.parseRequestOptionsFromJSON({}), TypeError);
    await new Promise(resolve => setTimeout(resolve, 0));
    assert.deepEqual(noActivationAPI.events, ['passkey-unavailable'], 'Older WebKit still reports delayed preparation failures');

    const synthetic = fixture({parser: 'missing'});
    synthetic.interact(false);
    assert.equal(typeof synthetic.publicKey.parseRequestOptionsFromJSON, 'undefined');
    await new Promise(resolve => setTimeout(resolve, 0));
    assert.deepEqual(synthetic.events, [], 'Script-generated clicks must not trigger help');

    const brokenBridge = fixture({bridgeThrows: true});
    await assert.rejects(brokenBridge.credentials.get({publicKey: {}}), e => e === brokenBridge.originalError);

    const registration = fixture({path: '/register'});
    const registerPassword = input({name: 'password', type: 'password'});
    registration.fields.push(registerPassword);
    await Promise.resolve();
    assert.equal(registerPassword.values.autocomplete, undefined, 'Leave registration form semantics alone');
    console.log('PASS: login AutoFill hints, dynamic MFA fields, origin isolation, and WebAuthn result preservation');
})().catch(error => { console.error(error); process.exitCode = 1; });
