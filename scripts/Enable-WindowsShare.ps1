#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$DataDirectory,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,19}$')]
    [string]$ShareUserName = 'projectdrive-smb',
    [string]$ExplorerDirectory,
    [string]$LanInterface,
    [string]$MacLanIp,
    [string]$TrustedLanName,
    [string]$MacTailnetIp,
    [string]$TailnetInterface = 'Tailscale',
    [switch]$CloudStorageAliasOnly,
    [Security.Principal.SecurityIdentifier]$LocalOperatorSid =
        [Security.Principal.WindowsIdentity]::GetCurrent().User
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$shareName = 'Cloud Storage'
$legacyShareName = 'ProjectDrive'
$localUser = $ShareUserName
$marker = 'Project Drive revision 3 dedicated SMB access'
$ruleNames = @('ProjectDrive-SMB-LAN', 'ProjectDrive-SMB-Tailnet')
$guardName = 'ProjectDrive-SMB-Setup-Block'
$windowsSharingGroup = '@FirewallAPI.dll,-28502'

function Get-LocalFolder([string]$Path) {
    if ($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path.Substring(2).Contains(':')) {
        throw 'Use an absolute folder path on a local drive.'
    }
    $fullPath = [IO.Path]::GetFullPath($Path) -replace '[\\/]+$', ''
    if ($fullPath -match '^[A-Za-z]:$') { throw 'Choose a folder below the drive root.' }
    for ($parent = [IO.Directory]::GetParent($fullPath); $parent; $parent = $parent.Parent) {
        $entry = Get-Item -LiteralPath $parent.FullName -Force -ErrorAction SilentlyContinue
        if ($entry -and (-not $entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
            throw "The folder's parent $($parent.FullName) must be an ordinary directory."
        }
    }
    return $fullPath
}

function Get-IPv4Bytes([string]$Address) {
    $parsed = $null
    if ($Address -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or
        -not [Net.IPAddress]::TryParse($Address, [ref]$parsed) -or
        $parsed.ToString() -ne $Address) {
        throw "Use a single canonical IPv4 address. Received '$Address'."
    }
    $parsed.GetAddressBytes()
}

function Test-Subnet([byte[]]$First, [byte[]]$Second, [int]$Length) {
    $wholeBytes = [int][Math]::Floor($Length / 8)
    for ($offset = 0; $offset -lt $wholeBytes; $offset++) {
        if ($First[$offset] -ne $Second[$offset]) { return $false }
    }
    $extraBits = $Length % 8
    if ($extraBits -eq 0) { return $true }
    $mask = (255 -shl (8 - $extraBits)) -band 255
    return ($First[$wholeBytes] -band $mask) -eq ($Second[$wholeBytes] -band $mask)
}

function Assert-NoOtherSmbAllowRules {
    foreach ($rule in Get-NetFirewallRule -PolicyStore ActiveStore -Enabled True -Direction Inbound -Action Allow) {
        if ($rule.Name -in $ruleNames -and $rule.Description -eq $marker) { continue }
        $port = $rule | Get-NetFirewallPortFilter
        # The raw CIM value includes transport predicates that DynamicTarget can omit.
        # Wi-Fi Direct and Teredo rules do not match direct IPv4 TCP connections.
        $transport = $port.CimInstanceProperties['DynamicTransport']
        if ($transport -and [uint32]$transport.Value -ne 0) { continue }
        if ($port.Protocol -notin @('TCP', '6', 'Any', '256')) { continue }
        $application = $rule | Get-NetFirewallApplicationFilter
        # The kernel SMB server has no app package identity.
        if ($application.Package -and $application.Package -ne 'Any') { continue }
        $program = $application.Program
        $service = ($rule | Get-NetFirewallServiceFilter).Service
        if (($service -notin @('Any', 'LanmanServer')) -or
            ($program -notin @('Any', 'System') -and $service -ne 'LanmanServer')) { continue }
        foreach ($entry in $port.LocalPort) {
            $includesSmb = $entry -in @('Any', '139', '445')
            if ($entry -match '^(\d+)-(\d+)$') {
                $first = [int]$Matches[1]
                $last = [int]$Matches[2]
                $includesSmb = ($first -le 139 -and $last -ge 139) -or ($first -le 445 -and $last -ge 445)
            }
            if ($includesSmb) {
                throw "Enabled rule '$($rule.DisplayName)' also allows SMB. Review it before enabling this share."
            }
        }
    }
}

function Assert-ShareAccess([string]$Name, [string]$ShareUser, [string]$Administrators) {
    $entries = @(Get-SmbShareAccess -Name $Name)
    if ($entries.Count -ne 2 -or
        ($entries | Where-Object AccessControlType -ne 'Allow') -or
        -not ($entries | Where-Object { $_.AccountName -eq $ShareUser -and $_.AccessRight -eq 'Change' }) -or
        -not ($entries | Where-Object { $_.AccountName -eq $Administrators -and $_.AccessRight -eq 'Full' })) {
        throw "The $Name share access differs from the expected account and administrator grants."
    }
}

function Assert-ScopedFirewallRule($Scope) {
    $effective = @(Get-NetFirewallRule -Name $Scope.Name -PolicyStore ActiveStore)
    if ($effective.Count -ne 1 -or $effective[0].Enabled -ne 'True' -or
        $effective[0].Description -ne $marker -or $effective[0].Action -ne 'Allow' -or
        $effective[0].Direction -ne 'Inbound' -or $effective[0].Profile -ne $Scope.Profile) {
        throw "The active firewall rule differs from the expected policy for $($Scope.Name)."
    }
    $addresses = $effective | Get-NetFirewallAddressFilter
    $localAddress = @($addresses.LocalAddress -replace '/32$|/255\.255\.255\.255$', '')
    $remoteAddress = @($addresses.RemoteAddress -replace '/32$|/255\.255\.255\.255$', '')
    $interfaces = @(($effective | Get-NetFirewallInterfaceFilter).InterfaceAlias)
    $port = $effective | Get-NetFirewallPortFilter
    if ($localAddress.Count -ne 1 -or $localAddress[0] -ne $Scope.LocalAddress -or
        $remoteAddress.Count -ne 1 -or $remoteAddress[0] -ne $Scope.RemoteAddress -or
        $interfaces.Count -ne 1 -or $interfaces[0] -ne $Scope.InterfaceAlias -or
        $port.Protocol -ne 'TCP' -or @($port.LocalPort).Count -ne 1 -or $port.LocalPort -ne '445') {
        throw "The active firewall rule has an unexpected network scope for $($Scope.Name)."
    }
}

if ([bool]$LanInterface -ne [bool]$MacLanIp -or (-not $MacLanIp -and -not $MacTailnetIp)) {
    throw 'Supply both -LanInterface and -MacLanIp, a verified -MacTailnetIp, or both routes.'
}
if ($TrustedLanName -and -not $LanInterface) { throw 'Supply -LanInterface with -TrustedLanName.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script in an administrator Windows PowerShell session.'
}

$sharePath = Get-LocalFolder $DataDirectory
$explorerPath = if ($ExplorerDirectory) { Get-LocalFolder $ExplorerDirectory }
if ($explorerPath -eq $sharePath) { $explorerPath = $null }
$rules = @()
$lanToTrust = $null
if ($MacLanIp) {
    $mac = Get-IPv4Bytes $MacLanIp
    $privateMac = $mac[0] -eq 10 -or ($mac[0] -eq 172 -and $mac[1] -in (16..31)) -or
        ($mac[0] -eq 192 -and $mac[1] -eq 168)
    if (-not $privateMac) { throw 'The Mac LAN address must belong to a private IPv4 range.' }
    $connection = Get-NetConnectionProfile -InterfaceAlias $LanInterface
    if ($TrustedLanName -and $connection.Name -cne $TrustedLanName) {
        throw 'The selected connection differs from the approved trusted LAN.'
    }
    if ($connection.NetworkCategory -ne 'Private') {
        if (-not $TrustedLanName -or $connection.NetworkCategory -ne 'Public') {
            throw 'The selected LAN must be a trusted Private network.'
        }
        $lanToTrust = $connection
    }
    $local = @(Get-NetIPAddress -InterfaceIndex $connection.InterfaceIndex -AddressFamily IPv4 |
        Where-Object {
            $_.AddressState -eq 'Preferred' -and $_.IPAddress -ne $MacLanIp -and
            (Test-Subnet (Get-IPv4Bytes $_.IPAddress) $mac $_.PrefixLength)
        })
    if ($local.Count -ne 1) { throw 'The Mac must belong to one active IPv4 subnet on the selected LAN.' }
    $rules += @{
        Name = $ruleNames[0]; InterfaceAlias = $connection.InterfaceAlias; Profile = 'Private'
        LocalAddress = $local[0].IPAddress; RemoteAddress = $MacLanIp
    }
}
if ($MacTailnetIp) {
    $mac = Get-IPv4Bytes $MacTailnetIp
    $adapter = Get-NetAdapter -Name $TailnetInterface
    if ((-not (Test-Subnet $mac @(100, 64, 0, 0) 10)) -or
        $adapter.InterfaceDescription -notmatch 'Tailscale' -or $adapter.Status -ne 'Up') {
        throw 'Use the approved Mac Tailscale IPv4 address and an active Tailscale adapter.'
    }
    $local = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 |
        Where-Object {
            $_.IPAddress -ne $MacTailnetIp -and
            (Test-Subnet (Get-IPv4Bytes $_.IPAddress) @(100, 64, 0, 0) 10)
        })
    if ($local.Count -ne 1) { throw 'The Tailscale adapter needs one active tailnet IPv4 address.' }
    $rules += @{
        Name = $ruleNames[1]; InterfaceAlias = $adapter.Name; Profile = 'Any'
        LocalAddress = $local[0].IPAddress; RemoteAddress = $MacTailnetIp
    }
}

