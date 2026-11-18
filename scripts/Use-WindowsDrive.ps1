#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('Mount','Status','Unmount','SavePassword')]
    [string]$Action,
    [string]$Config = "$PSScriptRoot/../config/windows.local.json",
    [ValidatePattern('^[D-Zd-z]:$')]
    [string]$Drive = 'P:'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Drive = $Drive.ToUpperInvariant()
$root = Join-Path $env:LOCALAPPDATA 'ProjectDrive'
$state = Join-Path $root "mount-$($Drive[0]).json"
$driveRoot = "$Drive\"
$juicefs = if ($Action -in @('Mount','Unmount')) {
    (Get-Command juicefs.exe -CommandType Application).Source
}

function Test-DrivePresent {
    return [IO.DriveInfo]::GetDrives().Name -contains $driveRoot
}

function Get-ManagedProcess {
    if (-not (Test-Path -LiteralPath $state -PathType Leaf)) { return }
    $record = Get-Content -LiteralPath $state -Raw | ConvertFrom-Json
    $process = Get-Process -Id $record.processId -ErrorAction SilentlyContinue
    if ($process -and $process.ProcessName -eq 'juicefs' -and
        $process.StartTime.ToUniversalTime().Ticks -eq $record.started) {
        return $process
    }
}

function Assert-IndexReachable([string]$IndexHost) {
    $tcp = [Net.Sockets.TcpClient]::new()
    try {
        if ($tcp.ConnectAsync($IndexHost, 55432).Wait([TimeSpan]::FromSeconds(5)) -and $tcp.Connected) {
            return
        }
    } catch {
        Write-Verbose $_.Exception.Message
    } finally {
        $tcp.Dispose()
    }
    throw "Index unavailable at ${IndexHost}:55432. Check host wake state, PostgreSQL and Tailscale."
}

