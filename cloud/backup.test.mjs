import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, readdirSync, statSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {createCloudServer} from './server.mjs';
import {acceptanceFixture, issuer} from './test-support/acceptance-fixture.mjs';

const snapshotScript = [
  'import hashlib,json,sqlite3,sys',
  'db=sqlite3.connect("file:"+sys.argv[1]+"?mode=ro",uri=True)',
  'try:',
  ' integrity=db.execute("PRAGMA integrity_check").fetchone()[0]',
  ' assert integrity=="ok"',
  ' tables=[row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type=\\\'table\\\' ORDER BY name")]',
  ' counts={name:db.execute("SELECT count(*) FROM "+name).fetchone()[0] for name in tables}',
  ' digest=hashlib.sha256("\\n".join(db.iterdump()).encode()).hexdigest()',
  ' print(json.dumps({"integrity":integrity,"counts":counts,"logicalSHA256":digest}))',
  'finally: db.close()',
].join('\n');

function python(script, args) {
  const result = spawnSync('python3', ['-c', script, ...args], {
    encoding: 'utf8', timeout: 15000, maxBuffer: 1024 * 1024,
  });
  assert.equal(result.status, 0, result.stderr || result.error?.message);
  return JSON.parse(result.stdout);
}

test('online backup restores populated WAL, account isolation, sessions and idempotency receipts',
  {timeout: 45000}, async t => {
    const f = await acceptanceFixture(t);
    const users = [
      await f.register('backup-one@example.com'),
      await f.register('backup-two@example.com'),
    ];
    const requests = users.map((_, index) => ({
      name: 'create_task',
      arguments: {title: 'Isolated backup task ' + index, request_id: 'backup-acceptance-' + index},
    }));
    const taskIDs = [];
    for (let index = 0; index < users.length; index++) {
      const created = await f.request('/v1/tools/call', requests[index],
        {token: users[index].access_token});
      assert.equal(created.status, 200);
      assert.equal(created.value.isError, false);
      taskIDs.push(JSON.parse(created.value.content[0].text).task.id);
    }
    const before = python(snapshotScript, [f.dbFile]);
    for (const table of ['accounts', 'entities', 'changes', 'receipts', 'tokens', 'audit']) {
      assert.ok(before.counts[table] >= 2, table + ' contains actual committed fixture rows');
    }
    assert.ok(statSync(f.dbFile + '-wal').size > 0,
      'Backup must include committed WAL while the source store remains open');

    const directory = path.join(f.folder, 'backups');
    const environment = Object.fromEntries(
      Object.entries(process.env).filter(([key]) => !key.startsWith('LORVEX_')));
    const backup = spawnSync('python3', [fileURLToPath(new URL('./backup.py', import.meta.url))], {
      env: {...environment, LORVEX_CLOUD_HOME: f.folder,
        LORVEX_CLOUD_DB: f.dbFile, LORVEX_CLOUD_BACKUP_DIR: directory},
      encoding: 'utf8', timeout: 15000, maxBuffer: 1024 * 1024,
    });
    assert.equal(backup.status, 0, backup.stderr || backup.error?.message);
    const files = readdirSync(directory).filter(name => name.endsWith('.sqlite.gz'));
    assert.equal(files.length, 1);
    const archive = path.join(directory, files[0]);
    assert.equal(statSync(archive).mode & 0o777, 0o600);
    assert.ok(statSync(archive).size < 1024 * 1024, 'Fixture archive stays bounded');
    const restoredFile = path.join(f.folder, 'restored.sqlite');
    const restore = python([
      'import gzip,json,pathlib,sys',
      'with gzip.open(sys.argv[1],"rb") as archive: data=archive.read(8*1024*1024+1)',
      'assert len(data)<=8*1024*1024',
      'pathlib.Path(sys.argv[2]).write_bytes(data)',
      'print(json.dumps({"sizeBytes":len(data)}))',
    ].join('\n'), [archive, restoredFile]);
    const restored = python(snapshotScript, [restoredFile]);
    assert.deepEqual(restored, before,
      'Restoration preserves every table row, schema and the logical database digest');

    const recovered = createCloudServer({dbFile: restoredFile, publicOrigin: issuer, clock: f.clock});
    await new Promise(resolve => recovered.server.listen(0, '127.0.0.1', resolve));
    const address = 'http://127.0.0.1:' + recovered.server.address().port + '/cloud';
    try {
      for (let index = 0; index < users.length; index++) {
        const headers = {Authorization: 'Bearer ' + users[index].access_token};
        const summary = await fetch(address + '/v1/dashboard',
          {headers, signal: AbortSignal.timeout(5000)});
        assert.equal(summary.status, 200, 'The preserved session authenticates after restore');
        assert.equal((await summary.json()).totalMatching, 1,
          'Each restored account sees only its own task');
        const replay = await fetch(address + '/v1/tools/call', {
          method: 'POST', headers: {...headers, 'Content-Type': 'application/json'},
          body: JSON.stringify(requests[index]), signal: AbortSignal.timeout(5000),
        });
        assert.equal(replay.status, 200);
        const result = await replay.json();
        assert.equal(JSON.parse(result.content[0].text).task.id, taskIDs[index],
          'Restored request receipts prevent a duplicate write');
      }
      assert.deepEqual(python(snapshotScript, [restoredFile]), before,
        'Authenticated reads and idempotent replay do not add or remove restored records');
    } finally {
      recovered.server.closeAllConnections();
      await recovered.close();
    }
    t.diagnostic(JSON.stringify({
      counts: before.counts, integrity: restored.integrity,
      logicalSHA256: restored.logicalSHA256,
      archiveSHA256: createHash('sha256').update(readFileSync(archive)).digest('hex'),
      archiveSizeBytes: statSync(archive).size, restoredSizeBytes: restore.sizeBytes,
      sourceConnectionOpenDuringBackup: true,
      restoredSessionsAndIdempotencyVerified: true,
    }));
  });
