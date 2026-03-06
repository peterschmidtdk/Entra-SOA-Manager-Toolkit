This is a list of lightweight PowerShell tools for managing Entra ID ‘source of authority’ (SOA) scenarios, quickly audit, validate, and correct identity attributes during migrations and hybrid-to-cloud transitions.

# Set-EntraUserSOA-Bulk.ps1

Bulk update Entra ID users’ **Source of Authority (SOA)** by setting **`onPremisesSyncBehavior.isCloudManaged`** using Microsoft Graph.

This script is designed for tenant-to-tenant migrations and Entra cleanup scenarios where you need to convert users from **on-prem managed** to **cloud managed** (or explicitly set either state) at scale.

# Set-EntraGroupSOA-Bulk.ps1
This script is not fully ready for public yet.


---

## What Set-EntraUserSOA-Bulk.ps1 does

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

## CSV file format
Identity,Mode
<user-or-group-objectId-or-displayName-or-mail-or-userprinciplanmae>,

Identity: recommended = Group ObjectId (GUID) or UserPrincipalName.
Also supports displayName (only if it resolves to exactly one group) or mail (group email address).

Mode: optional. If blank/missing → defaults to True (convert to cloud-managed).
Mode values supported are the same as your User script: true/false, enable/disable, cloud/onprem, etc.

### PowerShell Modules
- `Microsoft.Graph.Authentication`
- `Microsoft.Graph.Users`

Install and how to run:
```PowerShell:
Install-Module Microsoft.Graph -Scope CurrentUser

Update the TenantID to match your tenant.

Run the script...
```

## Microsoft documentation (Source of Authority)

This script aligns with Microsoft’s **Source of Authority (SOA)** guidance for transitioning identity management from on-premises AD DS to **Microsoft Entra ID**, by updating **`onPremisesSyncBehavior.isCloudManaged`** through Microsoft Graph (beta). :contentReference[oaicite:1]{index=1}

### User SOA (Users)
- Transfer user Source of Authority (SOA) to the cloud (Overview)  
  https://learn.microsoft.com/en-us/entra/identity/hybrid/user-source-of-authority-overview :contentReference[oaicite:2]{index=2}
- Configure User Source of Authority (SOA) (How-to)  
  https://learn.microsoft.com/en-us/entra/identity/hybrid/how-to-user-source-of-authority-configure :contentReference[oaicite:3]{index=3}

### Group SOA (Groups)
- Convert Group Source of Authority (SOA) to the cloud (Overview)  
  https://learn.microsoft.com/en-us/entra/identity/hybrid/concept-source-of-authority-overview :contentReference[oaicite:4]{index=4}

### Guidance for IT Architects
- Cloud-first identity management: Guidance for IT architects (SOA)  
  https://learn.microsoft.com/en-us/entra/identity/hybrid/guidance-it-architects-source-of-authority :contentReference[oaicite:5]{index=5}

## ⚠️ Important / Disclaimer

This script is provided **as-is**, without warranty.

- **Always test in a non-production (lab) tenant first**
- Review and understand the code before running it
- Start with a small pilot CSV and validate results
- Do **not** run in production until you are confident in the behavior and impact

You are responsible for any changes made by running this script.
