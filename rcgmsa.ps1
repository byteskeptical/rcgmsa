param (
    [Parameter(Mandatory = $true, ParameterSetName="gmsa", Position = 0)]
    [ValidateLength(2, 255)]
    [string]$Command,

    [Parameter(Mandatory = $true, ParameterSetName="gmsa", Position = 1)]
    [ValidateLength(2, 255)]
    [ValidateScript({
        foreach ($computer in $_) {
            if (-not ([System.Uri]::CheckHostName($computer) -in @('Dns', 'IPv4', 'IPv6'))) {
                throw "Creativity meets catastrophe, invalid computer name: $computer"
            }
        }
        $true
    })]
    [string[]]$Computers,

    [Parameter(Mandatory = $true, ParameterSetName="gmsa", Position = 2)]
    [ValidateLength(2, 16)]
    [string]$User,

    [Parameter(Mandatory = $false, ParameterSetName="gmsa", Position = 3)]
    [ValidateSet(0, 1, 2, 3, 4, 5, 6)]
    [int]$Authentication = 0,

    [Parameter(Mandatory = $false, ParameterSetName="gmsa", Position = 4)]
    [ValidateLength(2, 64)]
    [string]$Domain = "",

    [Parameter(Mandatory = $false, ParameterSetName="gmsa", Position = 5)]
    [ValidateLength(22, 22)]
    [string]$Keeper,

    [Parameter(Mandatory = $false, ParameterSetName="gmsa", Position = 6)]
    [ValidateLength(2, 255)]
    [ValidateScript({
        foreach ($computer in $_) {
            if (-not ([System.Uri]::CheckHostName($computer) -in @('Dns', 'IPv4', 'IPv6'))) {
                throw "For FQDN's sake, invalid computer name: $computer"
            }
        }
        $true
    })]
    [string[]]$Orbs = "",

    [Parameter(Mandatory = $false, ParameterSetName="gmsa", Position = 7)]
    [ValidateLength(3, 24)]
    [string]$Vault = "devops",

    [Parameter(Mandatory = $false, ParameterSetName="gmsa", Position = 8)]
    [switch]$Raw,

    [Parameter(Mandatory = $true, ParameterSetName="info", Position = 0)]
    [switch]$v
)

if ($v) {
    $version = "1.0.0"
    Write-Host "Version: $version"
    exit
}

$account = (New-Object System.Management.Automation.PSCredential("$Domain\$User"))
$command = $Command -replace 'javaopts\=', 'javaopts '
$credential  = $null
if ($Raw) {
    $sb = $command
} else {
    $sb = [scriptblock]::Create($command)
}
$keeperFiles = $null
$scriptPath = $MyInvocation.MyCommand.Path
$serverName = $env:COMPUTERNAME
$sessionOptions = New-PSSessionOption -NoCompression
$sysTempDir = [System.IO.Path]::GetTempPath()
$tempDir = Join-Path -Path $sysTempDir -ChildPath ([Guid]::NewGuid().ToString())

New-Item -Path $tempDir -ItemType Directory -Force | Out-Null

Write-Host "***********************************************************************"
Write-Host "* Running PowerShell Script: $scriptPath on $serverName"
Write-Host "* Command: $command"
Write-Host "* Run on: $Computers"
Write-Host "* gMSA Account: $User"
Write-Host "* Domain: $Domain"
Write-Host "* Keeper Credential ID: $Keeper"
Write-Host "***********************************************************************"

