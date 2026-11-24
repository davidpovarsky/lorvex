import assert from 'node:assert/strict';
import {mkdtempSync, rmSync} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {createHash, randomBytes} from 'node:crypto';
import {createCloudServer} from '../server.mjs';

// Every connection, account, clock and database in these probes belongs to this
// local fixture. Neither the deployed service nor a personal account is used.
export const issuer = 'https://lorvex.example/cloud';
export const password = 'Isolated acceptance passphrase 2026';

export async function acceptanceFixture(t, options = {}) {
  const folder = mkdtempSync(path.join(os.tmpdir(), 'lorvex-acceptance-'));
  const dbFile = path.join(folder, 'database.sqlite');
  let now = Date.UTC(2026, 10, 24, 12);
  const app = createCloudServer({
    dbFile, publicOrigin: issuer, clock: () => now, ...options,
  });
  await new Promise(resolve => app.server.listen(0, '127.0.0.1', resolve));
  const address = 'http://127.0.0.1:' + app.server.address().port;
  t.after(async () => {
    app.server.closeAllConnections();
    await app.close();
    rmSync(folder, {recursive: true, force: true});
  });
  const request = async (route, body = null, {form = false, token} = {}) => {
    const response = await fetch(address + '/cloud' + route, {
      method: body === null ? 'GET' : 'POST',
      redirect: 'manual',
      signal: AbortSignal.timeout(5000),
      headers: {
        Origin: new URL(issuer).origin,
        ...(body === null ? {} : {'Content-Type': form
          ? 'application/x-www-form-urlencoded' : 'application/json'}),
        ...(token ? {Authorization: 'Bearer ' + token} : {}),
      },
      body: body === null ? undefined
        : form ? new URLSearchParams(body) : JSON.stringify(body),
    });
    const text = await response.text();
    let value;
    try { value = JSON.parse(text); } catch { value = text; }
    return {status: response.status, value, headers: response.headers};
  };
  const register = async email => {
    const response = await request('/v1/auth/register', {email, password});
    assert.equal(response.status, 201);
    return response.value;
  };
  const begin = async () => {
    const redirect = 'https://chatgpt.com/connector_platform_oauth_redirect';
    const registration = await request('/oauth/register', {redirect_uris: [redirect]});
    assert.equal(registration.status, 201);
    const client = registration.value.client_id;
    const verifier = randomBytes(48).toString('base64url');
    const page = await request('/oauth/authorize?' + new URLSearchParams({
      client_id: client, redirect_uri: redirect, response_type: 'code',
      code_challenge_method: 'S256',
      code_challenge: createHash('sha256').update(verifier).digest('base64url'),
      state: 'isolated-acceptance-state', scope: 'lorvex.read offline_access',
      resource: issuer + '/mcp', ui_locales: 'en',
    }));
    assert.equal(page.status, 200);
    const match = page.value.match(/name="request" value="([^"]+)"/);
    assert.ok(match, 'The real authorization page contains its request ID');
    return {id: match[1], client, verifier, redirect};
  };
  const counts = () => Object.fromEntries(
    ['accounts', 'entities', 'changes', 'receipts', 'tokens', 'audit', 'oauth_codes']
      .map(table => [table, app.store.get('SELECT count(*) AS n FROM ' + table).n]),
  );
  return {folder, dbFile, app, request, register, begin, counts,
    clock: () => now, advance: milliseconds => { now += milliseconds; }};
}
