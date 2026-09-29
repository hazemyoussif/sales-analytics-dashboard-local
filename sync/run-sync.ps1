# Runs the nightly Odoo -> Supabase sync, with a log a human can read the
# morning after.
#
# WHY A LOG FILE AT ALL. The pipeline this replaced failed silently: n8n's
# backfill could not complete, nobody was told, and 29,284 phantom invoice
# lines accumulated until someone reconciled the totals by hand. A scheduled
# job that cannot be seen failing is the same trap. Every run appends here
# whether it succeeds or not, and the last line always states the exit code.
#
# Triggered by the Windows scheduled task "Dabboos Odoo Sync" (daily 03:00).
# Safe to run by hand at any time -- every job is an upsert.

$syncDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $syncDir

$logDir = Join-Path $syncDir 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$log = Join-Path $logDir ('sync-' + (Get-Date -Format 'yyyy-MM-dd') + '.log')

$py = 'C:\Users\ENG. AHMED GOMMA\AppData\Local\Programs\Python\Python310\python.exe'
if (-not (Test-Path $py)) { $py = 'python' }

Add-Content $log ''
Add-Content $log ('=' * 72)
Add-Content $log ("RUN STARTED   " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Add-Content $log ('=' * 72)

# Redirection is delegated to cmd rather than PowerShell's own 2>&1. In
# Windows PowerShell 5.1, redirecting a NATIVE executable's stderr wraps each
# line in an ErrorRecord and reports failure even when the exit code is 0 --
# which would make every healthy run look broken in this log.
& cmd /c "`"$py`" -m odoosync all >> `"$log`" 2>&1"
$rc = $LASTEXITCODE

Add-Content $log ("RUN FINISHED  " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "   exit=$rc")
if ($rc -ne 0) { Add-Content $log "*** THIS RUN FAILED -- the dashboard is now showing older numbers ***" }

# Thirty days is enough to answer "when did this start going wrong" and not
# enough to quietly fill a disk.
Get-ChildItem $logDir -Filter 'sync-*.log' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

exit $rc