if ($Keeper) {
    $requiredModules = @(
        'Microsoft.PowerShell.SecretManagement',
        'Microsoft.PowerShell.SecretStore',
        'SecretManagement.Keeper'
    )

    $requiredModules.ForEach{
        $moduleName = $_
        try {
            Write-Host "Importing [$moduleName]"
            Import-Module $moduleName -ErrorAction Stop
        } catch [System.Management.Automation.RuntimeException] {
            Write-Host "Installing [$moduleName]"
            Install-Module -Name $moduleName -Scope CurrentUser -Force
            Import-Module $moduleName
        }
    }

    try {
        $vault_credential = [System.Environment]::GetEnvironmentVariable("VAULT", [System.EnvironmentVariableTarget]::User)
        $password = ConvertTo-SecureString -String $vault_credential -AsPlainText -Force
        Unlock-SecretStore -Password $password
        $credential = Get-Secret -Vault $Vault -Name $Keeper -AsPlainText -ErrorAction Stop

        if ('Files' -in $credential.Keys) {
            foreach ($filename in ($credential.Files)) {
                $data = Get-Secret -Vault $Vault -Name "$($Keeper).Files[$filename]"
                $filepath = Join-Path -Path $tempDir -ChildPath $filename
                Set-Content -Path $filepath -Value $data -AsByteStream
            }

            $keeperFiles = Get-ChildItem -Path $tempDir
        }
    } catch [Microsoft.PowerShell.SecretManagement.PasswordRequiredException]  {
        Write-Host "Unlocking Vault $Vault for one hour."
        Unlock-SecretStore -Password $password
        $credential = Get-Secret -Vault $Vault -Name $Keeper -AsPlainText -ErrorAction Stop
    } catch [System.Exception] {
        Write-Error "Failed to retrieve Keeper secret.`nError: $($_.Exception.Message)"
        $host.SetShouldExit(1)
    }
}

$parameters = @{
    Authentication    = $Authentication
    ComputerName      = $Computers
    Credential        = $account
    ScriptBlock       = {
        $cred = $using:credential
        $remoteSysTempDir = [System.IO.Path]::GetTempPath()
        $remoteTempDir = Join-Path -Path $remoteSysTempDir -ChildPath ([Guid]::NewGuid().ToString())

        New-Item -Path $remoteTempDir -ItemType Directory -Force | Out-Null

        if ($cred) {
            foreach ($field in ($cred.Keys)) {
                if ($field -ne 'Files') {
                    $name = "KEEPER_$($field.ToUpper())"
                    [Environment]::SetEnvironmentVariable(
                        $name,
                        $cred[$field],
                        [System.EnvironmentVariableTarget]::User
                    )
                } else {
                    foreach ($filename in $using:keeperFiles) {
                        Copy-Item -Path $filename.FullName -Destination $remoteTempDir
                    }
                }
            }
        }

        if ($using:Orbs) {
            $orbParameters = @{
                ComputerName  = $using:Orbs
                Credential    = $using:account
                ScriptBlock   = { & $using:sb }
                SessionOption = $using:sessionOptions
            }
            Invoke-Command @orbParameters
        } else {
            Invoke-Command -ScriptBlock { & $using:sb }
        }

        Remove-Item -Path $remoteTempDir -Recurse -Force
    }
}

try {
    $remoteResults = Invoke-Command @parameters -SessionOption $sessionOptions -ErrorAction Stop
    Write-Host "$remoteResults"
} catch [System.Exception] {
    $currentError = $_
    $errorId = $currentError.FullyQualifiedErrorId
    $errorType = $currentError.GetType().FullName

    $spnRelatedFQIDs = @(
        "-2144108387,PSSessionStateBroken"
    )
    $spnRelatedTypes= @(
        "System.Management.Automation.ErrorRecord"
    )

    Write-Warning "Caught an Exception."
    Write-Host "    - FQID: $errorId"
    Write-Host "    - Type: $errorType"

    if ( ($spnRelatedFQIDs -contains $errorId) -or
         ($spnRelatedTypes -contains $errorType) )
    {
        Write-Warning "First attempt failed with a possible SPN issue. Retrying with -IncludePortInSPN."
        $sessionOptions = New-PSSessionOption -IncludePortInSPN -NoCompression
        $remoteResults = Invoke-Command @parameters -SessionOption $sessionOptions
        Write-Host "$remoteResults"
    } else {
        throw $currentError
        $host.SetShouldExit(1)
    }
} finally {
    Remove-Item -Path $tempDir -Recurse -Force
}

$host.SetShouldExit(0)
