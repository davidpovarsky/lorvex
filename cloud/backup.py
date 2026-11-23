#!/usr/bin/env python3
"""Online-safe daily SQLite backup; never copy live WAL files as a raw file."""
import gzip
import os
from pathlib import Path
import sqlite3
import tempfile
import time

root=Path(os.getenv("LORVEX_CLOUD_HOME","/home/ubuntu/lorvex-cloud"))
src=Path(os.getenv("LORVEX_CLOUD_DB",str(root/"data"/"lorvex.sqlite")))
target=Path(os.getenv("LORVEX_CLOUD_BACKUP_DIR",str(root/"backups")))
if not src.is_file():
    raise SystemExit("No Lorvex Cloud database exists")
target.mkdir(mode=0o700,parents=True,exist_ok=True)
label=time.strftime("%Y%m%dT%H%M%SZ",time.gmtime())
output=target/("lorvex-cloud-"+label+".sqlite.gz")
with tempfile.TemporaryDirectory(dir=target,prefix=".backup-") as tmp:
    snapshot=Path(tmp)/"database.sqlite"
    source=sqlite3.connect(f"file:{src}?mode=ro",uri=True)
    destination=sqlite3.connect(snapshot)
    try:
        source.backup(destination,pages=100,sleep=0.01)
        result=destination.execute("PRAGMA integrity_check").fetchone()[0]
        if result!="ok":
            raise RuntimeError("SQLite integrity check failed")
    finally:
        destination.close()
        source.close()
    compressed=Path(tmp)/output.name
    with snapshot.open("rb") as inp,gzip.open(compressed,"wb",compresslevel=5) as gz:
        for block in iter(lambda:inp.read(1024*1024),b""):
            gz.write(block)
    compressed.chmod(0o600)
    with compressed.open("rb") as verified:
        os.fsync(verified.fileno())
    os.replace(compressed,output)
all_files=sorted(target.glob("lorvex-cloud-*.sqlite.gz"),reverse=True)
for old in all_files[7:]:
    old.unlink()
print("Lorvex SQLite online backup created and verified:",output.name,
      "retained",len(list(target.glob("lorvex-cloud-*.sqlite.gz"))))
