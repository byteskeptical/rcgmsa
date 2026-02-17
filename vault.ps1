param (
    [Parameter(Mandatory = $true, ParameterSetName="vault", Position = 0)]
    [ValidateLength(2, 255)]
    [string]$Path,

    [Parameter(Mandatory = $false, ParameterSetName="vault", Position = 1)]
    [ValidateLength(3, 24)]
    [string]$Vault = "devops",

    [Parameter(Mandatory = $false, ParameterSetName="vault", Position = 2)]
    [ValidateLength(3, 6)]
    [int]$Timeout= 3600,

    [Parameter(Mandatory = $true, ParameterSetName="info", Position = 0)]
    [switch]$v
)

if ($v) {
    $version = "1.0.0"
    Write-Host "Version: $version"
    exit
}

Write-Host "Loading modules"
$requiredModules = @(
    'Microsoft.PowerShell.SecretStore',
    'Microsoft.PowerShell.SecretManagement',
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

Write-Host "Getting secure store password"
$credential = Get-Credential -UserName $Vault
$credential.Password | Export-Clixml -Path $Path

$password = Import-CliXml -Path $Path
$parameters = @{
    Name = $Vault
    ModuleName = $requiredModules[0]
    VaultParameters = @{
        Confirm = $false
        Interaction = $null
        Password = $password
        PasswordTimeout = $Timeout
    }
    DefaultVault = $true
}

Write-Host "Registering [$Vault] vault"
[Environment]::SetEnvironmentVariable("VAULT", $password, [System.EnvironmentVariableTarget]::User)
Register-SecretVault @parameters
Remove-Item -Path $Path -Force
Write-Host "All done!!!"
