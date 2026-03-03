<# 
.SYNOPSIS
  Updates onPremisesSyncBehavior.isCloudManaged (beta endpoint) based on CSV input: Identity,Mode
  If Mode is missing/empty -> defaults to TRUE.

.CSV
  Identity,Mode
  becstu1@contoso.onmicrosoft.com,true
  joestu1@contoso.onmicrosoft.com,disable

.NOTES
  - Identity is treated as UserPrincipalName (UPN)
  - Mode is optional. If blank/missing, defaults to $true.
#>

# ----------------------------
# Version
# ----------------------------
$ScriptVersion = "v1.2"
$Updated       = "2026-03-03"

# ----------------------------
# Modules
# ----------------------------
Import-Module Microsoft.Graph.Users -ErrorAction Stop
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

# ----------------------------
# Settings
# ----------------------------
$tenantId  = "" #Add tenantID here
$inputCsv  = ".\input-users.csv"
$WhatIf    = $false   # <--- set to $true to simulate (no changes)

# ----------------------------
# Logging setup
# ----------------------------
$ts      = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = ".\SOA-Convert-$ts.log"
$outCsv  = ".\SOA-Convert-Results-$ts.csv"

function Write-HostColor {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet("Green","Yellow","Red","Cyan","Magenta","Gray","White")][string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet("INFO","SUCCESS","WARN","ERROR")][string]$Level = "INFO"
    )
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "[$stamp] [$Level] $Message"
}

function Convert-ModeToBool {
    param([string]$Mode)

    if ($null -eq $Mode) { return $null }
    $m = $Mode.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($m)) { return $null }

    switch ($m) {
        "true" { return $true }
        "1" { return $true }
        "yes" { return $true }
        "y" { return $true }
        "enable" { return $true }
        "enabled" { return $true }
        "cloud" { return $true }
        "cloudmanaged" { return $true }
        "cloud-managed" { return $true }
        "soa" { return $true }
        "convert" { return $true }

        "false" { return $false }
        "0" { return $false }
        "no" { return $false }
        "n" { return $false }
        "disable" { return $false }
        "disabled" { return $false }
        "onprem" { return $false }
        "onpremmanaged" { return $false }
        "onprem-managed" { return $false }
        "revert" { return $false }

        default { return $null }
    }
}

# ----------------------------
# Start
# ----------------------------
Write-HostColor "SOA Conversion Script $ScriptVersion ($Updated)" Cyan
Write-HostColor "TenantId: $tenantId" Gray
Write-HostColor "Input CSV: $inputCsv" Gray
Write-HostColor "WhatIf: $WhatIf" Yellow
Write-Host ""

Write-Log "Starting. Version=$ScriptVersion Updated=$Updated TenantId=$tenantId InputCsv=$inputCsv WhatIf=$WhatIf" "INFO"

# Connect
try {
    Write-HostColor "Connecting to Microsoft Graph..." Cyan
    Connect-MgGraph -Scopes "User.Read.All,User-OnPremisesSyncBehavior.ReadWrite.All" -TenantId $tenantId -ErrorAction Stop | Out-Null
    Write-HostColor "Connected." Green
    Write-Log "Connected to Microsoft Graph." "SUCCESS"
}
catch {
    Write-HostColor "Failed to connect: $($_.Exception.Message)" Red
    Write-Log "Failed to connect: $($_.Exception.Message)" "ERROR"
    throw
}

# Validate CSV
if (-not (Test-Path $inputCsv)) {
    Write-HostColor "ERROR: Input CSV not found: $inputCsv" Red
    Write-Log "Input CSV not found: $inputCsv" "ERROR"
    throw "Missing input CSV: $inputCsv"
}

$rows = Import-Csv -Path $inputCsv
if (-not $rows -or $rows.Count -eq 0) {
    Write-HostColor "ERROR: Input CSV is empty: $inputCsv" Red
    Write-Log "Input CSV is empty: $inputCsv" "ERROR"
    throw "Empty input CSV: $inputCsv"
}

