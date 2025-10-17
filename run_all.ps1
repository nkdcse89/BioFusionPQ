# run_all.ps1 — End-to-end runner for BioFusionPQ on Windows 11 + Python 3.11
# Usage: powershell -ExecutionPolicy Bypass -File .\run_all.ps1
param(
  [int]$Wallets = 200,
  [int]$TxEach = 100,
  [string]$Host = "127.0.0.1",
  [int]$Port = 9000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$baseUrl = "http://$Host`:$Port"

# --- Repo paths ---
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $RepoRoot
$VenvPy = ".\.venv\Scripts\python.exe"

# --- 0) Venv + deps ---
if (!(Test-Path $VenvPy)) { py -3.11 -m venv .venv }
& $VenvPy -m pip install --upgrade pip

if (!(Test-Path .\requirements.txt)) {
@'
streamlit
fastapi
uvicorn[standard]
pydantic>=2
numpy
pandas
matplotlib
requests
psutil
PyNaCl
cryptography
'@ | Set-Content -Encoding UTF8 .\requirements.txt
}
& $VenvPy -m pip install -r .\requirements.txt

# --- 1) Folders + sample data ---
mkdir data, artifacts, figures, scripts -Force | Out-Null
mkdir data\modalities -Force | Out-Null

# index.csv + dummy modality files
'path,user_id' | Set-Content -Encoding ASCII .\data\index.csv
$rand = [System.Random]::new()
for ($i=1; $i -le $Wallets; $i++) {
  $uid = ('user{0:d3}' -f $i)
  $p = ".\data\modalities\$uid.bin"
  $bytes = New-Object Byte[] 1024; $rand.NextBytes($bytes)
  [System.IO.File]::WriteAllBytes($p, $bytes)
  Add-Content -Encoding ASCII .\data\index.csv ("data/modalities/{0}.bin,{0}" -f $uid)
}

# --- 2) Ensure helper scripts exist (register/burst/stats) ---
# register_wallets.py
if (!(Test-Path .\scripts\register_wallets.py)) {
@'
import argparse, csv, sys
from pathlib import Path
import requests

def find_pubkey_column(fieldnames):
    if not fieldnames: return None
    lower = [h.lower() for h in fieldnames]
    for c in ["pubkey","public_key","pub_key","pk"]:
        if c in lower: return fieldnames[lower.index(c)]
    return None

def main():
    ap = argparse.ArgumentParser(description="Register wallets from summary.csv")
    ap.add_argument("--csv", required=True)
    ap.add_argument("--url", default="http://127.0.0.1:9000/register")
    ap.add_argument("--timeout", type=float, default=10.0)
    args = ap.parse_args()

    path = Path(args.csv)
    if not path.exists():
        print(f"ERROR: {path} not found", file=sys.stderr); sys.exit(1)

    ok = fail = 0
    with path.open("r", newline="", encoding="utf-8") as f:
        rdr = csv.DictReader(f)
        col = find_pubkey_column(rdr.fieldnames)
        if not col:
            print("ERROR: need pubkey/public_key column", file=sys.stderr); sys.exit(2)
        for i,row in enumerate(rdr,1):
            pk = (row.get(col) or "").strip()
            if not pk: fail+=1; continue
            try:
                r = requests.post(args.url, json={"pubkey": pk}, timeout=args.timeout)
                if r.ok: ok+=1
                else: fail+=1
            except requests.RequestException:
                fail+=1
    print(f"Registered: {ok} succeeded, {fail} failed")

if __name__ == "__main__":
    main()
'@ | Set-Content -Encoding UTF8 .\scripts\register_wallets.py
}

# burst_tx.py
if (!(Test-Path .\scripts\burst_tx.py)) {
@'
import argparse, csv, random, requests, time, sys
ap = argparse.ArgumentParser()
ap.add_argument("--csv", required=True)
ap.add_argument("--node", default="http://127.0.0.1:9000")
ap.add_argument("--count", type=int, default=100)
ap.add_argument("--endpoint", default="/tx")
args = ap.parse_args()

def pick_pk_col(fns):
    L = [x.lower() for x in (fns or [])]
    for k in ("pubkey","public_key","pub_key","pk"):
        if k in L: return (fns or [])[L.index(k)]
    return None

rows = list(csv.DictReader(open(args.csv, newline="", encoding="utf-8")))
col = pick_pk_col(rows[0].keys() if rows else [])
if not col: print("no pubkey column", file=sys.stderr) or sys.exit(2)
pubs = [r[col].strip() for r in rows if r.get(col)]
if len(pubs) < 2: print("need ≥2 pubs", file=sys.stderr) or sys.exit(3)

s = requests.Session()
ok = fail = 0; lat = []
for i in range(args.count):
    a,b = random.sample(pubs, 2)
    payload = {
        "from_pubkey": a,
        "to_pubkey": b,
        "amount": 1,
        "memo": f"tx-{i}",
        "sig_legacy": "00",
        "sig_pq": "00"
    }
    t0 = time.perf_counter()
    try:
        r = s.post(args.node.rstrip("/") + args.endpoint, json=payload, timeout=5)
        dt = time.perf_counter() - t0
        lat.append(dt)
        if r.ok: ok += 1
        else: fail += 1
    except Exception:
        fail += 1
print(f"sent={ok} failed={fail} avg_req_ms={(sum(lat)/len(lat)*1000 if lat else 0):.2f}")
'@ | Set-Content -Encoding UTF8 .\scripts\burst_tx.py
}

# chain_stats.py
if (!(Test-Path .\scripts\chain_stats.py)) {
@'
import json, requests
NODE = "http://127.0.0.1:9000"
data = requests.get(f"{NODE}/chain", timeout=10).json()
blocks = data.get("blocks") or data.get("chain") or []
sizes = []; verify_ms = []
for b in blocks:
    size = b.get("size_bytes")
    if size is None:
        try: size = len(json.dumps(b).encode("utf-8"))
        except Exception: size = 0
    sizes.append(size)
    for tx in (b.get("txs") or b.get("transactions") or []):
        vm = tx.get("verify_time_ms") or tx.get("verification_ms") or tx.get("verify_ms")
        if vm is None and tx.get("verify_time_ns") is not None:
            vm = float(tx["verify_time_ns"]) / 1e6
        if vm is not None: verify_ms.append(float(vm))
avg_block_size = (sum(sizes)/len(sizes)) if sizes else 0.0
avg_verify = (sum(verify_ms)/len(verify_ms)) if verify_ms else 0.0
print(json.dumps({
    "blocks": len(blocks),
    "avg_block_size_bytes": round(avg_block_size, 2),
    "avg_tx_verify_ms": round(avg_verify, 3),
}, indent=2))
'@ | Set-Content -Encoding UTF8 .\scripts\chain_stats.py
}

# --- 3) Start node ---
$nodeArgs = @("-m","uvicorn","src.protochain:app","--host",$Host,"--port",$Port.ToString())
$nodeProc = Start-Process -FilePath $VenvPy -ArgumentList $nodeArgs -PassThru
Write-Host "Started node PID=$($nodeProc.Id) on $baseUrl"

# Wait for readiness
$ready = $false
for ($t=0; $t -lt 60; $t++) {
  try {
    Invoke-RestMethod -Uri "$baseUrl/docs" -TimeoutSec 1 | Out-Null
    $ready = $true; break
  } catch { Start-Sleep -Milliseconds 500 }
}
if (-not $ready) { Stop-Process -Id $nodeProc.Id -Force; throw "Node failed to start at $baseUrl" }

# --- 4) Generate wallets (bulk_wallets.py) ---
& $VenvPy .\src\bulk_wallets.py --in .\data\index.csv --out .\artifacts\summary.csv --format csv

# --- 5) Register wallets ---
& $VenvPy .\scripts\register_wallets.py --csv .\artifacts\summary.csv --url "$baseUrl/register"

# --- 6) Legacy tx burst ---
try { Invoke-RestMethod -Method Post -Uri "$baseUrl/policy" -ContentType 'application/json' -Body '{"policy":"legacy"}' | Out-Null } catch {}
& $VenvPy .\scripts\burst_tx.py --csv .\artifacts\summary.csv --node $baseUrl --count $TxEach --endpoint /tx

# --- 7) Hybrid tx burst ---
try { Invoke-RestMethod -Method Post -Uri "$baseUrl/policy" -ContentType 'application/json' -Body '{"policy":"hybrid"}' | Out-Null } catch {}
& $VenvPy .\scripts\burst_tx.py --csv .\artifacts\summary.csv --node $baseUrl --count $TxEach --endpoint /tx

# --- 8) Mine ---
try { Invoke-RestMethod -Method Post -Uri "$baseUrl/mine" -ContentType 'application/json' -Body '{"max_blocks":1}' | Out-Null } catch {}

# --- 9) Stats ---
& $VenvPy .\scripts\chain_stats.py

# --- 10) Stop node ---
try { Stop-Process -Id $nodeProc.Id -Force } catch {}
Write-Host "Done."