$volume = Get-Volume -DriveLetter ([char]$sharePath[0])
if ($volume.FileSystem -ne 'NTFS' -or $volume.DriveType -notin @('Fixed', 'Removable')) {
    throw 'Use an internal or external local NTFS drive for shared files.'
}
$smb = Get-SmbServerConfiguration
if ($smb.EnableSMB1Protocol -or -not $smb.EnableSMB2Protocol -or -not $smb.RejectUnencryptedAccess) {
    throw 'The Windows server must use SMB2/3 and reject unencrypted access to encrypted shares.'
}
foreach ($profile in Get-NetFirewallProfile -PolicyStore ActiveStore) {
    if ($profile.Enabled -ne 'True' -or $profile.DefaultInboundAction -ne 'Block') {
        throw "Windows Firewall must be enabled with default inbound blocking on $($profile.Name)."
    }
}
Assert-NoOtherSmbAllowRules

$share = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
$legacyShare = Get-SmbShare -Name $legacyShareName -ErrorAction SilentlyContinue
if ($legacyShare -and ($legacyShare.Path -ne $sharePath -or $legacyShare.Description -ne $marker)) {
    $legacyShare = $null
}
$user = Get-LocalUser -Name $localUser -ErrorAction SilentlyContinue
$folder = Get-Item -LiteralPath $sharePath -Force -ErrorAction SilentlyContinue
$explorerFolder = if ($explorerPath) {
    Get-Item -LiteralPath $explorerPath -Force -ErrorAction SilentlyContinue
}
if ($share -and ($share.Path -ne $sharePath -or $share.Description -ne $marker)) {
    throw "A different share already uses $shareName."
}
if ($user -and $user.Description -ne $marker) { throw "A different account already uses $localUser." }
if ($folder -and (-not $folder.PSIsContainer -or ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
    throw "$sharePath must be an ordinary directory."
}
if ($folder -and -not ($share -or $legacyShare) -and
    (Get-ChildItem -LiteralPath $sharePath -Force | Select-Object -First 1)) {
    throw "A populated unshared directory already exists at $sharePath. Review its ownership before reuse."
}
if ($explorerFolder -and ($explorerFolder.LinkType -ne 'Junction' -or @($explorerFolder.Target) -notcontains $sharePath)) {
    throw "Another item is already using $explorerPath."
}
$existingRules = @(Get-NetFirewallRule -Name $ruleNames -PolicyStore PersistentStore -ErrorAction SilentlyContinue)
if ($existingRules | Where-Object Description -ne $marker) { throw 'A firewall rule name is already in use.' }
$setupGuard = Get-NetFirewallRule -Name $guardName -PolicyStore PersistentStore -ErrorAction SilentlyContinue
if ($setupGuard -and ($setupGuard.Description -ne $marker -or $setupGuard.Action -ne 'Block')) {
    throw 'The temporary Project Drive firewall rule name is already in use.'
}

$admin = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
$admins = $admin.Translate([Security.Principal.NTAccount]).Value
$smbUser = "$env:COMPUTERNAME\$localUser"
if ($CloudStorageAliasOnly) {
    if ($lanToTrust -or -not $folder -or -not $user -or -not ($share -or $legacyShare)) {
        throw 'Publishing the friendly name requires an existing secured Project Drive share and active network profile.'
    }
    foreach ($scope in $rules) { Assert-ScopedFirewallRule $scope }
}
if ($legacyShare) {
    if (-not $legacyShare.EncryptData -or $legacyShare.CachingMode -ne 'None') {
        throw 'The original ProjectDrive share needs encryption and caching review before adding Cloud Storage.'
    }
    Assert-ShareAccess $legacyShareName $smbUser $admins
}

$operation = 'Configure the private, encrypted SMB share'
if ($CloudStorageAliasOnly) { $operation = 'Publish Cloud Storage for the existing encrypted SMB share' }
if ($lanToTrust) { $operation += " and mark $TrustedLanName Private" }
if (-not $PSCmdlet.ShouldProcess($sharePath, $operation)) { return }
if (-not $user) {
    $password = $null
    $generatedPassword = $null
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $password = Read-Host "Set the $localUser password (16+ characters), or press Enter to generate one" -AsSecureString
        if ($password.Length -eq 0) {
            $password.Dispose()
            $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
            try {
                $bytes = [byte[]]::new(24)
                $generator.GetBytes($bytes)
                $generatedPassword = [Convert]::ToBase64String($bytes) + 'a7!'
            } finally {
                $generator.Dispose()
            }
            $password = ConvertTo-SecureString $generatedPassword -AsPlainText -Force
            break
        }
        if ($password.Length -ge 16) { break }
        $password.Dispose()
        $password = $null
        Write-Warning 'Use a unique passphrase of at least 16 characters, or press Enter to generate one.'
    }
    if (-not $password) { throw 'The share account needs a password to continue.' }
    try {
        $user = New-LocalUser -Name $localUser -Password $password -Description $marker
        if ($generatedPassword) {
            Write-Host 'Save this generated share password in your password manager now.'
            Write-Host $generatedPassword
        }
    } finally {
        $password.Dispose()
        $generatedPassword = $null
    }
}
if (-not $user.Enabled) { throw "The $localUser account is disabled. Review it before re-enabling." }
if (-not $folder) { New-Item -Path $sharePath -ItemType Directory | Out-Null }
if (-not $CloudStorageAliasOnly -and -not $legacyShare) {
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $acl = Get-Acl -LiteralPath $sharePath
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($existing in $acl.Access) { $acl.RemoveAccessRuleSpecific($existing) }
    foreach ($sid in (@($system, $admin, $LocalOperatorSid, $user.SID) | Select-Object -Unique)) {
        $rights = if ($sid -in @($system, $admin)) { 'FullControl' } else { 'Modify' }
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid, $rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    $acl.SetOwner($admin)
    Set-Acl -LiteralPath $sharePath -AclObject $acl
}
if ($explorerPath -and -not $explorerFolder) {
    New-Item -Path $explorerPath -ItemType Junction -Target $sharePath | Out-Null
}

if (-not $share -or -not $share.EncryptData -or $share.CachingMode -ne 'None') {
    $sharingFilter = @{
        PolicyStore = 'PersistentStore'; Group = $windowsSharingGroup; Direction = 'Inbound'; Enabled = 'True'
    }
    $sharingRulesBefore = @(Get-NetFirewallRule @sharingFilter -ErrorAction SilentlyContinue | ForEach-Object Name)
    # Creating the first share can enable Windows' broader File and Printer Sharing group.
    if (-not $setupGuard) {
        $guardOptions = @{
            Name = $guardName; DisplayName = $guardName; Description = $marker; Direction = 'Inbound'
            Action = 'Block'; Protocol = 'TCP'; LocalPort = @(139, 445); Program = 'System'
        }
        $setupGuard = New-NetFirewallRule @guardOptions
    }
    $activeGuard = Get-NetFirewallRule -Name $guardName -PolicyStore ActiveStore
    if ($activeGuard.Enabled -ne 'True' -or $activeGuard.Action -ne 'Block') {
        throw 'The temporary SMB block must be active before creating the share.'
    }
    try {
        if ($share) {
            Set-SmbShare -Name $shareName -CachingMode None -EncryptData $true -Force
        } else {
            $shareOptions = @{
                Name = $shareName; Path = $sharePath; Description = $marker; CachingMode = 'None'
                EncryptData = $true; ChangeAccess = $smbUser; FullAccess = $admins
            }
            New-SmbShare @shareOptions | Out-Null
        }
    } finally {
        Get-NetFirewallRule @sharingFilter -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin $sharingRulesBefore } | Disable-NetFirewallRule
    }
}
Assert-ShareAccess $shareName $smbUser $admins

