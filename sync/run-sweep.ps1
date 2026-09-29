# The monthly drift sweep -- the local twin of .github/workflows/sync-monthly.yml.
#
# WHY THIS EXISTS SEPARATELY FROM THE NIGHTLY RUN. An upsert can never DELETE.
# When an invoice is cancelled it does not change in account.invoice.report, it
# DISAPPEARS from it, so its rows survive every subsequent sync forever and keep
# inflating revenue. Measured on this database before the first reconciliation:
# 150,093 rows where Odoo had 120,809. Twenty-nine thousand phantom lines, with
# nothing in the pipeline able to remove them.
#
# `backfill --replace` deletes each month before inserting it, which is the only
# operation that removes a row that no longer exists upstream. The daily run
# already does this for the last 35 days. This reaches past that.
#
# Triggered by the scheduled task "Dabboos Odoo Sweep" (1st of the month, 13:00).

param([int]$Months = 3)

$syncDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $syncDir

$logDir = Join-Path $syncDir 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$log = Join-Path $logDir ('sweep-' + (Get-Date -Format 'yyyy-MM-dd') + '.log')

$py = 'C:\Users\ENG. AHMED GOMMA\AppData\Local\Programs\Python\Python310\python.exe'
if (-not (Test-Path $py)) { $py = 'python' }

# From the 1st of the month $Months back, through tomorrow. --to is exclusive,
# so tomorrow means "including everything dated today".
$from = (Get-Date -Day 1).Date.AddMonths(-$Months).ToString('yyyy-MM-dd')
$to   = (Get-Date).Date.AddDays(1).ToString('yyyy-MM-dd')

Add-Content $log ''
Add-Content $log ('=' * 72)
Add-Content $log ("SWEEP STARTED " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "   window $from .. $to")
Add-Content $log ('=' * 72)

& cmd /c "`"$py`" -m odoosync backfill --replace --from $from --to $to >> `"$log`" 2>&1"
$rc = $LASTEXITCODE

if ($rc -eq 0) {
    # branch-sales and branch-revenue used to run here. They were removed from
    # the CLI when the dashboard narrowed to Overview and Customers 80/20 and
    # their tables were dropped, but this script kept calling them -- argparse
    # rejects an unknown choice, so each run wrote two "invalid choice" errors
    # into the log and carried on. Nothing broke, which is why it went
    # unnoticed; the exit code came from the refresh below either way.

    # --since is the whole point. Plain `refresh` calls refresh_after_sync(),
    # which rebuilds a FIXED two months. A three-month replace would correct the
    # invoice lines and leave the oldest month's summary holding the old numbers
    # -- and every page reads the summaries, so the correction would never reach
    # a screen. Passing the backfill's own start date rebuilds what was replaced.
    & cmd /c "`"$py`" -m odoosync refresh --since $from >> `"$log`" 2>&1"
    $rc = $LASTEXITCODE
} else {
    Add-Content $log "*** backfill failed -- skipping the branch sweep and the refresh ***"
}

Add-Content $log ("SWEEP FINISHED " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "   exit=$rc")
if ($rc -ne 0) { Add-Content $log "*** THIS SWEEP FAILED -- cancelled invoices may still be inflating revenue ***" }
exit $rc
