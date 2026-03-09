#Requires -Version 5.1
<#
.SYNOPSIS
    Entra SOA Manager - GUI Version
    Manage Source of Authority (SOA) for Microsoft Entra ID users via a Windows Forms interface.

.DESCRIPTION
    A dark-themed Windows Forms GUI application that connects to Microsoft Graph and lets you:
      - Load all Entra ID users and view their current SOA state (isCloudManaged)
      - Filter / search the user list in real time
      - Multi-select users and set their SOA to Cloud (Entra) - isCloudManaged = true
      - Multi-select users and revert their SOA to On-Premises  - isCloudManaged = false
      - WhatIf / simulation mode (no changes are written)
      - Color-coded log panel with timestamps and levels
      - All activity is written to a timestamped .log file
      - Export the full user list (with SOA state) to a semicolon-delimited CSV
      - Right-click context menu on the grid for quick actions

.NOTES
    Version:    v1.0
    Updated:    2026-03-09
    Author:     Peter Schmidt

    Required Modules:
        Microsoft.Graph.Authentication
        Microsoft.Graph.Users

    Required Graph Permissions (delegated):
        User.Read.All
        User-OnPremisesSyncBehavior.ReadWrite.All

    Graph API used:
        GET  https://graph.microsoft.com/v1.0/users
        GET  https://graph.microsoft.com/beta/users/{id}/onPremisesSyncBehavior
        PATCH https://graph.microsoft.com/beta/users/{id}/onPremisesSyncBehavior
#>

# ─────────────────────────────────────────────────────────────────────────────
#  BOOTSTRAP – WinForms + module check
# ─────────────────────────────────────────────────────────────────────────────
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

