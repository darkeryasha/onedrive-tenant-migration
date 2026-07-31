<#
.SYNOPSIS
    Uploads locally-downloaded files to each in-scope TARGET OneDrive, preserving
    folder structure, and writes a per-file upload manifest CSV.

.NOTES
    Run 1-Download.ps1 first. Folders are created automatically by Add-PnPFile.
    Authenticate with your TARGET-tenant (target) admin identity when prompted.
    Content lands under Documents/<TargetSubfolder> (default "Migrated") so it never
    collides with files the users have already created in their live OneDrive.
    Only files recorded as Status=OK in the download manifest are uploaded — partial
    or failed downloads on disk are skipped and flagged.
#>

param(
    [string]$UsersCsv  = "$PSScriptRoot/users.csv",
    [string]$LocalRoot = "$HOME/OneDriveMigration",
    [string]$LogDir    = "$PSScriptRoot/logs",
    [string]$OnlyUser  = "",
    # Restore source Created/Modified (and Author/Editor where possible) onto target files.
    [switch]$RestoreMetadata,
    # Path to the download manifest. Defaults to newest in LogDir. Used both for
    # metadata restore and to validate that each local file was a clean download.
    [string]$DownloadManifest = "",
    # Optional source-email -> target-email map for Author/Editor. If a source author has
    # no entry and no matching target user, the field is left as-is (you, the uploader).
    [string]$UsersCsvForAuthorMap = "$PSScriptRoot/users.csv",
    # Entra app registration in the TARGET (target) tenant with delegated AllSites.FullControl
    [string]$ClientId = $env:PNPPOWERSHELL_CLIENTID,
    # Metadata verification sampling: always verify the first 3 files per user, then
    # every Nth file after that. 1 = verify every file (slowest, maximum assurance),
    # 0 = no verification at all (fastest; unverified files get MetaStatus
    # "restored-unverified"). Default 25 keeps a canary without the per-file cost.
    [int]$VerifyEvery = 25,
    # Subfolder under Documents that receives ALL migrated content. Keeps the migration
    # isolated from files the users have already created in their live OneDrive, so no
    # name collisions/overwrites are possible. Set to "" to upload into the root (not
    # recommended: Add-PnPFile overwrites same-named files without warning).
    [string]$TargetSubfolder = "Migrated"
)

$ErrorActionPreference = "Stop"
if (-not $ClientId) {
    throw "ClientId required. Pass -ClientId <target-tenant-app-guid> or set PNPPOWERSHELL_CLIENTID."
}

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$users = @(Import-Csv $UsersCsv | Where-Object { $_.Include -eq "Yes" })
if ($OnlyUser) {
    $users = @($users | Where-Object { $_.DisplayName -eq $OnlyUser -or $_.TargetUPN -eq $OnlyUser })
    if ($users.Count -eq 0) { throw "No Include=Yes user in $UsersCsv matches '$OnlyUser'." }
}

