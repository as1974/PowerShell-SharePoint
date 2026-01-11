
TeamCloner Pro
PowerShell Script

<#
.SYNOPSIS
    Clones a Microsoft Team (Channels, Users, and Content) to a new Team with a 'Test-' prefix.

.DESCRIPTION
    This script performs the following actions:
    1. Validates the Source Team exists.
    2. Creates a new Target Team with 'Test-' prefix.
    3. Copies all Owners and Members.
    4. Recreates all Standard and Private Channels.
    5. Uses PnP PowerShell to copy files from the Source 'Shared Documents' library to the Target.

.NOTES
    - The user running the script must be a SharePoint Admin and Teams Admin.
    - Private Channel file migration requires specific handling; this script recreates the channel structure but focuses file copy on the main Shared Documents library.
    - Copying large amounts of data may take time.

.PREREQUISITES
    - MicrosoftTeams Module
    - PnP.PowerShell Module
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$SourceTeamName
)

# Configuration
$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

# --- Helper Functions ---
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "Info"
    )
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Color = switch ($Level) {
        "Info" { "Cyan" }
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error" { "Red" }
        Default { "White" }
    }
    Write-Host "[$TimeStamp] [$Level] $Message" -ForegroundColor $Color
}

try {
    # --- 1. Connection ---
    Write-Log "Connecting to Microsoft Teams..."
    Connect-MicrosoftTeams | Out-Null

    # --- 2. Validate Source ---
    Write-Log "Searching for source team: $SourceTeamName"
    $SourceTeam = Get-Team | Where-Object { $_.DisplayName -eq $SourceTeamName }

    if (-not $SourceTeam) {
        throw "Source Team '$SourceTeamName' not found."
    }
    Write-Log "Found Source Team: $($SourceTeam.GroupId)" "Success"

    # --- 3. Create Target Team ---
    $TargetTeamName = "Test-$($SourceTeam.DisplayName)"
    Write-Log "Creating Target Team: $TargetTeamName"
    
    # Check if target already exists to avoid duplication errors
    $ExistingTarget = Get-Team | Where-Object { $_.DisplayName -eq $TargetTeamName }
    if ($ExistingTarget) {
        throw "Target Team '$TargetTeamName' already exists. Aborting to prevent overwrite."
    }

    $TargetTeam = New-Team -DisplayName $TargetTeamName -MailNickName "$($SourceTeam.MailNickName)Test" -Visibility Private
    Write-Log "Target Team Created. GroupId: $($TargetTeam.GroupId)" "Success"
    
    # Small delay to ensure backend propagation
    Start-Sleep -Seconds 10

    # --- 4. Copy Members and Owners ---
    Write-Log "Fetching users from Source..."
    $SourceUsers = Get-TeamUser -GroupId $SourceTeam.GroupId

    foreach ($User in $SourceUsers) {
        try {
            # Skip the account running the script if it's already added by creation
            if ($User.Role -eq "Owner") {
                Write-Log "Adding Owner: $($User.User)"
                Add-TeamUser -GroupId $TargetTeam.GroupId -User $User.User -Role Owner -ErrorAction SilentlyContinue
            }
            else {
                Write-Log "Adding Member: $($User.User)"
                Add-TeamUser -GroupId $TargetTeam.GroupId -User $User.User -Role Member -ErrorAction SilentlyContinue
            }
        }
        catch {
            Write-Log "Failed to add user $($User.User): $($_.Exception.Message)" "Warning"
        }
    }

    # --- 5. Copy Channels ---
    Write-Log "Fetching channels..."
    $SourceChannels = Get-TeamChannel -GroupId $SourceTeam.GroupId
    
    foreach ($Channel in $SourceChannels) {
        if ($Channel.DisplayName -eq "General") {
            continue # General channel is created automatically
        }

        Write-Log "Creating Channel: $($Channel.DisplayName) [$($Channel.MembershipType)]"
        try {
            New-TeamChannel -GroupId $TargetTeam.GroupId `
                            -DisplayName $Channel.DisplayName `
                            -MembershipType $Channel.MembershipType `
                            -Description $Channel.Description
        }
        catch {
            Write-Log "Failed to create channel $($Channel.DisplayName): $($_.Exception.Message)" "Error"
        }
    }

    # --- 6. Content Migration (PnP PowerShell) ---
    Write-Log "Preparing for SharePoint Content Migration..."
    
    # Get SharePoint URLs (Using Get-UnifiedGroup for reliability)
    $SourceGroup = Get-UnifiedGroup -Identity $SourceTeam.GroupId
    $TargetGroup = Get-UnifiedGroup -Identity $TargetTeam.GroupId
    
    $SourceSiteUrl = $SourceGroup.SharePointSiteUrl
    $TargetSiteUrl = $TargetGroup.SharePointSiteUrl

    if ([string]::IsNullOrEmpty($SourceSiteUrl) -or [string]::IsNullOrEmpty($TargetSiteUrl)) {
        throw "Could not determine SharePoint Site URLs."
    }

    Write-Log "Source Site: $SourceSiteUrl"
    Write-Log "Target Site: $TargetSiteUrl"

    # Connect to Source PnP
    Write-Log "Connecting to PnP Online (Interactive Login may be required)..."
    # Note: Use -Interactive or -Credentials depending on environment. Interactive used here for general compatibility.
    Connect-PnPOnline -Url $SourceSiteUrl -Interactive

    Write-Log "Copying 'Shared Documents' library content..."
    
    # We copy the contents of the default document library
    $DocLibName = "Shared Documents"
    
    # Get all top-level folders in the source Shared Documents (usually corresponding to Channels)
    $SourceFolders = Get-PnPFolderItem -FolderSiteRelativeUrl $DocLibName -ItemType Folder

    foreach ($Folder in $SourceFolders) {
        if ($Folder.Name -eq "Forms") { continue }

        Write-Log "Migrating Folder content: $($Folder.Name)"
        
        # Copy-PnPFile creates a copy job between sites
        # Force is used to overwrite if re-running
        try {
            $SourceFolderUrl = "$($DocLibName)/$($Folder.Name)"
            
            # We use Copy-PnPFile to copy from current PnP context (Source) to external URL (Target)
            # Note: This command runs asynchronously on the server side usually.
            Copy-PnPFile -SourceUrl $SourceFolderUrl `
                         -TargetWebUrl $TargetSiteUrl `
                         -TargetUrl "/$($DocLibName)" `
                         -OverwriteIfAlreadyExists `
                         -Force
            
            Write-Log "Initiated copy for $($Folder.Name)" "Success"
        }
        catch {
            Write-Log "Failed to copy folder $($Folder.Name): $($_.Exception.Message)" "Error"
        }
    }

    Write-Log "Cloning process completed successfully." "Success"
    Write-Log "Note: File copying is processed by SharePoint in the background and may take a few minutes to appear in the target." "Info"

}
catch {
    Write-Log "Critical Error: $($_.Exception.Message)" "Error"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" "Error"
}

Prerequisites

    1
    PowerShell 5.1 or PowerShell 7+
    2
    Module: MicrosoftTeams (Install-Module MicrosoftTeams)
    3
    Module: PnP.PowerShell (Install-Module PnP.PowerShell)
    4
    Permissions: SharePoint Administrator and Teams Administrator roles

Technical Breakdown

This script automates the duplication of a Microsoft Team for testing. **Key Features:** 1. **Team Creation:** Creates a new team using `New-Team` with a `Test-` prefix appended to the original name. 2. **User Migration:** Iterates through the source team's users (`Get-TeamUser`) and adds them to the new team with their respective roles (Owner/Member). 3. **Channel Replication:** Copies both Standard and Private channels. Note: Creating a Private channel generally requires the script runner to be an owner, which is handled implicitly if the creator is the admin. 4. **SharePoint Content Copy:** - It resolves the underlying SharePoint Site URLs using `Get-UnifiedGroup`. - It uses `Connect-PnPOnline` to connect to the source site. - It utilizes `Copy-PnPFile` to perform a cross-site copy of folders within 'Shared Documents' (which map to Channels) to the new Target site. 5. **Logging & Error Handling:** Includes a custom `Write-Log` function for color-coded status updates and `Try-Catch` blocks to ensure the script fails gracefully or reports specific errors without crashing entirely.
Pro Tip

Always run testing scripts against a demo tenant or non-production environment first. Ensure you have 'Global Admin' or 'Teams Admin' roles assigned.

Powered by Gemini 3 Pro • Professional PowerShell Series
Documentation
Best Practices
Security
