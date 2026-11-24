import test from 'node:test';
import assert from 'node:assert/strict';
import {acceptanceFixture, password, issuer} from './test-support/acceptance-fixture.mjs';

async function reachLimit(attempt, ordinaryStatus) {
  for (let count = 0; count < 16; count++) {
    const response = await attempt();
    if (response.status === 429) return;
    assert.equal(response.status, ordinaryStatus);
  }
  assert.fail('Repeated authentication attempts must reach a bounded HTTP 429 response');
}
const approve = (f, grant, email, mode = 'login', secret = password) =>
  f.request('/oauth/approve', {request: grant.id, email, password: secret, mode}, {form: true});

test('REST login limits attempts without writes, isolates accounts and recovers after cooldown',
  {timeout: 15000}, async t => {
    const f = await acceptanceFixture(t);
    await f.register('owner@example.com');
    await f.register('other@example.com');
    const before = f.counts();
    await reachLimit(() => f.request('/v1/auth/login',
      {email: 'owner@example.com', password: 'incorrect'}), 401);
    assert.deepEqual(f.counts(), before, 'Failed or throttled logins do not issue sessions');
    assert.equal((await f.request('/v1/auth/login',
      {email: 'owner@example.com'.toUpperCase(), password})).status, 429);
    const grant = await f.begin();
    assert.equal((await approve(f, grant, 'owner@example.com')).status, 429,
      'OAuth and REST share the same login limit');
    assert.equal((await f.request('/v1/auth/login',
      {email: 'other@example.com', password})).status, 200);
    f.advance(600000 - 1);
    assert.equal((await f.request('/v1/auth/login',
      {email: 'owner@example.com', password})).status, 429);
    f.advance(2);
    assert.equal((await f.request('/v1/auth/login',
      {email: 'owner@example.com', password})).status, 200);
    assert.equal(f.counts().accounts, before.accounts);
  });

test('OAuth login cooldown preserves the pending grant and permits a fresh PKCE exchange',
  {timeout: 15000}, async t => {
    const f = await acceptanceFixture(t);
    await f.register('oauth@example.com');
    const grant = await f.begin();
    const before = f.counts();
    await reachLimit(() => approve(f, grant, 'oauth@example.com', 'login', 'incorrect'), 200);
    assert.deepEqual(f.counts(), before, 'Failure must not issue an authorization code or token');
    assert.ok(f.app.store.oauthRequest(grant.id), 'Throttling does not consume the grant');
    assert.equal((await f.request('/v1/auth/login',
      {email: 'oauth@example.com', password})).status, 429);
    f.advance(600000 - 1);
    assert.equal((await approve(f, grant, 'oauth@example.com')).status, 429);
    f.advance(2);
    const fresh = await f.begin(); // The original request has its own ten-minute expiry.
    const approved = await approve(f, fresh, 'oauth@example.com');
    assert.equal(approved.status, 302);
    const callback = new URL(approved.headers.get('location'));
    assert.equal(callback.searchParams.get('iss'), issuer);
    const exchange = await f.request('/oauth/token', {
      grant_type: 'authorization_code', code: callback.searchParams.get('code'),
      client_id: fresh.client, redirect_uri: fresh.redirect, code_verifier: fresh.verifier,
    }, {form: true});
    assert.equal(exchange.status, 200);
  });

for (const transport of ['REST', 'OAuth']) {
  test(transport + ' registration is rate limited and recovers without changing an existing account',
    {timeout: 15000}, async t => {
      const f = await acceptanceFixture(t);
      await f.register('existing@example.com');
      let grant = transport === 'OAuth' ? await f.begin() : null;
      const attempt = () => transport === 'OAuth'
        ? approve(f, grant, 'existing@example.com', 'register')
        : f.request('/v1/auth/register', {email: 'existing@example.com', password});
      const before = f.counts();
      await reachLimit(attempt, transport === 'OAuth' ? 200 : 409);
      assert.deepEqual(f.counts(), before);
      assert.equal((await attempt()).status, 429);
      await f.register('independent@example.com');
      f.advance(600001);
      if (transport === 'OAuth') grant = await f.begin();
      assert.equal((await attempt()).status, transport === 'OAuth' ? 200 : 409);
      assert.equal(f.counts().accounts, before.accounts + 1);
      assert.equal(f.counts().tokens, before.tokens + 1);
    });

  test(transport + ' login keeps equivalent canonical account emails inside the same rate limit',
    {timeout: 15000}, async t => {
      const f = await acceptanceFixture(t);
      await f.register('canonical@example.com');
      await reachLimit(() => f.request('/v1/auth/login',
        {email: 'canonical@example.com', password: 'incorrect'}), 401);
      const before = f.counts();
      const alias = '  canonical@example.com  '.toUpperCase();
      const response = transport === 'OAuth'
        ? await approve(f, await f.begin(), alias, 'login', 'incorrect')
        : await f.request('/v1/auth/login', {email: alias, password: 'incorrect'});
      assert.equal(response.status, 429,
        'An email accepted as the same account must not create a separate attempt bucket');
      assert.deepEqual(f.counts(), before);
    });
}

for (const transport of ['REST', 'OAuth']) {
  test(transport + ' registration keeps canonical email aliases inside the same rate limit',
    {timeout: 15000}, async t => {
      const f = await acceptanceFixture(t);
      await f.register('registration@example.com');
      await reachLimit(() => f.request('/v1/auth/register',
        {email: 'registration@example.com', password}), 409);
      const before = f.counts();
      const alias = '  registration@example.com  '.toUpperCase();
      const response = transport === 'OAuth'
        ? await approve(f, await f.begin(), alias, 'register')
        : await f.request('/v1/auth/register', {email: alias, password});
      assert.equal(response.status, 429);
      assert.deepEqual(f.counts(), before);
    });
}

test('distinct long account emails do not collide through a truncated attempt key',
  {timeout: 15000}, async t => {
    const f = await acceptanceFixture(t);
    const common = 'person@' + 'a'.repeat(60) + '.' + 'b'.repeat(60) + '.' + 'c'.repeat(52);
    const first = common + 'x.example.com';
    const second = common + 'y.example.com';
    await f.register(first);
    await f.register(second);
    await reachLimit(() => f.request('/v1/auth/login',
      {email: first, password: 'incorrect'}), 401);
    assert.equal((await f.request('/v1/auth/login', {email: second, password})).status, 200,
      'Only the account whose canonical identity reached its limit is locked');
  });


test('oversized invalid emails retain normal opaque validation and authentication errors',
  {timeout: 15000}, async t => {
    const f = await acceptanceFixture(t);
    await f.register('valid@example.com');
    const before = f.counts();
    const email = 'x'.repeat(128 * 1024) + '@example.com';
    const registration = await f.request('/v1/auth/register', {email, password});
    assert.equal(registration.status, 422);
    assert.equal(registration.value.error, 'invalid_signup');
    const login = await f.request('/v1/auth/login', {email, password});
    assert.equal(login.status, 401);
    assert.equal(login.value.error, 'invalid_credentials');
    for (const mode of ['register', 'login']) {
      const response = await approve(f, await f.begin(), email, mode);
      assert.equal(response.status, 200);
      assert.equal(response.value.includes(email), false, 'Invalid input is not reflected');
    }
    assert.deepEqual(f.counts(), before, 'Invalid oversized identities never mutate account data');
    assert.equal((await f.request('/v1/auth/login',
      {email: 'valid@example.com', password})).status, 200);
  });