$manifestPath = Join-Path $LogDir ("upload-manifest_{0}.csv" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$manifest = [System.Collections.Generic.List[object]]::new()

# --- Load the download manifest (always, not just for -RestoreMetadata) ---
# Used to (a) verify each local file was a clean, complete download and
# (b) supply source timestamps/authors when -RestoreMetadata is on.
if (-not $DownloadManifest) {
    $dl = Get-ChildItem $LogDir -Filter "download-manifest_*.csv" -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime | Select-Object -Last 1
    if (-not $dl) { throw "No download-manifest_*.csv found in $LogDir. Run 1-Download.ps1 first, or pass -DownloadManifest." }
    $DownloadManifest = $dl.FullName
}
Write-Host "Using download manifest: $DownloadManifest" -ForegroundColor Yellow

# Key = "<User>|<RelativePath>"  Value = the download-manifest row
$srcMeta = @{}
foreach ($row in (Import-Csv $DownloadManifest)) {
    $srcMeta["$($row.User)|$($row.RelativePath)"] = $row
}

if ($RestoreMetadata) {
    # Source-email -> target-email map (for Author/Editor). Built from users.csv so the
    # migrated users get attributed correctly; extend this hashtable as needed.
    $authorMap = @{}
    if (Test-Path $UsersCsvForAuthorMap) {
        foreach ($m in (Import-Csv $UsersCsvForAuthorMap)) {
            if ($m.SourceUPN -and $m.TargetUPN) { $authorMap[$m.SourceUPN.ToLower()] = $m.TargetUPN }
        }
    }
    # Cache of resolved target user IDs so we don't re-resolve for every file.
    # $null cached values mean "tried and failed" — skip without retrying.
    $userCache = @{}
}

$firstConnect = $true
foreach ($u in $users) {
    Write-Host "`n========== UPLOAD: $($u.DisplayName) ==========" -ForegroundColor Cyan
    $localUserRoot = Join-Path $LocalRoot $u.LocalFolder
    if (-not (Test-Path $localUserRoot)) {
        Write-Warning "  No local folder for $($u.DisplayName) at $localUserRoot. Skipping."
        continue
    }

    # -ForceAuthentication on the first connect: you are switching identities from the
    # source-tenant admin (download) to the target-tenant admin. Do not reuse the cached token.
    if ($firstConnect) {
        Connect-PnPOnline -Url $u.TargetOneDriveUrl -Interactive -ClientId $ClientId -ForceAuthentication
        $firstConnect = $false
    } else {
        Connect-PnPOnline -Url $u.TargetOneDriveUrl -Interactive -ClientId $ClientId
    }

    # Current connection user (you, the admin) — used as the Author/Editor fallback.
    # SharePoint's SystemUpdate validates the user fields whenever Created/Modified are
    # written; leaving them unsupplied when the source had no resolvable author causes
    # "The specified user  could not be found" on every file.
    $currentUser = $null
    if ($RestoreMetadata) {
        $currentUser = Get-PnPProperty -ClientObject (Get-PnPWeb) -Property CurrentUser
    }

    $files = Get-ChildItem -Path $localUserRoot -Recurse -File
    Write-Host "  $($files.Count) files to upload." -ForegroundColor Yellow

    $totalBytes = ($files | Measure-Object Length -Sum).Sum
    $doneBytes  = [int64]0

    $i = 0
    foreach ($file in $files) {
        $i++
        $relativePath = $file.FullName.Substring($localUserRoot.Length).TrimStart('/','\')
        # Normalize to forward slashes so manifest keys match the download manifest
        # regardless of platform.
        $relativePath = $relativePath -replace '\\','/'
        $relativeDir  = Split-Path $relativePath -Parent
        # All migrated content lands under Documents/<TargetSubfolder>/ to avoid
        # colliding with files the user has already created in the live OneDrive.
        $targetBase = "Documents"
        if ($TargetSubfolder) { $targetBase = "Documents/" + $TargetSubfolder.Trim('/') }
        $targetFolder = $targetBase
        if ($relativeDir) {
            $targetFolder = $targetBase + "/" + ($relativeDir -replace '\\','/')
        }

        $key  = "$($u.DisplayName)|$relativePath"
        $meta = $srcMeta[$key]

        Write-Progress -Activity "Uploading: $($u.DisplayName)" `
            -Status ("{0}/{1} files | {2:N1} / {3:N1} MB" -f $i, $files.Count, ($doneBytes / 1MB), ($totalBytes / 1MB)) `
            -CurrentOperation $relativePath `
            -PercentComplete ([math]::Min(100, [int](($i - 1) * 100 / [math]::Max(1, $files.Count))))

        $status = "OK"; $err = ""; $metaStatus = ""
        try {
            # Guard: only upload files the download manifest recorded as clean.
            if (-not $meta) {
                throw "Not in download manifest (unexpected local file) - skipped"
            }
            if ($meta.Status -ne "OK") {
                throw "Download manifest recorded Status=$($meta.Status) - skipped"
            }
            if ([int64]$meta.SizeBytes -ne $file.Length) {
                throw "Local size $($file.Length) != manifest size $($meta.SizeBytes) - possible partial download, skipped"
            }

            $uploaded = Add-PnPFile -Path $file.FullName -Folder $targetFolder

            if ($RestoreMetadata -and $uploaded) {
                # ListItemAllFields may not be initialized on the returned file object
                # depending on PnP version; load it explicitly.
                $listItem = Get-PnPProperty -ClientObject $uploaded -Property ListItemAllFields

                # Build the field hashtable. Created/Modified are set from the source UTC
                # values; SharePoint stores UTC and renders in the viewer's locale.
                $values = @{}
                if ($meta.SrcCreatedUtc)  { $values["Created"]  = ([datetime]$meta.SrcCreatedUtc).ToUniversalTime() }
                if ($meta.SrcModifiedUtc) { $values["Modified"] = ([datetime]$meta.SrcModifiedUtc).ToUniversalTime() }

                # Author (Created By) / Editor (Modified By): resolve to a target user.
                # Prefer the users.csv source->target map; else try the raw source email
                # in case that identity also exists in the target tenant. New-PnPUser wraps
                # EnsureUser and is the reliable way to resolve by UPN. Values are passed
                # as claims login-name strings (not raw IDs) — PnP resolves strings
                # through EnsureUser, which avoids ID-format edge cases.
                foreach ($pair in @(@{Src=$meta.SrcAuthor; Field="Author"}, @{Src=$meta.SrcEditor; Field="Editor"})) {
                    $srcEmail = if ($pair.Src) { $pair.Src.Trim() } else { "" }
                    if (-not $srcEmail) { continue }
                    $targetEmail = $authorMap[$srcEmail.ToLower()]
                    if (-not $targetEmail) { $targetEmail = $srcEmail }  # fall back to same address

                    if (-not $userCache.ContainsKey($targetEmail)) {
                        try {
                            $ensured = New-PnPUser -LoginName $targetEmail -ErrorAction Stop
                            $userCache[$targetEmail] = $ensured.LoginName
                        } catch {
                            $userCache[$targetEmail] = $null
                        }
                    }
                    $login = $userCache[$targetEmail]
                    if ($login) { $values[$pair.Field] = $login }
                }

                # SystemUpdate validates Author/Editor whenever Created/Modified are
                # written. If the source had no resolvable author, supply the current
                # connection user explicitly so SharePoint never resolves an empty one.
                if (($values.ContainsKey("Created") -or $values.ContainsKey("Modified")) -and $currentUser) {
                    if (-not $values.ContainsKey("Author")) { $values["Author"] = $currentUser.LoginName }
                    if (-not $values.ContainsKey("Editor")) { $values["Editor"] = $currentUser.LoginName }
                }

                if ($values.Count -gt 0) {
                    # Modified is hard to persist on SPO document libraries: SystemUpdate
                    # is known to silently drop it on some PnP/SPO combinations, and
                    # SharePoint's post-upload property promotion re-saves Office files
                    # seconds after upload, re-stamping Modified. Strategy:
                    #   Attempt 1: UpdateOverwriteVersion with all fields (the field-
                    #              reported workaround for the SystemUpdate issue).
                    #   Attempt 2: if Modified still wrong, wait out property promotion,
                    #              then re-apply dates via SystemUpdate.
                    # Each attempt is verified by reading back the stored value.
                    $wantMod = $null
                    if ($meta.SrcModifiedUtc) { $wantMod = ([datetime]$meta.SrcModifiedUtc).ToUniversalTime() }

                    # Sampled verification: first 3 files per user always, then every
                    # $VerifyEvery-th. The restore path is deterministic once proven,
                    # so a canary is enough; per-file read-back costs a round trip.
                    $doVerify = $false
                    if ($VerifyEvery -eq 1) { $doVerify = $true }
                    elseif ($VerifyEvery -gt 1) { $doVerify = ($i -le 3) -or ($i % $VerifyEvery -eq 0) }

                    $verifyModified = {
                        param($itemId, $expected)
                        if (-not $expected) { return $true }   # nothing to verify against
                        $check = Get-PnPListItem -List "Documents" -Id $itemId
                        $stored = ([datetime]$check.FieldValues.Modified).ToUniversalTime()
                        return ([math]::Abs(($stored - $expected).TotalSeconds) -le 2)
                    }

                    Set-PnPListItem -List "Documents" -Identity $listItem.Id `
                        -Values $values -UpdateType UpdateOverwriteVersion | Out-Null

                    if (-not $doVerify) {
                        $metaStatus = "restored-unverified:" + ($values.Keys -join "+")
                    } elseif (& $verifyModified $listItem.Id $wantMod) {
                        $metaStatus = "restored:" + ($values.Keys -join "+")
                    } else {
                        # Likely property promotion racing us — let it finish, re-stamp dates.
                        Start-Sleep -Seconds 5
                        $dateVals = @{}
                        if ($values.ContainsKey("Created"))  { $dateVals["Created"]  = $values["Created"] }
                        if ($values.ContainsKey("Modified")) { $dateVals["Modified"] = $values["Modified"] }
                        if ($values.ContainsKey("Editor"))   { $dateVals["Editor"]   = $values["Editor"] }
                        Set-PnPListItem -List "Documents" -Identity $listItem.Id `
                            -Values $dateVals -UpdateType SystemUpdate | Out-Null

                        if (& $verifyModified $listItem.Id $wantMod) {
                            $metaStatus = "restored-on-retry:" + ($values.Keys -join "+")
                        } else {
                            $check = Get-PnPListItem -List "Documents" -Id $listItem.Id
                            $storedMod = ([datetime]$check.FieldValues.Modified).ToUniversalTime()
                            $metaStatus = "restore-verify-FAILED: stored Modified=$($storedMod.ToString('o'))"
                            Write-Warning "  [$i/$($files.Count)] META: $relativePath -- Modified did not stick (stored: $storedMod)"
                        }
                    }
                } else {
                    $metaStatus = "no-source-meta"
                }
            }
        } catch {
            $status = "FAIL"; $err = $_.Exception.Message
            Write-Warning "  [$i/$($files.Count)] FAIL: $relativePath -- $err"
        }

        if ($status -eq "OK") { $doneBytes += $file.Length }

        $manifest.Add([pscustomobject]@{
            Timestamp    = (Get-Date -Format "o")
            User         = $u.DisplayName
            Phase        = "Upload"
            RelativePath = $relativePath
            TargetFolder = $targetFolder
            SizeBytes    = $file.Length
            MetaStatus   = $metaStatus
            Status       = $status
            Error        = $err
        })

    }

    Write-Progress -Activity "Uploading: $($u.DisplayName)" -Completed

    $ok   = ($manifest | Where-Object { $_.User -eq $u.DisplayName -and $_.Status -eq "OK" }).Count
    $fail = ($manifest | Where-Object { $_.User -eq $u.DisplayName -and $_.Status -eq "FAIL" }).Count
    Write-Host "  Done: $ok OK, $fail FAIL" -ForegroundColor Green
}

$manifest | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8
Write-Host "`nUpload manifest written: $manifestPath" -ForegroundColor Cyan

$manifest | Group-Object User | ForEach-Object {
    $g = $_.Group
    [pscustomobject]@{
        User    = $_.Name
        Files   = $g.Count
        OK      = ($g | Where-Object Status -eq "OK").Count
        Failed  = ($g | Where-Object Status -eq "FAIL").Count
        TotalMB = [math]::Round(($g | Measure-Object SizeBytes -Sum).Sum / 1MB, 1)
    }
} | Format-Table -AutoSize