# Results
$results = New-Object System.Collections.Generic.List[object]
$total   = $rows.Count
$idx     = 0

foreach ($row in $rows) {
    $idx++

    $upnRaw  = $row.Identity
    $modeRaw = $row.Mode

    $upn = if ($upnRaw) { $upnRaw.Trim() } else { "" }
    if ([string]::IsNullOrWhiteSpace($upn)) {
        $msg = "Row ${idx}/${total}: Missing Identity. Skipping."
        Write-HostColor $msg Yellow
        Write-Log $msg "WARN"

        $results.Add([pscustomobject]@{
            Timestamp = (Get-Date).ToString("s")
            Identity  = ""
            Mode      = $modeRaw
            DisplayName = ""
            ObjectId  = ""
            PreviousIsCloudManaged = ""
            TargetIsCloudManaged   = ""
            NewIsCloudManaged      = ""
            Action   = "Skipped"
            Status   = "MissingIdentity"
            Error    = ""
        })
        continue
    }

    # Mode OPTIONAL: if empty/missing -> default TRUE
    $targetBool = Convert-ModeToBool -Mode $modeRaw
    if ($null -eq $targetBool) {
        $targetBool = $true
        $msg = "Row ${idx}/${total}: Mode missing/blank for ${upn}. Defaulting to TRUE."
        Write-HostColor $msg Magenta
        Write-Log $msg "WARN"
    }

    Write-HostColor "[${idx}/${total}] Processing: $upn  (Target isCloudManaged=$targetBool)" Cyan
    Write-Log "Row ${idx}/${total}: Processing $upn Target=$targetBool (Mode=$modeRaw)" "INFO"

    $displayName  = ""
    $userObjectId = ""
    $prevVal      = ""
    $newVal       = ""

    try {
        # Lookup user by UPN
        $user = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ConsistencyLevel eventual -CountVariable count -ErrorAction Stop

        if ($null -eq $user) {
            $msg = "User not found: $upn"
            Write-HostColor $msg Yellow
            Write-Log $msg "WARN"

            $results.Add([pscustomobject]@{
                Timestamp = (Get-Date).ToString("s")
                Identity  = $upn
                Mode      = $modeRaw
                DisplayName = ""
                ObjectId  = ""
                PreviousIsCloudManaged = ""
                TargetIsCloudManaged   = $targetBool
                NewIsCloudManaged      = ""
                Action   = "Skipped"
                Status   = "NotFound"
                Error    = ""
            })
            continue
        }

        $displayName  = $user.DisplayName
        $userObjectId = $user.Id

        # Read current (beta endpoint)
        $getUrl  = "https://graph.microsoft.com/beta/users/$userObjectId/onPremisesSyncBehavior?`$select=id,isCloudManaged"
        $current = Invoke-MgGraphRequest -Method Get -Uri $getUrl -ErrorAction Stop
        $prevVal = $current.isCloudManaged

        $prevIsTrue  = ($prevVal -eq $true -or "$prevVal" -eq "true")
        $prevIsFalse = ($prevVal -eq $false -or "$prevVal" -eq "false")

        $alreadyTarget =
            ($targetBool -eq $true  -and $prevIsTrue) -or
            ($targetBool -eq $false -and $prevIsFalse)

        if ($alreadyTarget) {
            $msg = "No change (already isCloudManaged=$targetBool): $upn ($displayName)"
            Write-HostColor $msg Yellow
            Write-Log $msg "INFO"

            $results.Add([pscustomobject]@{
                Timestamp = (Get-Date).ToString("s")
                Identity  = $upn
                Mode      = $modeRaw
                DisplayName = $displayName
                ObjectId  = $userObjectId
                PreviousIsCloudManaged = $prevVal
                TargetIsCloudManaged   = $targetBool
                NewIsCloudManaged      = $prevVal
                Action   = "NoChange"
                Status   = "OK"
                Error    = ""
            })
            continue
        }

        if ($WhatIf) {
            $msg = "WHATIF: Would set isCloudManaged=$targetBool for $upn ($displayName)"
            Write-HostColor $msg Magenta
            Write-Log $msg "INFO"

            $results.Add([pscustomobject]@{
                Timestamp = (Get-Date).ToString("s")
                Identity  = $upn
                Mode      = $modeRaw
                DisplayName = $displayName
                ObjectId  = $userObjectId
                PreviousIsCloudManaged = $prevVal
                TargetIsCloudManaged   = $targetBool
                NewIsCloudManaged      = ""
                Action   = "WhatIf"
                Status   = "Planned"
                Error    = ""
            })
            continue
        }

        # PATCH
        $patchUrl = "https://graph.microsoft.com/beta/users/$userObjectId/onPremisesSyncBehavior"
        $jsonPayload = @{ isCloudManaged = $targetBool } | ConvertTo-Json

        Invoke-MgGraphRequest -Uri $patchUrl -Method Patch -ContentType "application/json" -Body $jsonPayload -ErrorAction Stop

        # Verify
        $verify = Invoke-MgGraphRequest -Method Get -Uri $getUrl -ErrorAction Stop
        $newVal = $verify.isCloudManaged

        $newIsTarget =
            ($targetBool -eq $true  -and ($newVal -eq $true -or "$newVal" -eq "true")) -or
            ($targetBool -eq $false -and ($newVal -eq $false -or "$newVal" -eq "false"))

        if ($newIsTarget) {
            $msg = "Changed: $upn ($displayName) -> isCloudManaged=$targetBool"
            Write-HostColor $msg Green
            Write-Log $msg "SUCCESS"

            $results.Add([pscustomobject]@{
                Timestamp = (Get-Date).ToString("s")
                Identity  = $upn
                Mode      = $modeRaw
                DisplayName = $displayName
                ObjectId  = $userObjectId
                PreviousIsCloudManaged = $prevVal
                TargetIsCloudManaged   = $targetBool
                NewIsCloudManaged      = $newVal
                Action   = "Updated"
                Status   = "OK"
                Error    = ""
            })
        }
        else {
            $msg = "Warning: Updated but verification did not match target. $upn ($displayName) newValue='$newVal' target='$targetBool'"
            Write-HostColor $msg Magenta
            Write-Log $msg "WARN"

            $results.Add([pscustomobject]@{
                Timestamp = (Get-Date).ToString("s")
                Identity  = $upn
                Mode      = $modeRaw
                DisplayName = $displayName
                ObjectId  = $userObjectId
                PreviousIsCloudManaged = $prevVal
                TargetIsCloudManaged   = $targetBool
                NewIsCloudManaged      = $newVal
                Action   = "Updated"
                Status   = "VerifyFailed"
                Error    = ""
            })
        }
    }
    catch {
        $err = $_.Exception.Message
        $msg = "ERROR: ${upn} -> $err"
        Write-HostColor $msg Red
        Write-Log $msg "ERROR"

        $results.Add([pscustomobject]@{
            Timestamp = (Get-Date).ToString("s")
            Identity  = $upn
            Mode      = $modeRaw
            DisplayName = $displayName
            ObjectId  = $userObjectId
            PreviousIsCloudManaged = $prevVal
            TargetIsCloudManaged   = $targetBool
            NewIsCloudManaged      = $newVal
            Action   = "Failed"
            Status   = "Error"
            Error    = $err
        })
    }

    Write-Host ""
}

# Export results (semicolon for DK-friendly Excel)
$results | Export-Csv -Path $outCsv -NoTypeInformation -Encoding UTF8 -Delimiter ";"

Write-HostColor "Done." Cyan
Write-HostColor "Log file:   $logFile" Gray
Write-HostColor "Result CSV: $outCsv" Gray

Write-Log "Completed. Results exported to $outCsv" "INFO"

Disconnect-MgGraph | Out-Null
Write-Log "Disconnected from Microsoft Graph." "INFO"