foreach ($mod in @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Users')) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Required PowerShell module not found:`n`n  $mod`n`nInstall it with:`n  Install-Module $mod -Scope CurrentUser",
            "Missing Module",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        exit 1
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  SCRIPT-LEVEL STATE
# ─────────────────────────────────────────────────────────────────────────────
$Script:AppVersion  = "v1.0"
$Script:AppUpdated  = "2026-03-09"
$Script:AppTitle    = "Entra SOA Manager GUI  $($Script:AppVersion)"

$Script:LogFile     = ""
$Script:IsConnected = $false
$Script:WhatIf      = $false
$Script:UserData    = [System.Collections.Generic.List[hashtable]]::new()  # all loaded users
$Script:Results     = [System.Collections.Generic.List[PSObject]]::new()   # action results

# UI control references (set during form build, used by functions)
$Script:TxtLog              = $null
$Script:DgvUsers            = $null
$Script:LblConnectionStatus = $null
$Script:BtnConnect          = $null
$Script:BtnDisconnect       = $null
$Script:BtnLoadUsers        = $null
$Script:BtnLoadSOA          = $null
$Script:StatusLabel         = $null
$Script:ProgBar             = $null
$Script:MainForm            = $null
$Script:LblSelectionInfo    = $null

# ─────────────────────────────────────────────────────────────────────────────
#  LOGGING
# ─────────────────────────────────────────────────────────────────────────────
function Initialize-Logging {
    $ts               = Get-Date -Format "yyyyMMdd-HHmmss"
    $Script:LogFile   = ".\SOA-GUI-$ts.log"
}

function Write-LogFile {
    param(
        [string]$Message,
        [ValidateSet("INFO","SUCCESS","WARN","ERROR")][string]$Level = "INFO"
    )
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line  = "[$stamp] [$Level] $Message"
    if ($Script:LogFile) {
        try { Add-Content -Path $Script:LogFile -Value $line -ErrorAction SilentlyContinue } catch {}
    }
    return $line
}

function Log-Message {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    $color = switch ($Level) {
        "SUCCESS" { [System.Drawing.Color]::FromArgb(100, 220, 120) }
        "WARN"    { [System.Drawing.Color]::FromArgb(240, 200, 60)  }
        "ERROR"   { [System.Drawing.Color]::FromArgb(240, 100, 90)  }
        "SECTION" { [System.Drawing.Color]::FromArgb(100, 160, 240) }
        default   { [System.Drawing.Color]::FromArgb(190, 190, 190) }
    }
    $fileLevel = if ($Level -eq "SECTION") { "INFO" } else { $Level }
    $line = Write-LogFile -Message $Message -Level $fileLevel

    if ($Script:TxtLog -and -not $Script:TxtLog.IsDisposed) {
        $Script:TxtLog.SelectionStart  = $Script:TxtLog.TextLength
        $Script:TxtLog.SelectionLength = 0
        $Script:TxtLog.SelectionColor  = $color
        $Script:TxtLog.AppendText("$line`r`n")
        $Script:TxtLog.ScrollToCaret()
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Log-Info    { param([string]$m) Log-Message $m "INFO"    }
function Log-Success { param([string]$m) Log-Message $m "SUCCESS" }
function Log-Warn    { param([string]$m) Log-Message $m "WARN"    }
function Log-Error   { param([string]$m) Log-Message $m "ERROR"   }
function Log-Section { param([string]$m) Log-Message "─── $m ───" "SECTION" }

# ─────────────────────────────────────────────────────────────────────────────
#  STATUS BAR
# ─────────────────────────────────────────────────────────────────────────────
function Set-StatusText {
    param([string]$Text)
    if ($Script:StatusLabel -and -not $Script:StatusLabel.IsDisposed) {
        $Script:StatusLabel.Text = $Text
        [System.Windows.Forms.Application]::DoEvents()
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  GRAPH – CONNECT / DISCONNECT
# ─────────────────────────────────────────────────────────────────────────────
function Connect-ToGraph {
    param([string]$TenantId)

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        Log-Warn "Tenant ID is empty. Please enter a valid Azure Tenant ID (GUID)."
        return $false
    }

    Log-Section "Connecting to Microsoft Graph"
    Log-Info "Tenant ID : $TenantId"
    Log-Info "Scopes    : User.Read.All, User-OnPremisesSyncBehavior.ReadWrite.All"

    try {
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        Import-Module Microsoft.Graph.Users          -ErrorAction Stop

        Connect-MgGraph `
            -Scopes   "User.Read.All,User-OnPremisesSyncBehavior.ReadWrite.All" `
            -TenantId $TenantId `
            -ErrorAction Stop | Out-Null

        $ctx = Get-MgContext
        Log-Success "Connected successfully"
        Log-Info    "Account  : $($ctx.Account)"
        Log-Info    "Tenant   : $($ctx.TenantId)"

        $Script:IsConnected = $true
        Write-LogFile "Connected to Microsoft Graph. Account=$($ctx.Account) Tenant=$($ctx.TenantId)" "SUCCESS"
        return $true
    }
    catch {
        Log-Error "Connection failed: $($_.Exception.Message)"
        Write-LogFile "Connection failed: $($_.Exception.Message)" "ERROR"
        $Script:IsConnected = $false
        return $false
    }
}

function Disconnect-FromGraph {
    if ($Script:IsConnected) {
        try {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        }
        catch {}
        $Script:IsConnected = $false
        Log-Info "Disconnected from Microsoft Graph."
        Write-LogFile "Disconnected from Microsoft Graph." "INFO"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  GRAPH – LOAD USERS (paginated)
# ─────────────────────────────────────────────────────────────────────────────
function Load-EntraUsers {
    Log-Section "Loading Entra ID Users"
    $Script:UserData.Clear()

    try {
        $selectFields = "id,displayName,userPrincipalName,accountEnabled,userType"
        $uri = "https://graph.microsoft.com/v1.0/users" +
               "?`$select=$selectFields&`$top=999&`$orderby=displayName&`$count=true"

        $page  = 0
        $total = 0

        do {
            $page++
            $response = Invoke-MgGraphRequest `
                -Method  Get `
                -Uri     $uri `
                -Headers @{ ConsistencyLevel = "eventual" } `
                -ErrorAction Stop

            foreach ($u in $response.value) {
                $dn  = if ($u.displayName)       { $u.displayName }       else { "" }
                $upn = if ($u.userPrincipalName) { $u.userPrincipalName } else { "" }
                $ut  = if ($u.userType)          { $u.userType }          else { "Member" }

                $Script:UserData.Add(@{
                    ObjectId          = $u.id
                    DisplayName       = $dn
                    UserPrincipalName = $upn
                    AccountEnabled    = $u.accountEnabled
                    UserType          = $ut
                    IsCloudManaged    = $null        # loaded later
                    SoaState          = "Not Loaded"
                    LastUpdated       = ""
                })
                $total++
            }

            Log-Info "  Page $page – $total users loaded so far..."
            $uri = $response.'@odata.nextLink'
            [System.Windows.Forms.Application]::DoEvents()

        } while ($uri)

        Log-Success "Total users loaded: $total"
        Write-LogFile "Users loaded: $total" "SUCCESS"
        return $true
    }
    catch {
        Log-Error "Failed to load users: $($_.Exception.Message)"
        Write-LogFile "Load users failed: $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  GRAPH – LOAD SOA STATE (per-user, with progress)
# ─────────────────────────────────────────────────────────────────────────────
function Load-SOAState {
    param([System.Collections.Generic.List[hashtable]]$Users)

    if ($Users.Count -eq 0) { return }

    Log-Section "Refreshing SOA state for $($Users.Count) users"

    if ($Script:ProgBar) {
        $Script:ProgBar.Minimum = 0
        $Script:ProgBar.Maximum = $Users.Count
        $Script:ProgBar.Value   = 0
        $Script:ProgBar.Visible = $true
        [System.Windows.Forms.Application]::DoEvents()
    }

    $ok  = 0
    $err = 0

    for ($i = 0; $i -lt $Users.Count; $i++) {
        $u = $Users[$i]
        try {
            $uri    = "https://graph.microsoft.com/beta/users/$($u.ObjectId)" +
                      "/onPremisesSyncBehavior?`$select=id,isCloudManaged"
            $result = Invoke-MgGraphRequest -Method Get -Uri $uri -ErrorAction Stop
            $icm    = $result.isCloudManaged

            $u.IsCloudManaged = $icm
            $u.SoaState       = if ($icm -eq $true)  { "Cloud (Entra)" }
                                 elseif ($icm -eq $false) { "On-Premises" }
                                 else { "Unknown" }
            $ok++
        }
        catch {
            $u.IsCloudManaged = $null
            $u.SoaState       = "Error"
            Log-Warn "  SOA load error for $($u.UserPrincipalName): $($_.Exception.Message)"
            $err++
        }

        if ($Script:ProgBar) { $Script:ProgBar.Value = $i + 1 }

        # Update status every 10 users to keep the UI responsive
        if ((($i + 1) % 10 -eq 0) -or ($i -eq ($Users.Count - 1))) {
            Set-StatusText "Loading SOA state: $($i+1) / $($Users.Count)..."
            [System.Windows.Forms.Application]::DoEvents()
        }
    }

    if ($Script:ProgBar) { $Script:ProgBar.Visible = $false }

    Log-Success "SOA state loaded – OK: $ok   Errors: $err"
    Write-LogFile "SOA state loaded – OK=$ok  Errors=$err" "SUCCESS"
}

# ─────────────────────────────────────────────────────────────────────────────
#  GRAPH – GET SINGLE USER SOA STATE
# ─────────────────────────────────────────────────────────────────────────────
function Get-UserSOAState {
    param([string]$ObjectId)
    try {
        $uri    = "https://graph.microsoft.com/beta/users/$ObjectId" +
                  "/onPremisesSyncBehavior?`$select=id,isCloudManaged"
        $result = Invoke-MgGraphRequest -Method Get -Uri $uri -ErrorAction Stop
        return $result.isCloudManaged
    }
    catch {
        return $null
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  GRAPH – SET / REVERT SOA FOR ONE USER
# ─────────────────────────────────────────────────────────────────────────────
function Set-UserSOA {
    param(
        [hashtable]$UserEntry,
        [bool]$TargetIsCloud,
        [bool]$WhatIfMode = $false
    )

    $upn         = $UserEntry.UserPrincipalName
    $dn          = $UserEntry.DisplayName
    $oid         = $UserEntry.ObjectId
    $prev        = $UserEntry.IsCloudManaged
    $actionLabel = if ($TargetIsCloud) { "Cloud (Entra)" } else { "On-Premises" }

    Log-Info "  User       : $upn  ($dn)"
    Log-Info "  Current    : $($UserEntry.SoaState)"
    Log-Info "  Target     : $actionLabel"

    # ── Already at target state ──────────────────────────────────────────────
    $alreadyTarget = ($null -ne $prev) -and ($prev -eq $TargetIsCloud)
    if ($alreadyTarget) {
        Log-Warn "  No change needed – already set to $actionLabel"
        Write-LogFile "NoChange: $upn  ($dn)  already=$actionLabel" "INFO"
        return [PSCustomObject]@{
            Timestamp              = (Get-Date).ToString("s")
            DisplayName            = $dn
            UserPrincipalName      = $upn
            ObjectId               = $oid
            TargetSOA              = $actionLabel
            PreviousIsCloudManaged = $prev
            NewIsCloudManaged      = $prev
            Action                 = "NoChange"
            Status                 = "OK"
            Error                  = ""
        }
    }

    # ── WhatIf mode ──────────────────────────────────────────────────────────
    if ($WhatIfMode) {
        Log-Warn "  WHATIF: Would set isCloudManaged=$TargetIsCloud for $upn"
        Write-LogFile "WHATIF: $upn  target=$actionLabel" "INFO"
        return [PSCustomObject]@{
            Timestamp              = (Get-Date).ToString("s")
            DisplayName            = $dn
            UserPrincipalName      = $upn
            ObjectId               = $oid
            TargetSOA              = $actionLabel
            PreviousIsCloudManaged = $prev
            NewIsCloudManaged      = "(WhatIf – not applied)"
            Action                 = "WhatIf"
            Status                 = "Planned"
            Error                  = ""
        }
    }

    # ── Apply PATCH ──────────────────────────────────────────────────────────
    try {
        $patchUri    = "https://graph.microsoft.com/beta/users/$oid/onPremisesSyncBehavior"
        $jsonPayload = @{ isCloudManaged = $TargetIsCloud } | ConvertTo-Json

        Invoke-MgGraphRequest `
            -Uri         $patchUri `
            -Method      Patch `
            -ContentType "application/json" `
            -Body        $jsonPayload `
            -ErrorAction Stop

        # ── Verify ───────────────────────────────────────────────────────────
        $newVal   = Get-UserSOAState -ObjectId $oid
        $newLabel = if ($newVal -eq $true)  { "Cloud (Entra)" }
                    elseif ($newVal -eq $false) { "On-Premises" }
                    else { "Unknown" }

        $verified = ($newVal -eq $TargetIsCloud)

        # Update user entry in-memory so the grid reflects the new state
        $UserEntry.IsCloudManaged = $newVal
        $UserEntry.SoaState       = $newLabel
        $UserEntry.LastUpdated    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

        if ($verified) {
            Log-Success "  Changed:  $upn  →  $actionLabel  (verified)"
            Write-LogFile "Updated OK: $upn  previous=$prev  new=$newVal  target=$TargetIsCloud" "SUCCESS"
            return [PSCustomObject]@{
                Timestamp              = (Get-Date).ToString("s")
                DisplayName            = $dn
                UserPrincipalName      = $upn
                ObjectId               = $oid
                TargetSOA              = $actionLabel
                PreviousIsCloudManaged = $prev
                NewIsCloudManaged      = $newVal
                Action                 = "Updated"
                Status                 = "OK"
                Error                  = ""
            }
        }
        else {
            Log-Warn "  Updated but verification mismatch!  got=$newLabel  expected=$actionLabel"
            Write-LogFile "VerifyFailed: $upn  newValue=$newVal  expected=$TargetIsCloud" "WARN"
            return [PSCustomObject]@{
                Timestamp              = (Get-Date).ToString("s")
                DisplayName            = $dn
                UserPrincipalName      = $upn
                ObjectId               = $oid
                TargetSOA              = $actionLabel
                PreviousIsCloudManaged = $prev
                NewIsCloudManaged      = $newVal
                Action                 = "Updated"
                Status                 = "VerifyFailed"
                Error                  = "Post-update value=$newVal expected=$TargetIsCloud"
            }
        }
    }
    catch {
        $errMsg = $_.Exception.Message
        Log-Error "  ERROR: $errMsg"
        Write-LogFile "Error: $upn  $errMsg" "ERROR"
        return [PSCustomObject]@{
            Timestamp              = (Get-Date).ToString("s")
            DisplayName            = $dn
            UserPrincipalName      = $upn
            ObjectId               = $oid
            TargetSOA              = $actionLabel
            PreviousIsCloudManaged = $prev
            NewIsCloudManaged      = ""
            Action                 = "Failed"
            Status                 = "Error"
            Error                  = $errMsg
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  UI HELPER – REFRESH THE DATAGRIDVIEW
# ─────────────────────────────────────────────────────────────────────────────
function Refresh-UserGrid {
    param([string]$Filter = "")

    if (-not $Script:DgvUsers -or $Script:DgvUsers.IsDisposed) { return }

    $dgv         = $Script:DgvUsers
    $filterLower = $Filter.ToLower()

    $dgv.SuspendLayout()
    $dgv.Rows.Clear()

    $count = 0
    foreach ($u in $Script:UserData) {
        # Client-side filter
        if ($filterLower) {
            $match = $u.DisplayName.ToLower().Contains($filterLower) -or
                     $u.UserPrincipalName.ToLower().Contains($filterLower)
            if (-not $match) { continue }
        }

        $icm   = $u.IsCloudManaged
        $soa   = $u.SoaState
        $rowIdx = $dgv.Rows.Add()
        $row    = $dgv.Rows[$rowIdx]
        $row.Tag = $u  # keep reference so we can update in-memory

        $row.Cells["colDisplayName"].Value    = $u.DisplayName
        $row.Cells["colUPN"].Value            = $u.UserPrincipalName
        $row.Cells["colIsCloudManaged"].Value = if ($null -eq $icm) { "N/A" } else { $icm.ToString() }
        $row.Cells["colSOAState"].Value       = $soa
        $row.Cells["colAccountEnabled"].Value = if ($null -eq $u.AccountEnabled) { "N/A" } else { $u.AccountEnabled.ToString() }
        $row.Cells["colUserType"].Value       = $u.UserType
        $row.Cells["colLastUpdated"].Value    = $u.LastUpdated

        # Colour-code rows by SOA state (subtle – just the ForeColor)
        $row.DefaultCellStyle.ForeColor = switch ($soa) {
            "Cloud (Entra)"  { [System.Drawing.Color]::FromArgb(120, 220, 130) }
            "On-Premises"    { [System.Drawing.Color]::FromArgb(240, 160, 80)  }
            "Error"          { [System.Drawing.Color]::FromArgb(240, 100, 90)  }
            default          { [System.Drawing.Color]::FromArgb(190, 190, 190) }
        }
        $count++
    }

    $dgv.ResumeLayout()

    if ($Script:LblSelectionInfo) {
        $Script:LblSelectionInfo.Text = "0 selected  |  $count shown  |  $($Script:UserData.Count) total"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  UI HELPER – UPDATE CONNECTION STATUS CONTROLS
# ─────────────────────────────────────────────────────────────────────────────
function Update-ConnectionUI {
    param([bool]$Connected, [string]$Account = "")

    if ($Connected) {
        $Script:LblConnectionStatus.Text      = if ($Account) { "Connected  ($Account)" } else { "Connected" }
        $Script:LblConnectionStatus.ForeColor = [System.Drawing.Color]::FromArgb(100, 220, 120)
        $Script:BtnConnect.Enabled            = $false
        $Script:BtnDisconnect.Enabled         = $true
        $Script:BtnLoadUsers.Enabled          = $true
        $Script:BtnLoadSOA.Enabled            = ($Script:UserData.Count -gt 0)
    }
    else {
        $Script:LblConnectionStatus.Text      = "Not connected"
        $Script:LblConnectionStatus.ForeColor = [System.Drawing.Color]::FromArgb(240, 100, 90)
        $Script:BtnConnect.Enabled            = $true
        $Script:BtnDisconnect.Enabled         = $false
        $Script:BtnLoadUsers.Enabled          = $false
        $Script:BtnLoadSOA.Enabled            = $false
    }
}

# ─────────────────────────────────────────────────────────────────────────────
#  UI HELPER – GET SELECTED USER ENTRIES FROM GRID
# ─────────────────────────────────────────────────────────────────────────────
function Get-SelectedUserEntries {
    $list = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($row in $Script:DgvUsers.SelectedRows) {
        if ($row.Tag -is [hashtable]) { $list.Add($row.Tag) }
    }
    return $list
}

# ─────────────────────────────────────────────────────────────────────────────
#  UI HELPER – RUN SOA OPERATION ON SELECTED USERS
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-SOAOperation {
    param([bool]$TargetIsCloud, [string]$TxtFilter)

    $selected    = Get-SelectedUserEntries
    $actionLabel = if ($TargetIsCloud) { "Cloud (Entra)" } else { "On-Premises" }

    if ($selected.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "No users selected.`n`nPlease select one or more rows in the list first.",
            "No Selection",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return
    }

    $whatIfNote = if ($Script:WhatIf) { "`n`n[WhatIf Mode – no changes will be written]" } else { "" }
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Set SOA to '$actionLabel' for $($selected.Count) selected user(s)?$whatIfNote",
        "Confirm Action",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    Log-Section "Setting SOA to $actionLabel for $($selected.Count) user(s)"
    if ($Script:WhatIf) { Log-Warn "WhatIf mode active – no changes will be applied" }

    if ($Script:MainForm) { $Script:MainForm.UseWaitCursor = $true }

    $Script:ProgBar.Minimum = 0
    $Script:ProgBar.Maximum = $selected.Count
    $Script:ProgBar.Value   = 0
    $Script:ProgBar.Visible = $true

    $ok      = 0
    $noChg   = 0
    $errored = 0
    $planned = 0
    $idx     = 0

    foreach ($u in $selected) {
        $idx++
        Log-Info "[$idx / $($selected.Count)] Processing: $($u.UserPrincipalName)"
        $result = Set-UserSOA -UserEntry $u -TargetIsCloud $TargetIsCloud -WhatIfMode $Script:WhatIf
        $Script:Results.Add($result)

        switch ($result.Status) {
            "OK"         { if ($result.Action -eq "NoChange") { $noChg++ } else { $ok++ } }
            "Planned"    { $planned++ }
            default      { $errored++ }
        }

        $Script:ProgBar.Value = $idx
        Set-StatusText "Processing $idx / $($selected.Count)..."
        [System.Windows.Forms.Application]::DoEvents()
    }

    $Script:ProgBar.Visible = $false
    if ($Script:MainForm) { $Script:MainForm.UseWaitCursor = $false }

    Refresh-UserGrid -Filter $TxtFilter

    $summary = "Done: $ok changed, $noChg no-change, $planned planned (WhatIf), $errored error(s)"
    Log-Section $summary
    Set-StatusText $summary
    Write-LogFile $summary "INFO"
}

# ─────────────────────────────────────────────────────────────────────────────
#  BUILD THE MAIN FORM
# ─────────────────────────────────────────────────────────────────────────────
function New-MainForm {

    # ── Colour palette ────────────────────────────────────────────────────────
    $clrBg        = [System.Drawing.Color]::FromArgb(28, 28, 30)
    $clrPanel     = [System.Drawing.Color]::FromArgb(38, 38, 42)
    $clrToolbar   = [System.Drawing.Color]::FromArgb(33, 33, 37)
    $clrInput     = [System.Drawing.Color]::FromArgb(52, 52, 58)
    $clrFg        = [System.Drawing.Color]::FromArgb(215, 215, 215)
    $clrBlue      = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $clrGreen     = [System.Drawing.Color]::FromArgb(0, 160, 80)
    $clrOrange    = [System.Drawing.Color]::FromArgb(180, 80, 0)
    $clrGray      = [System.Drawing.Color]::FromArgb(70, 70, 78)
    $clrAccent    = [System.Drawing.Color]::FromArgb(100, 160, 240)
    $clrLogBg     = [System.Drawing.Color]::FromArgb(18, 18, 20)

    $flatBorder   = [System.Windows.Forms.FlatStyle]::Flat
    $fontUI       = New-Object System.Drawing.Font("Segoe UI", 9)
    $fontBold     = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $fontMono     = New-Object System.Drawing.Font("Consolas",  8.5)
    $fontTitle    = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)

    # ── Helper to create a styled button ─────────────────────────────────────
    function New-Button {
        param([string]$Text, [int]$W, [int]$H, [int]$X, [int]$Y,
              [System.Drawing.Color]$Back, [bool]$Bold = $false)
        $b = New-Object System.Windows.Forms.Button
        $b.Text      = $Text
        $b.Size      = New-Object System.Drawing.Size($W, $H)
        $b.Location  = New-Object System.Drawing.Point($X, $Y)
        $b.BackColor = $Back
        $b.ForeColor = [System.Drawing.Color]::White
        $b.FlatStyle = $flatBorder
        $b.FlatAppearance.BorderSize = 0
        $b.Font      = if ($Bold) { $fontBold } else { $fontUI }
        $b.Cursor    = [System.Windows.Forms.Cursors]::Hand
        return $b
    }

    # ══════════════════════════════════════════════════════════════════════════
    #  FORM
    # ══════════════════════════════════════════════════════════════════════════
    $form = New-Object System.Windows.Forms.Form
    $form.Text          = $Script:AppTitle
    $form.Size          = New-Object System.Drawing.Size(1280, 960)
    $form.MinimumSize   = New-Object System.Drawing.Size(960, 720)
    $form.StartPosition = "CenterScreen"
    $form.BackColor     = $clrBg
    $form.ForeColor     = $clrFg
    $form.Font          = $fontUI
    $Script:MainForm    = $form

    # ══════════════════════════════════════════════════════════════════════════
    #  TOP PANEL – Connection
    # ══════════════════════════════════════════════════════════════════════════
    $panConnect = New-Object System.Windows.Forms.Panel
    $panConnect.Dock      = "Top"
    $panConnect.Height    = 88
    $panConnect.BackColor = $clrPanel
    $panConnect.Padding   = New-Object System.Windows.Forms.Padding(12)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text      = $Script:AppTitle
    $lblTitle.Font      = $fontTitle
    $lblTitle.ForeColor = $clrAccent
    $lblTitle.AutoSize  = $true
    $lblTitle.Location  = New-Object System.Drawing.Point(12, 8)

    $lblVer = New-Object System.Windows.Forms.Label
    $lblVer.Text      = "Updated $($Script:AppUpdated)"
    $lblVer.ForeColor = $clrGray
    $lblVer.AutoSize  = $true
    $lblVer.Location  = New-Object System.Drawing.Point(14, 30)

    $lblTenant = New-Object System.Windows.Forms.Label
    $lblTenant.Text      = "Tenant ID:"
    $lblTenant.ForeColor = $clrFg
    $lblTenant.AutoSize  = $true
    $lblTenant.Location  = New-Object System.Drawing.Point(12, 58)

    $txtTenantId = New-Object System.Windows.Forms.TextBox
    $txtTenantId.Size        = New-Object System.Drawing.Size(310, 24)
    $txtTenantId.Location    = New-Object System.Drawing.Point(86, 55)
    $txtTenantId.BackColor   = $clrInput
    $txtTenantId.ForeColor   = $clrFg
    $txtTenantId.BorderStyle = "FixedSingle"
    $txtTenantId.Font        = $fontUI

    $btnConnect = New-Button "Connect" 100 26 406 54 $clrBlue
    $Script:BtnConnect = $btnConnect

    $btnDisconnect = New-Button "Disconnect" 100 26 514 54 $clrGray
    $btnDisconnect.Enabled    = $false
    $Script:BtnDisconnect     = $btnDisconnect

    $chkWhatIf = New-Object System.Windows.Forms.CheckBox
    $chkWhatIf.Text      = "WhatIf Mode  (simulate – no changes written)"
    $chkWhatIf.ForeColor = [System.Drawing.Color]::FromArgb(240, 200, 60)
    $chkWhatIf.AutoSize  = $true
    $chkWhatIf.Location  = New-Object System.Drawing.Point(636, 57)
    $chkWhatIf.Font      = $fontBold
    $chkWhatIf.Cursor    = [System.Windows.Forms.Cursors]::Hand

    $lblConnectionStatus = New-Object System.Windows.Forms.Label
    $lblConnectionStatus.Text      = "Not connected"
    $lblConnectionStatus.ForeColor = [System.Drawing.Color]::FromArgb(240, 100, 90)
    $lblConnectionStatus.AutoSize  = $true
    $lblConnectionStatus.Location  = New-Object System.Drawing.Point(920, 59)
    $lblConnectionStatus.Font      = $fontBold
    $Script:LblConnectionStatus    = $lblConnectionStatus

    $panConnect.Controls.AddRange(@(
        $lblTitle, $lblVer, $lblTenant, $txtTenantId,
        $btnConnect, $btnDisconnect, $chkWhatIf, $lblConnectionStatus
    ))

    # ══════════════════════════════════════════════════════════════════════════
    #  SECOND TOP PANEL – Toolbar / Filter
    # ══════════════════════════════════════════════════════════════════════════
    $panToolbar = New-Object System.Windows.Forms.Panel
    $panToolbar.Dock      = "Top"
    $panToolbar.Height    = 46
    $panToolbar.BackColor = $clrToolbar
    $panToolbar.Padding   = New-Object System.Windows.Forms.Padding(6)

    $lblFilter = New-Object System.Windows.Forms.Label
    $lblFilter.Text      = "Filter:"
    $lblFilter.ForeColor = $clrFg
    $lblFilter.AutoSize  = $true
    $lblFilter.Location  = New-Object System.Drawing.Point(10, 14)

    $txtFilter = New-Object System.Windows.Forms.TextBox
    $txtFilter.Size        = New-Object System.Drawing.Size(230, 24)
    $txtFilter.Location    = New-Object System.Drawing.Point(52, 11)
    $txtFilter.BackColor   = $clrInput
    $txtFilter.ForeColor   = $clrFg
    $txtFilter.BorderStyle = "FixedSingle"

    $btnClearFilter = New-Button "✕" 26 24 288 11 $clrGray
    $btnClearFilter.Font = $fontUI

    $btnLoadUsers = New-Button "Load Users" 110 26 324 9 $clrBlue
    $btnLoadUsers.Enabled = $false
    $Script:BtnLoadUsers  = $btnLoadUsers

    $btnLoadSOA = New-Button "Refresh SOA State" 140 26 442 9 $clrGray
    $btnLoadSOA.Enabled = $false
    $Script:BtnLoadSOA  = $btnLoadSOA

    $sep = New-Object System.Windows.Forms.Label
    $sep.Text      = "|"
    $sep.ForeColor = $clrGray
    $sep.AutoSize  = $true
    $sep.Location  = New-Object System.Drawing.Point(594, 14)

    $btnSelectAll = New-Button "Select All" 90 26 608 9 $clrGray
    $btnClearSel  = New-Button "Clear" 70 26 706 9 $clrGray

    $lblSelInfo = New-Object System.Windows.Forms.Label
    $lblSelInfo.Text      = "0 selected"
    $lblSelInfo.ForeColor = $clrFg
    $lblSelInfo.AutoSize  = $true
    $lblSelInfo.Location  = New-Object System.Drawing.Point(790, 14)
    $Script:LblSelectionInfo = $lblSelInfo

    $panToolbar.Controls.AddRange(@(
        $lblFilter, $txtFilter, $btnClearFilter,
        $btnLoadUsers, $btnLoadSOA, $sep,
        $btnSelectAll, $btnClearSel, $lblSelInfo
    ))

    # ══════════════════════════════════════════════════════════════════════════
    #  SPLIT CONTAINER – Users (top) + Log (bottom)
    # ══════════════════════════════════════════════════════════════════════════
    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock             = "Fill"
    $split.Orientation      = "Horizontal"
    $split.SplitterDistance = 480
    $split.SplitterWidth    = 5
    $split.BackColor        = [System.Drawing.Color]::FromArgb(50, 50, 56)
    $split.Panel1MinSize    = 150
    $split.Panel2MinSize    = 120

    # ── DataGridView ──────────────────────────────────────────────────────────
    $dgv = New-Object System.Windows.Forms.DataGridView
    $dgv.Dock                              = "Fill"
    $dgv.SelectionMode                     = "FullRowSelect"
    $dgv.MultiSelect                       = $true
    $dgv.AllowUserToAddRows                = $false
    $dgv.AllowUserToDeleteRows             = $false
    $dgv.ReadOnly                          = $true
    $dgv.RowHeadersVisible                 = $false
    $dgv.AutoSizeRowsMode                  = "None"
    $dgv.ColumnHeadersHeightSizeMode       = "DisableResizing"
    $dgv.ColumnHeadersHeight               = 30
    $dgv.RowTemplate.Height                = 22
    $dgv.BackgroundColor                   = [System.Drawing.Color]::FromArgb(24, 24, 26)
    $dgv.GridColor                         = [System.Drawing.Color]::FromArgb(48, 48, 54)
    $dgv.BorderStyle                       = "None"
    $dgv.CellBorderStyle                   = "SingleHorizontal"
    $dgv.EnableHeadersVisualStyles         = $false
    $dgv.DefaultCellStyle.BackColor        = [System.Drawing.Color]::FromArgb(24, 24, 26)
    $dgv.DefaultCellStyle.ForeColor        = $clrFg
    $dgv.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(0, 80, 160)
    $dgv.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
    $dgv.DefaultCellStyle.Font             = $fontUI
    $dgv.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 34)
    $dgv.ColumnHeadersDefaultCellStyle.BackColor   = [System.Drawing.Color]::FromArgb(42, 42, 48)
    $dgv.ColumnHeadersDefaultCellStyle.ForeColor   = $clrFg
    $dgv.ColumnHeadersDefaultCellStyle.Font        = $fontBold
    $Script:DgvUsers = $dgv

    # Columns
    $colDefs = @(
        @{ Name="colDisplayName";    Header="Display Name";      Width=200; Fill=$false },
        @{ Name="colUPN";            Header="User Principal Name"; Width=0;  Fill=$true  },
        @{ Name="colIsCloudManaged"; Header="isCloudManaged";    Width=125; Fill=$false },
        @{ Name="colSOAState";       Header="SOA State";         Width=145; Fill=$false },
        @{ Name="colAccountEnabled"; Header="Account Enabled";   Width=120; Fill=$false },
        @{ Name="colUserType";       Header="User Type";         Width=90;  Fill=$false },
        @{ Name="colLastUpdated";    Header="Last Updated";      Width=165; Fill=$false }
    )

    foreach ($cd in $colDefs) {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name       = $cd.Name
        $col.HeaderText = $cd.Header
        $col.ReadOnly   = $true
        $col.SortMode   = [System.Windows.Forms.DataGridViewColumnSortMode]::Automatic
        if ($cd.Fill) {
            $col.AutoSizeMode = [System.Windows.Forms.DataGridViewAutoSizeColumnMode]::Fill
        }
        else {
            $col.Width = $cd.Width
        }
        $dgv.Columns.Add($col) | Out-Null
    }

    # ── Action Buttons Panel (bottom of Panel1) ───────────────────────────────
    $panActions = New-Object System.Windows.Forms.Panel
    $panActions.Dock      = "Bottom"
    $panActions.Height    = 46
    $panActions.BackColor = $clrToolbar
    $panActions.Padding   = New-Object System.Windows.Forms.Padding(8)

    $btnSetCloud     = New-Button "▲  Set to Cloud (Entra)"     180 28 8   8 $clrGreen  $true
    $btnRevertOnPrem = New-Button "▼  Revert to On-Premises"    180 28 198 8 $clrOrange $true
    $btnExportCSV    = New-Button "Export Results CSV"           150 28 400 8 ([System.Drawing.Color]::FromArgb(60,60,100))

    $lblActionHint = New-Object System.Windows.Forms.Label
    $lblActionHint.Text      = "Select users above, then click an action button"
    $lblActionHint.ForeColor = $clrGray
    $lblActionHint.AutoSize  = $true
    $lblActionHint.Location  = New-Object System.Drawing.Point(564, 16)

    $panActions.Controls.AddRange(@($btnSetCloud, $btnRevertOnPrem, $btnExportCSV, $lblActionHint))

    # Context menu for right-click on grid
    $ctxMenu          = New-Object System.Windows.Forms.ContextMenuStrip
    $ctxMenu.BackColor = $clrPanel
    $ctxMenu.ForeColor = $clrFg
    $ctxMenu.Font      = $fontUI

    $ctxSetCloud     = New-Object System.Windows.Forms.ToolStripMenuItem
    $ctxSetCloud.Text = "▲  Set to Cloud (Entra)"
    $ctxSetCloud.ForeColor = [System.Drawing.Color]::FromArgb(100, 220, 130)

    $ctxRevert = New-Object System.Windows.Forms.ToolStripMenuItem
    $ctxRevert.Text = "▼  Revert to On-Premises"
    $ctxRevert.ForeColor = [System.Drawing.Color]::FromArgb(240, 160, 80)

    $ctxSep = New-Object System.Windows.Forms.ToolStripSeparator

    $ctxRefresh = New-Object System.Windows.Forms.ToolStripMenuItem
    $ctxRefresh.Text = "⟳  Refresh SOA state for selected"

    $ctxCopyUPN = New-Object System.Windows.Forms.ToolStripMenuItem
    $ctxCopyUPN.Text = "Copy UPN to clipboard"

    $ctxMenu.Items.AddRange(@($ctxSetCloud, $ctxRevert, $ctxSep, $ctxRefresh, $ctxCopyUPN))
    $dgv.ContextMenuStrip = $ctxMenu

    $split.Panel1.Controls.Add($dgv)
    $split.Panel1.Controls.Add($panActions)

    # ── Log Panel (Panel2) ────────────────────────────────────────────────────
    $lblLogHeader = New-Object System.Windows.Forms.Label
    $lblLogHeader.Text      = "  Activity Log"
    $lblLogHeader.Dock      = "Top"
    $lblLogHeader.Height    = 24
    $lblLogHeader.BackColor = [System.Drawing.Color]::FromArgb(42, 42, 48)
    $lblLogHeader.ForeColor = $clrAccent
    $lblLogHeader.Font      = $fontBold
    $lblLogHeader.TextAlign = "MiddleLeft"

    $txtLog = New-Object System.Windows.Forms.RichTextBox
    $txtLog.Dock        = "Fill"
    $txtLog.ReadOnly    = $true
    $txtLog.BackColor   = $clrLogBg
    $txtLog.ForeColor   = $clrFg
    $txtLog.Font        = $fontMono
    $txtLog.BorderStyle = "None"
    $txtLog.ScrollBars  = "Vertical"
    $Script:TxtLog      = $txtLog

    $panLogButtons = New-Object System.Windows.Forms.Panel
    $panLogButtons.Dock      = "Bottom"
    $panLogButtons.Height    = 36
    $panLogButtons.BackColor = $clrToolbar
    $panLogButtons.Padding   = New-Object System.Windows.Forms.Padding(6)

    $btnOpenLog  = New-Button "Open Log File" 120 24 8  6 ([System.Drawing.Color]::FromArgb(60,60,100))
    $btnClearLog = New-Button "Clear Log"      90 24 136 6 $clrGray

    $lblLogPath = New-Object System.Windows.Forms.Label
    $lblLogPath.ForeColor = $clrGray
    $lblLogPath.AutoSize  = $true
    $lblLogPath.Location  = New-Object System.Drawing.Point(240, 12)

    $panLogButtons.Controls.AddRange(@($btnOpenLog, $btnClearLog, $lblLogPath))

    $split.Panel2.Controls.Add($txtLog)
    $split.Panel2.Controls.Add($lblLogHeader)
    $split.Panel2.Controls.Add($panLogButtons)

    # ── Status Strip ──────────────────────────────────────────────────────────
    $statusStrip = New-Object System.Windows.Forms.StatusStrip
    $statusStrip.BackColor  = [System.Drawing.Color]::FromArgb(0, 84, 166)
    $statusStrip.SizingGrip = $false

    $statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusLabel.Text      = "Ready  –  Enter Tenant ID and click Connect"
    $statusLabel.ForeColor = [System.Drawing.Color]::White
    $statusLabel.Spring    = $true
    $statusLabel.TextAlign = "MiddleLeft"
    $Script:StatusLabel    = $statusLabel

    $progBar = New-Object System.Windows.Forms.ToolStripProgressBar
    $progBar.Visible = $false
    $progBar.Width   = 220
    $Script:ProgBar  = $progBar

    $statusStrip.Items.AddRange(@($statusLabel, $progBar))

    # ── Assemble Form ─────────────────────────────────────────────────────────
    # Dock.Top panels: first added = topmost
    $form.Controls.Add($panConnect)
    $form.Controls.Add($panToolbar)
    $form.Controls.Add($statusStrip)
    $form.Controls.Add($split)

    # ══════════════════════════════════════════════════════════════════════════
    #  EVENT HANDLERS
    # ══════════════════════════════════════════════════════════════════════════

    # ── Connect ───────────────────────────────────────────────────────────────
    $btnConnect.Add_Click({
        $form.UseWaitCursor = $true
        Set-StatusText "Connecting to Microsoft Graph..."
        $ok = Connect-ToGraph -TenantId $txtTenantId.Text.Trim()
        if ($ok) {
            $ctx = Get-MgContext
            Update-ConnectionUI -Connected $true -Account $ctx.Account
            Set-StatusText "Connected. Click 'Load Users' to load the user list."
        }
        else {
            Update-ConnectionUI -Connected $false
            Set-StatusText "Connection failed – check the log for details."
        }
        $form.UseWaitCursor = $false
    })

    # ── Disconnect ────────────────────────────────────────────────────────────
    $btnDisconnect.Add_Click({
        Disconnect-FromGraph
        $Script:UserData.Clear()
        Refresh-UserGrid
        Update-ConnectionUI -Connected $false
        Set-StatusText "Disconnected."
    })

    # ── WhatIf checkbox ───────────────────────────────────────────────────────
    $chkWhatIf.Add_CheckedChanged({
        $Script:WhatIf = $chkWhatIf.Checked
        $state = if ($Script:WhatIf) { "ENABLED – no changes will be written" } else { "disabled" }
        Log-Warn "WhatIf mode $state"
        Set-StatusText "WhatIf: $state"
    })

    # ── Load Users ────────────────────────────────────────────────────────────
    $btnLoadUsers.Add_Click({
        $form.UseWaitCursor = $true
        $Script:BtnLoadUsers.Enabled = $false
        $Script:BtnLoadSOA.Enabled   = $false
        Set-StatusText "Loading users from Entra ID..."

        $ok = Load-EntraUsers
        if ($ok) {
            Refresh-UserGrid -Filter $txtFilter.Text
            $Script:BtnLoadSOA.Enabled = $true
            Set-StatusText "$($Script:UserData.Count) users loaded.  Click 'Refresh SOA State' to load current SOA values."
        }
        else {
            Set-StatusText "Failed to load users – check the log."
        }
        $Script:BtnLoadUsers.Enabled = $true
        $form.UseWaitCursor = $false
    })

    # ── Refresh SOA State ─────────────────────────────────────────────────────
    $btnLoadSOA.Add_Click({
        if ($Script:UserData.Count -eq 0) {
            Log-Warn "No users loaded. Click 'Load Users' first."
            return
        }
        $form.UseWaitCursor          = $true
        $Script:BtnLoadSOA.Enabled   = $false
        $Script:BtnLoadUsers.Enabled = $false

        Load-SOAState -Users $Script:UserData
        Refresh-UserGrid -Filter $txtFilter.Text

        $Script:BtnLoadSOA.Enabled   = $true
        $Script:BtnLoadUsers.Enabled = $true
        $form.UseWaitCursor          = $false
        Set-StatusText "SOA state refreshed for $($Script:UserData.Count) users."
    })

    # ── Filter (live) ─────────────────────────────────────────────────────────
    $txtFilter.Add_TextChanged({
        Refresh-UserGrid -Filter $txtFilter.Text
    })

    $btnClearFilter.Add_Click({
        $txtFilter.Clear()
        Refresh-UserGrid
    })

    # ── Select All / Clear ────────────────────────────────────────────────────
    $btnSelectAll.Add_Click({
        $Script:DgvUsers.SelectAll()
        $Script:LblSelectionInfo.Text = "$($Script:DgvUsers.SelectedRows.Count) selected"
    })

    $btnClearSel.Add_Click({
        $Script:DgvUsers.ClearSelection()
        $Script:LblSelectionInfo.Text = "0 selected"
    })

    # ── Selection changed ─────────────────────────────────────────────────────
    $dgv.Add_SelectionChanged({
        $n = $Script:DgvUsers.SelectedRows.Count
        $shown = $Script:DgvUsers.RowCount
        $total = $Script:UserData.Count
        $Script:LblSelectionInfo.Text = "$n selected  |  $shown shown  |  $total total"
    })

    # ── Set to Cloud ──────────────────────────────────────────────────────────
    $btnSetCloud.Add_Click({
        Invoke-SOAOperation -TargetIsCloud $true -TxtFilter $txtFilter.Text
    })

    # ── Revert to On-Premises ─────────────────────────────────────────────────
    $btnRevertOnPrem.Add_Click({
        Invoke-SOAOperation -TargetIsCloud $false -TxtFilter $txtFilter.Text
    })

    # ── Context menu – Set to Cloud ───────────────────────────────────────────
    $ctxSetCloud.Add_Click({
        Invoke-SOAOperation -TargetIsCloud $true -TxtFilter $txtFilter.Text
    })

    # ── Context menu – Revert ─────────────────────────────────────────────────
    $ctxRevert.Add_Click({
        Invoke-SOAOperation -TargetIsCloud $false -TxtFilter $txtFilter.Text
    })

    # ── Context menu – Refresh selected ──────────────────────────────────────
    $ctxRefresh.Add_Click({
        $sel = Get-SelectedUserEntries
        if ($sel.Count -eq 0) { Log-Warn "No users selected."; return }
        Log-Section "Refreshing SOA state for $($sel.Count) selected user(s)"
        $form.UseWaitCursor = $true

        $Script:ProgBar.Minimum = 0
        $Script:ProgBar.Maximum = $sel.Count
        $Script:ProgBar.Value   = 0
        $Script:ProgBar.Visible = $true

        $i = 0
        foreach ($u in $sel) {
            $i++
            try {
                $uri  = "https://graph.microsoft.com/beta/users/$($u.ObjectId)" +
                        "/onPremisesSyncBehavior?`$select=id,isCloudManaged"
                $res  = Invoke-MgGraphRequest -Method Get -Uri $uri -ErrorAction Stop
                $icm  = $res.isCloudManaged
                $u.IsCloudManaged = $icm
                $u.SoaState       = if ($icm -eq $true) { "Cloud (Entra)" }
                                     elseif ($icm -eq $false) { "On-Premises" }
                                     else { "Unknown" }
                Log-Info "  Refreshed: $($u.UserPrincipalName)  →  $($u.SoaState)"
            }
            catch {
                Log-Warn "  Failed for $($u.UserPrincipalName): $($_.Exception.Message)"
            }
            $Script:ProgBar.Value = $i
            [System.Windows.Forms.Application]::DoEvents()
        }

        $Script:ProgBar.Visible = $false
        $form.UseWaitCursor = $false
        Refresh-UserGrid -Filter $txtFilter.Text
        Log-Success "Refresh complete for $($sel.Count) user(s)"
    })

    # ── Context menu – Copy UPN ───────────────────────────────────────────────
    $ctxCopyUPN.Add_Click({
        $sel = Get-SelectedUserEntries
        if ($sel.Count -eq 0) { return }
        $upns = $sel | ForEach-Object { $_.UserPrincipalName }
        [System.Windows.Forms.Clipboard]::SetText(($upns -join "`r`n"))
        Log-Info "Copied $($sel.Count) UPN(s) to clipboard"
        Set-StatusText "Copied $($sel.Count) UPN(s) to clipboard"
    })

    # ── Export Results CSV ────────────────────────────────────────────────────
    $btnExportCSV.Add_Click({
        $dlg = New-Object System.Windows.Forms.SaveFileDialog
        $dlg.Title            = "Export Grid as CSV"
        $dlg.Filter           = "CSV files (*.csv)|*.csv|All files (*.*)|*.*"
        $dlg.FileName         = "SOA-Export-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
        $dlg.InitialDirectory = (Get-Location).Path

        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            try {
                $rows = foreach ($u in $Script:UserData) {
                    [PSCustomObject]@{
                        DisplayName       = $u.DisplayName
                        UserPrincipalName = $u.UserPrincipalName
                        ObjectId          = $u.ObjectId
                        IsCloudManaged    = $u.IsCloudManaged
                        SOAState          = $u.SoaState
                        AccountEnabled    = $u.AccountEnabled
                        UserType          = $u.UserType
                        LastUpdated       = $u.LastUpdated
                    }
                }
                $rows | Export-Csv -Path $dlg.FileName -NoTypeInformation -Encoding UTF8 -Delimiter ";"
                Log-Success "Exported $($Script:UserData.Count) users to: $($dlg.FileName)"
                Set-StatusText "Exported to: $($dlg.FileName)"
            }
            catch {
                Log-Error "Export failed: $($_.Exception.Message)"
            }
        }
    })

    # ── Export Results (action log) to CSV ───────────────────────────────────
    # (accessible from btnExportCSV – additional option via second click-path
    #  if the user holds Shift. For simplicity, the button exports the grid.
    #  Action results are in $Script:Results and always written to the log file.)

    # ── Open Log File ─────────────────────────────────────────────────────────
    $btnOpenLog.Add_Click({
        if ($Script:LogFile -and (Test-Path $Script:LogFile)) {
            Start-Process notepad.exe -ArgumentList $Script:LogFile
        }
        else {
            Log-Warn "Log file not found: $($Script:LogFile)"
        }
    })

    # ── Clear Log Panel ───────────────────────────────────────────────────────
    $btnClearLog.Add_Click({
        $Script:TxtLog.Clear()
        Log-Info "Log panel cleared. Full log is still saved to: $($Script:LogFile)"
    })

    # ── Form Closing ──────────────────────────────────────────────────────────
    $form.Add_FormClosing({
        param($s, $e)
        Log-Info "Application closing."
        Disconnect-FromGraph
        Write-LogFile "Session ended." "INFO"
    })

    # ── Set log path label ────────────────────────────────────────────────────
    $lblLogPath.Text = "Log: $($Script:LogFile)"

    return $form
}

# ─────────────────────────────────────────────────────────────────────────────
#  MAIN ENTRY POINT
# ─────────────────────────────────────────────────────────────────────────────
Initialize-Logging

$mainForm = New-MainForm

# Bootstrap log messages (TxtLog is now wired)
Log-Section $Script:AppTitle
Log-Info    "Version  : $($Script:AppVersion)  |  Updated: $($Script:AppUpdated)"
Log-Info    "Log file : $($Script:LogFile)"
Log-Info    "Enter your Azure Tenant ID (GUID) in the field above and click Connect."
Log-Info    "Required modules : Microsoft.Graph.Authentication, Microsoft.Graph.Users"
Log-Warn    "Requires Graph permissions : User.Read.All  +  User-OnPremisesSyncBehavior.ReadWrite.All"
Log-Section "Ready"

Update-ConnectionUI -Connected $false
Set-StatusText "Ready  –  Enter Tenant ID and click Connect"

[System.Windows.Forms.Application]::Run($mainForm)
