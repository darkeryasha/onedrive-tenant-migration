<#
.SYNOPSIS
    Downloads current-version files from each in-scope SOURCE OneDrive to local disk,
    preserving folder structure, and writes a per-file manifest CSV.

.NOTES
    Run 0-Preflight.ps1 first. Only pulls the latest version of each file (no history).
    Authenticate with your SOURCE-tenant (source) admin identity when prompted.
#>

param(
    [string]$UsersCsv  = "$PSScriptRoot/users.csv",
    [string]$LocalRoot = "$HOME/OneDriveMigration",
    [string]$LogDir    = "$PSScriptRoot/logs",
    # Optional: process only one user by DisplayName or TargetUPN
    [string]$OnlyUser  = "",
    # Entra app registration in the SOURCE (source) tenant with delegated AllSites.FullControl
    [string]$ClientId  = $env:PNPPOWERSHELL_CLIENTID
)

$ErrorActionPreference = "Stop"
if (-not $ClientId) {
    throw "ClientId required. Pass -ClientId <source-tenant-app-guid> or set PNPPOWERSHELL_CLIENTID."
}

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$users = @(Import-Csv $UsersCsv | Where-Object { $_.Include -eq "Yes" })
if ($OnlyUser) {
    $users = @($users | Where-Object { $_.DisplayName -eq $OnlyUser -or $_.TargetUPN -eq $OnlyUser })
    if ($users.Count -eq 0) { throw "No Include=Yes user in $UsersCsv matches '$OnlyUser'." }
}

$manifestPath = Join-Path $LogDir ("download-manifest_{0}.csv" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$manifest = [System.Collections.Generic.List[object]]::new()

$firstConnect = $true
foreach ($u in $users) {
    Write-Host "`n========== DOWNLOAD: $($u.DisplayName) ==========" -ForegroundColor Cyan
    $localUserRoot = Join-Path $LocalRoot $u.LocalFolder
    New-Item -ItemType Directory -Path $localUserRoot -Force | Out-Null

    # -ForceAuthentication on the first connect only: guarantees you pick the source-tenant
    # admin identity instead of silently reusing a cached token from another tenant.
    # Subsequent connects within the same (source) tenant reuse that token.
    if ($firstConnect) {
        Connect-PnPOnline -Url $u.SourceOneDriveUrl -Interactive -ClientId $ClientId -ForceAuthentication
        $firstConnect = $false
    } else {
        Connect-PnPOnline -Url $u.SourceOneDriveUrl -Interactive -ClientId $ClientId
    }

    # Enumerate all files in the Documents library
    $list = Get-PnPList -Identity "Documents"
    $items = Get-PnPListItem -List $list -PageSize 500 | Where-Object {
        $_.FileSystemObjectType -eq "File"
    }
    Write-Host "  $($items.Count) files found." -ForegroundColor Yellow

    # Total bytes for this user so the progress bar can report MB done / MB total
    $totalBytes = ($items | ForEach-Object { [int64]$_.FieldValues.File_x0020_Size } | Measure-Object -Sum).Sum
    $doneBytes  = [int64]0

    $i = 0
    foreach ($item in $items) {
        $i++
        $serverRelativeUrl = $item.FieldValues.FileRef
        $sizeBytes         = [int64]($item.FieldValues.File_x0020_Size)
        # Capture source system fields for later restoration on the target.
        # SharePoint stores these in UTC; format round-trip so re-parse is unambiguous.
        $srcCreated  = $null; $srcModified = $null
        if ($item.FieldValues.Created)  { $srcCreated  = ([datetime]$item.FieldValues.Created).ToUniversalTime().ToString("o") }
        if ($item.FieldValues.Modified) { $srcModified = ([datetime]$item.FieldValues.Modified).ToUniversalTime().ToString("o") }
        # Author/Editor come back as FieldUserValue objects; grab the email
        $srcAuthor = $null; $srcEditor = $null
        if ($item.FieldValues.Author) { $srcAuthor = ($item.FieldValues.Author.Email) }
        if ($item.FieldValues.Editor) { $srcEditor = ($item.FieldValues.Editor.Email) }
        # Strip the /personal/<slug>/Documents/ prefix to keep relative structure
        $relativePath = $serverRelativeUrl -replace "^/personal/[^/]+/Documents/", ""
        $localFile    = Join-Path $localUserRoot $relativePath
        $localDir     = Split-Path $localFile -Parent

        Write-Progress -Activity "Downloading: $($u.DisplayName)" `
            -Status ("{0}/{1} files | {2:N1} / {3:N1} MB" -f $i, $items.Count, ($doneBytes / 1MB), ($totalBytes / 1MB)) `
            -CurrentOperation $relativePath `
            -PercentComplete ([math]::Min(100, [int](($i - 1) * 100 / [math]::Max(1, $items.Count))))

        $status = "OK"; $err = ""
        try {
            if (-not (Test-Path $localDir)) {
                New-Item -ItemType Directory -Path $localDir -Force | Out-Null
            }
            Get-PnPFile -Url $serverRelativeUrl -Path $localDir `
                -FileName (Split-Path $localFile -Leaf) -AsFile -Force

            # Integrity check: the file on disk must match the size SharePoint reported.
            # Catches truncated/partial downloads that would otherwise upload silently.
            $onDisk = Get-Item -LiteralPath $localFile -ErrorAction Stop
            if ($onDisk.Length -ne $sizeBytes) {
                $status = "FAIL"
                $err = "Size mismatch after download: expected $sizeBytes, got $($onDisk.Length)"
                Write-Warning "  [$i/$($items.Count)] FAIL: $relativePath -- $err"
            }
        } catch {
            $status = "FAIL"; $err = $_.Exception.Message
            Write-Warning "  [$i/$($items.Count)] FAIL: $relativePath -- $err"
        }

        if ($status -eq "OK") { $doneBytes += $sizeBytes }

        $manifest.Add([pscustomobject]@{
            Timestamp        = (Get-Date -Format "o")
            User             = $u.DisplayName
            Phase            = "Download"
            RelativePath     = $relativePath
            SourceServerUrl  = $serverRelativeUrl
            SizeBytes        = $sizeBytes
            LocalPath        = $localFile
            PathLength       = $serverRelativeUrl.Length
            SrcCreatedUtc    = $srcCreated
            SrcModifiedUtc   = $srcModified
            SrcAuthor        = $srcAuthor
            SrcEditor        = $srcEditor
            Status           = $status
            Error            = $err
        })

    }

    Write-Progress -Activity "Downloading: $($u.DisplayName)" -Completed

    $ok   = ($manifest | Where-Object { $_.User -eq $u.DisplayName -and $_.Status -eq "OK" }).Count
    $fail = ($manifest | Where-Object { $_.User -eq $u.DisplayName -and $_.Status -eq "FAIL" }).Count
    Write-Host "  Done: $ok OK, $fail FAIL" -ForegroundColor Green
}

$manifest | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8
Write-Host "`nManifest written: $manifestPath" -ForegroundColor Cyan

# Summary
$manifest | Group-Object User | ForEach-Object {
    $g = $_.Group
    [pscustomobject]@{
        User      = $_.Name
        Files     = $g.Count
        OK        = ($g | Where-Object Status -eq "OK").Count
        Failed    = ($g | Where-Object Status -eq "FAIL").Count
        TotalMB   = [math]::Round(($g | Measure-Object SizeBytes -Sum).Sum / 1MB, 1)
        LongPaths = ($g | Where-Object { $_.PathLength -gt 380 }).Count
    }
} | Format-Table -AutoSize