New-Item -Path $root -ItemType Directory -Force | Out-Null
$lock = [IO.File]::Open("$state.lock", 'OpenOrCreate', 'ReadWrite', 'None')
try {
    $managed = Get-ManagedProcess
    $present = Test-DrivePresent
    if ($present -and -not $managed) {
        throw "Drive $Drive is already in use by a mount this script does not own. Choose another drive letter."
    }
    if ($Action -eq 'Unmount') {
        if (-not $present) {
            if ($managed) { throw 'The mount process is still running without a drive. See the client log.' }
            Write-Output "Project Drive $Drive is disconnected."
            return
        }
        & $juicefs umount $Drive
        if ($LASTEXITCODE -ne 0 -or -not $managed.WaitForExit(8000)) {
            throw 'Unmount did not complete. Close open files and retry before reconnecting.'
        }
        Remove-Item -LiteralPath $state
        Write-Output "Project Drive $Drive disconnected."
        return
    }

    $python = (Get-Command python.exe -CommandType Application).Source
    $cloud = Join-Path $PSScriptRoot '../tools/cloud.py'
    $configArguments = @('--config', $Config, '--device', 'windows')
    $settings = & $python $cloud client-settings @configArguments
    if ($LASTEXITCODE -ne 0) { throw 'Read the Windows client configuration error above.' }
    $profile, $role, $bucketEndpoint, $indexHost, $region, $bucketName = $settings -split "`t"
    $macUid = (Get-Content -LiteralPath $Config -Raw | ConvertFrom-Json).mac_uid
    if ($macUid -isnot [long] -or $macUid -lt 1 -or $macUid -gt [int]::MaxValue) {
        throw 'Set mac_uid in the Windows config to the number printed by id -u on the Mac.'
    }
    $passwordPath = Join-Path $root "postgres-$indexHost.xml"
    if ($Action -eq 'SavePassword') {
        $password = Read-Host 'PostgreSQL password for projectdrive_windows' -AsSecureString
        try {
            if ($password.Length -eq 0) { throw 'An index password is required.' }
            $password | Export-Clixml -LiteralPath $passwordPath
        } finally {
            $password.Dispose()
        }
        return
    }

    if ($Action -eq 'Status') {
        $stateDescription = if ($present) { 'mounted' } elseif ($managed) { 'starting' } else { 'disconnected' }
        Write-Output "Project Drive $Drive is $stateDescription."
    }
    Assert-IndexReachable $indexHost
    & $python $cloud check-mount @configArguments
    if ($LASTEXITCODE -ne 0) { throw 'The AWS mount credential or S3 access check failed.' }
    if ($Action -eq 'Status') { return }

    if (-not $present) {
        if ($managed) { throw 'The previous mount process is still starting. Check Status and the client log.' }
        if (-not (Test-Path -LiteralPath $passwordPath -PathType Leaf)) {
            throw 'Run Use-WindowsDrive.ps1 SavePassword first.'
        }
        $secure = Import-Clixml -LiteralPath $passwordPath
        if ($secure -isnot [Security.SecureString]) { throw 'Save the Windows database password again.' }
        $cache = Join-Path $root 'cache'
        New-Item -Path $cache -ItemType Directory -Force | Out-Null
        $environment = @{
            AWS_PROFILE = $profile; AWS_DEFAULT_PROFILE = $profile; AWS_REGION = $region
            AWS_DEFAULT_REGION = $region; AWS_EC2_METADATA_DISABLED = 'true'
            AWS_IGNORE_CONFIGURED_ENDPOINT_URLS = 'true'
            AWS_ACCESS_KEY_ID = $null; AWS_SECRET_ACCESS_KEY = $null; AWS_SESSION_TOKEN = $null
            AWS_SECURITY_TOKEN = $null; AWS_ROLE_ARN = $null; AWS_ROLE_SESSION_NAME = $null
            AWS_WEB_IDENTITY_TOKEN_FILE = $null; AWS_CONTAINER_CREDENTIALS_RELATIVE_URI = $null
            AWS_CONTAINER_CREDENTIALS_FULL_URI = $null; META_PASSWORD_FILE = $null
            ACCESS_KEY = $null; SECRET_KEY = $null; SESSION_TOKEN = $null
        }
        $previous = @{}
        $uri = "postgres://projectdrive_windows@${indexHost}:55432/projectdrive?sslmode=disable&connect_timeout=5"
        $arguments = @(
            'mount', '-o', ('"uidmap={0}:,volname=Cloud Storage"' -f $macUid),
            '--cache-dir', ('"' + $cache + '"'), '--cache-size', '512',
            '--backup-meta', '0', '--metrics', '127.0.0.1:0', '--no-usage-report', $uri, $Drive
        )
        try {
            $environment['META_PASSWORD'] = [Net.NetworkCredential]::new('', $secure).Password
            foreach ($name in $environment.Keys) {
                $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
                [Environment]::SetEnvironmentVariable($name, $environment[$name], 'Process')
            }
            $options = @{
                FilePath = $juicefs; ArgumentList = $arguments; WorkingDirectory = $root
                RedirectStandardOutput = (Join-Path $root "juicefs-$($Drive[0]).out.log")
                RedirectStandardError = (Join-Path $root "juicefs-$($Drive[0]).err.log")
                WindowStyle = 'Hidden'; PassThru = $true
            }
            $process = Start-Process @options
            @{ processId = $process.Id; started = $process.StartTime.ToUniversalTime().Ticks } |
                ConvertTo-Json -Compress | Set-Content -LiteralPath $state
        } finally {
            foreach ($name in $previous.Keys) {
                [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
            }
            $environment.Remove('META_PASSWORD')
            $secure.Dispose()
        }
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            if (Test-DrivePresent) { break }
            if ($process.HasExited) { break }
            Start-Sleep -Seconds 1
        }
        if (-not (Test-DrivePresent) -or $process.HasExited) {
            throw "Mount did not become ready. Read the JuiceFS log at $root."
        }
    }
    Start-Process -FilePath explorer.exe -ArgumentList $driveRoot
} finally {
    $lock.Dispose()
}
