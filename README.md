This is a list of lightweight PowerShell tools for managing Entra ID ‘source of authority’ (SOA) scenarios, quickly audit, validate, and correct identity attributes during migrations and hybrid-to-cloud transitions.

# Change-EntraUserSOA-Bulk.ps1

Bulk update Entra ID users’ **Source of Authority (SOA)** by setting **`onPremisesSyncBehavior.isCloudManaged`** using Microsoft Graph.

This script is designed for tenant-to-tenant migrations and Entra cleanup scenarios where you need to convert users from **on-prem managed** to **cloud managed** (or explicitly set either state) at scale.

---

## What it does

For each row in a CSV file, the script:

1. Looks up the user by **UserPrincipalName (UPN)** using `Get-MgUser` with an OData filter  
2. Reads current **`onPremisesSyncBehavior.isCloudManaged`** (Graph **beta** endpoint)  
3. Determines the target value from **`Mode`** (optional)
   - If `Mode` is **missing/blank**, the script defaults to **`true`**
4. Updates the user with a **PATCH** request  
5. Re-reads the value to **verify** the change  
6. Logs everything to:
   - a timestamped **TXT** log file
   - a timestamped **CSV** results file (semicolon `;` delimited for easy Excel use)

---

## Requirements

### PowerShell Modules
- `Microsoft.Graph.Authentication`
- `Microsoft.Graph.Users`

Install:
```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
