<#
.SYNOPSIS
    Reconciles a download manifest against an upload manifest. Flags any file that
    was downloaded but not successfully uploaded, and any per-file size mismatches.
    Writes a reconciliation report CSV.

.NOTES
    Defaults to the newest manifest of each type in the log directory. If you ran
    per-user passes that produced multiple manifest pairs, either reconcile after
    each pair or pass -DownloadManifest/-UploadManifest explicitly — the newest-file
    default only covers the most recent run.
#>

param(
    [string]$LogDir = "$PSScriptRoot/logs",
    # Explicit manifest paths (override the newest-in-LogDir default)
    [string]$DownloadManifest = "",
    [string]$UploadManifest   = ""
)

$ErrorActionPreference = "Stop"

if (-not $DownloadManifest) {
    $dl = Get-ChildItem $LogDir -Filter "download-manifest_*.csv" -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $dl) { throw "No download manifest found in $LogDir" }
    $DownloadManifest = $dl.FullName
}
if (-not $UploadManifest) {
    $ul = Get-ChildItem $LogDir -Filter "upload-manifest_*.csv" -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $ul) { throw "No upload manifest found in $LogDir" }
    $UploadManifest = $ul.FullName
}

Write-Host "Download manifest: $(Split-Path $DownloadManifest -Leaf)"
Write-Host "Upload manifest:   $(Split-Path $UploadManifest -Leaf)`n"

# @() guards: with a single-row manifest, .User member enumeration returns a scalar
# string and '+' would concatenate strings instead of joining arrays.
$down = @(Import-Csv $DownloadManifest)
$up   = @(Import-Csv $UploadManifest)

# Lookup of successfully uploaded files: User|RelativePath -> upload row
$upOk = @{}
foreach ($row in ($up | Where-Object Status -eq "OK")) {
    $upOk["$($row.User)|$($row.RelativePath)"] = $row
}

$report = [System.Collections.Generic.List[object]]::new()
foreach ($row in ($down | Where-Object Status -eq "OK")) {
    $key = "$($row.User)|$($row.RelativePath)"
    if (-not $upOk.ContainsKey($key)) {
        $report.Add([pscustomobject]@{
            User          = $row.User
            RelativePath  = $row.RelativePath
            DownSizeBytes = $row.SizeBytes
            UpSizeBytes   = ""
            Issue         = "Downloaded but NOT uploaded"
        })
    } elseif ([int64]$upOk[$key].SizeBytes -ne [int64]$row.SizeBytes) {
        # Size mismatch between what SharePoint reported at download and what was
        # uploaded — catches truncated transfers that both phases marked OK.
        $report.Add([pscustomobject]@{
            User          = $row.User
            RelativePath  = $row.RelativePath
            DownSizeBytes = $row.SizeBytes
            UpSizeBytes   = $upOk[$key].SizeBytes
            Issue         = "Size mismatch between download and upload"
        })
    }
}

# Per-user summary
Write-Host "=== Per-user reconciliation ===`n" -ForegroundColor Cyan
$users = @($down.User) + @($up.User) | Sort-Object -Unique
$summary = foreach ($usr in $users) {
    $dOk = @($down | Where-Object { $_.User -eq $usr -and $_.Status -eq "OK" })
    $uOk = @($up   | Where-Object { $_.User -eq $usr -and $_.Status -eq "OK" })
    $dFail = @($down | Where-Object { $_.User -eq $usr -and $_.Status -eq "FAIL" }).Count
    $uFail = @($up   | Where-Object { $_.User -eq $usr -and $_.Status -eq "FAIL" }).Count
    # MetaStatus only exists if the upload ran with -RestoreMetadata
    $metaRestored = @($uOk | Where-Object { $_.PSObject.Properties.Name -contains "MetaStatus" -and $_.MetaStatus -like "restored:*" }).Count
    [pscustomobject]@{
        User            = $usr
        Downloaded_OK   = $dOk.Count
        Uploaded_OK     = $uOk.Count
        Download_Fail   = $dFail
        Upload_Fail     = $uFail
        Discrepancies   = @($report | Where-Object User -eq $usr).Count
        MetaRestored    = $metaRestored
        DownMB          = [math]::Round(($dOk | Measure-Object SizeBytes -Sum).Sum / 1MB, 1)
        UpMB            = [math]::Round(($uOk | Measure-Object SizeBytes -Sum).Sum / 1MB, 1)
    }
}
$summary | Format-Table -AutoSize

$reportPath = Join-Path $LogDir ("reconcile_{0}.csv" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
if ($report.Count -gt 0) {
    $report | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8
    Write-Host "`n$($report.Count) discrepancies written to: $reportPath" -ForegroundColor Yellow
} else {
    Write-Host "`nNo discrepancies. Every downloaded file was uploaded successfully with matching sizes." -ForegroundColor Green
}