if ($CloudStorageAliasOnly) {
    Assert-NoOtherSmbAllowRules
    if ($setupGuard) { Remove-NetFirewallRule -Name $guardName -PolicyStore PersistentStore }
    foreach ($scope in $rules) { Assert-ScopedFirewallRule $scope }
    Get-SmbShare -Name $shareName | Select-Object Name, Path, EncryptData, CachingMode
    Write-Host "In Finder, use smb://$($rules[0].LocalAddress)/$([uri]::EscapeDataString($shareName)) and sign in as $smbUser."
    return
}

if ($existingRules) { $existingRules | Remove-NetFirewallRule }
$changedProfile = $false
try {
    foreach ($scope in $rules) {
        $firewallOptions = @{
            DisplayName = $scope.Name; Description = $marker; Direction = 'Inbound'; Action = 'Allow'
            Protocol = 'TCP'; LocalPort = 445; Program = 'System'; EdgeTraversalPolicy = 'Block'
        }
        New-NetFirewallRule @scope @firewallOptions | Out-Null
        Assert-ScopedFirewallRule $scope
    }
    if ($lanToTrust) {
        $current = Get-NetConnectionProfile -InterfaceIndex $lanToTrust.InterfaceIndex
        if ($current.Name -cne $TrustedLanName -or $current.NetworkCategory -ne 'Public') {
            throw 'The network profile changed during setup. Review the active connection before retrying.'
        }
        Set-NetConnectionProfile -InputObject $current -NetworkCategory Private
        $changedProfile = $true
        $current = Get-NetConnectionProfile -InterfaceIndex $lanToTrust.InterfaceIndex
        if ($current.Name -cne $TrustedLanName -or $current.NetworkCategory -ne 'Private') {
            throw 'Windows did not activate the approved Private network profile.'
        }
    }
    Assert-NoOtherSmbAllowRules
    if ($setupGuard) {
        Remove-NetFirewallRule -Name $guardName -PolicyStore PersistentStore
    }
} catch {
    if ($changedProfile) {
        $current = Get-NetConnectionProfile -InterfaceIndex $lanToTrust.InterfaceIndex
        if ($current.Name -ceq $TrustedLanName -and $current.NetworkCategory -eq 'Private') {
            Set-NetConnectionProfile -InputObject $current -NetworkCategory Public
        }
    }
    Get-NetFirewallRule -Name $ruleNames -PolicyStore PersistentStore -ErrorAction SilentlyContinue |
        Where-Object Description -eq $marker | Disable-NetFirewallRule
    throw
}

Get-SmbShare -Name $shareName | Select-Object Name, Path, EncryptData, CachingMode
Write-Host "In Finder, use smb://$($rules[0].LocalAddress)/$([uri]::EscapeDataString($shareName)) and sign in as $smbUser."
