<#
.SYNOPSIS
    Preflight for a tenant-to-tenant OneDrive migration.
    Resolves actual personal-site URLs from each tenant, grants you site-collection
    admin on every in-scope source AND target OneDrive, and validates that the URLs
    in users.csv are correct before you download/upload anything.

.NOTES
    Run this FIRST. Nothing else should run until this reports all-clear.
    Requires: PnP.PowerShell 2.12+ (PS 7.4+ for PnP 3.x), SharePoint Admin on both tenants.

    AUTH: PnP.PowerShell no longer ships a shared app registration. You must register
    an Entra app (delegated SharePoint > AllSites.FullControl) in EACH tenant, or one
    multi-tenant app consented in both, and pass the ClientId(s) below. Env-var
    fallback: PNPPOWERSHELL_CLIENTID (used for both sides if the params are omitted).

.EXAMPLE
    ./0-Preflight.ps1 -SourceClientId <source-app-guid> -TargetClientId <target-app-guid> `
                      -SourceAdminAcct admin@source-tenant.example
#>

param(
    [string]$UsersCsv        = "$PSScriptRoot/users.csv",
    [string]$SourceAdminUrl  = "https://SOURCETENANT-admin.sharepoint.com",
    [string]$TargetAdminUrl  = "https://TARGETTENANT-admin.sharepoint.com",
    [string]$AdminAccount    = "",                             # your admin ID on the TARGET side (required)
    [string]$SourceAdminAcct = "",                             # your admin ID on the SOURCE side (required)
    [string]$SourceClientId  = $env:PNPPOWERSHELL_CLIENTID,
    [string]$TargetClientId  = $env:PNPPOWERSHELL_CLIENTID
)

$ErrorActionPreference = "Stop"

# --- Fail fast on missing/placeholder inputs ---
if (-not $SourceClientId -or -not $TargetClientId) {
    throw "ClientId required. Register an Entra app per tenant (delegated AllSites.FullControl) and pass -SourceClientId/-TargetClientId, or set PNPPOWERSHELL_CLIENTID."
}
if (-not $AdminAccount) {
    throw "-AdminAccount is required: your SharePoint Admin identity in the TARGET tenant."
}
if ($SourceAdminUrl -like "*SOURCETENANT*" -or $TargetAdminUrl -like "*TARGETTENANT*") {
    throw "Set -SourceAdminUrl and -TargetAdminUrl to your real admin center URLs (https://<tenant>-admin.sharepoint.com)."
}
if (-not $SourceAdminAcct -or $SourceAdminAcct -like "you@*") {
    throw "-SourceAdminAcct is required: your SharePoint Admin identity in the SOURCE tenant."
}

$users = Import-Csv $UsersCsv | Where-Object { $_.Include -eq "Yes" }
Write-Host "`n=== Preflight: $($users.Count) in-scope users ===`n" -ForegroundColor Cyan

$mismatches = 0
$unresolved = 0

# ---------- SOURCE TENANT ----------
Write-Host "Connecting to SOURCE admin center ($SourceAdminUrl)..." -ForegroundColor Yellow
Connect-PnPOnline -Url $SourceAdminUrl -Interactive -ClientId $SourceClientId -ForceAuthentication

foreach ($u in $users) {
    Write-Host "`n--- $($u.DisplayName) [SOURCE] ---" -ForegroundColor Green

    # Resolve the real personal-site URL from the source UPN.
    # Guarded: $resolved can be $null (deleted user / no profile) and PersonalUrl can
    # be empty (site never provisioned). Either case must warn, not crash.
    $resolved = Get-PnPUserProfileProperty -Account $u.SourceUPN -ErrorAction SilentlyContinue
    $realSourceUrl = if ($resolved -and $resolved.PersonalUrl) { $resolved.PersonalUrl.TrimEnd('/') } else { $null }

    if ($realSourceUrl) {
        Write-Host "  Resolved source OneDrive: $realSourceUrl"
        if ($realSourceUrl -ne $u.SourceOneDriveUrl.TrimEnd('/')) {
            $mismatches++
            Write-Warning "  CSV MISMATCH. CSV has: $($u.SourceOneDriveUrl)"
            Write-Warning "  --> Update users.csv SourceOneDriveUrl to: $realSourceUrl"
        }
        # Grant your source-side admin identity site-collection admin on the source OneDrive
        try {
            Set-PnPTenantSite -Url $realSourceUrl -Owners $SourceAdminAcct
            Write-Host "  Granted $SourceAdminAcct admin on source OneDrive." -ForegroundColor DarkGray
        } catch {
            Write-Warning "  Could not set owner: $($_.Exception.Message)"
        }
    } else {
        $unresolved++
        Write-Warning "  Could NOT resolve source OneDrive for $($u.SourceUPN). Site may be deleted or user unlicensed."
    }
}

# ---------- TARGET TENANT ----------
Write-Host "`nConnecting to TARGET admin center ($TargetAdminUrl)..." -ForegroundColor Yellow
# -ForceAuthentication: do not silently reuse the cached source-tenant token when switching tenants.
Connect-PnPOnline -Url $TargetAdminUrl -Interactive -ClientId $TargetClientId -ForceAuthentication

foreach ($u in $users) {
    Write-Host "`n--- $($u.DisplayName) [TARGET] ---" -ForegroundColor Green

    $resolved = Get-PnPUserProfileProperty -Account $u.TargetUPN -ErrorAction SilentlyContinue
    $realTargetUrl = if ($resolved -and $resolved.PersonalUrl) { $resolved.PersonalUrl.TrimEnd('/') } else { $null }

    if ($realTargetUrl) {
        Write-Host "  Resolved target OneDrive: $realTargetUrl"
        if ($realTargetUrl -ne $u.TargetOneDriveUrl.TrimEnd('/')) {
            $mismatches++
            Write-Warning "  CSV MISMATCH. CSV has: $($u.TargetOneDriveUrl)"
            Write-Warning "  --> Update users.csv TargetOneDriveUrl to: $realTargetUrl"
        }
        try {
            Set-PnPTenantSite -Url $realTargetUrl -Owners $AdminAccount
            Write-Host "  Granted $AdminAccount admin on target OneDrive." -ForegroundColor DarkGray
        } catch {
            Write-Warning "  Could not set owner: $($_.Exception.Message)"
        }
    } else {
        $unresolved++
        Write-Warning "  Could NOT resolve target OneDrive for $($u.TargetUPN)."
        Write-Warning "  The user may need to log into OneDrive once to provision it, OR run:"
        Write-Warning "    Request-PnPPersonalSite -UserEmails '$($u.TargetUPN)'"
    }
}

Write-Host ""
if ($mismatches -eq 0 -and $unresolved -eq 0) {
    Write-Host "=== Preflight ALL CLEAR. $($users.Count) users verified on both sides. ===" -ForegroundColor Green
} else {
    Write-Host "=== Preflight finished with $mismatches CSV mismatch(es) and $unresolved unresolved site(s). Fix before proceeding. ===" -ForegroundColor Yellow
}
