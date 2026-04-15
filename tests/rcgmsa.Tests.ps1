BeforeAll {
    $script:credFile      = [System.IO.Path]::GetTempFileName()
    $script:keeperSecret  = @{
        API_KEY  = '06ed1705-a2d5-4d16-b3b2-1a2814e7ef67'
        DB_PASS  = 'SuperSecretPass'
        Files    = '{"license.key": "FileID_123"}'
        Keys     = 'Files'
    }
    $script:scriptPath    = "$PSScriptRoot/../rcgmsa.ps1"
    $script:secretName    = '9vb_wew-d6_AmgUNmIO6Ez'
    $script:setupPath     = "$PSScriptRoot/../vault.ps1"
    $script:vaultName     = 'devops'
    $script:vaultPassword = 'VaultPassword123'

    function script:Get-Credential {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory=$false)]
            [string]$UserName,

            [Parameter(Mandatory=$false)]
            [string]$Message
        )
        $securePass = ConvertTo-SecureString $script:vaultPassword -AsPlainText -Force
        return [PSCredential]::new($UserName, $securePass)
    }

    . $script:setupPath -Path $script:credFile -Vault $script:vaultName

    Remove-Item Function:\script:Get-Credential -ErrorAction SilentlyContinue

    [Environment]::SetEnvironmentVariable(
        "VAULT",
        $script:vaultPassword,
        [System.EnvironmentVariableTarget]::User
    )

    $securePass = ConvertTo-SecureString $script:vaultPassword -AsPlainText -Force
    Unlock-SecretStore -Password $securePass

    Set-Secret -Name $secretName -Secret $script:keeperSecret -Vault $script:vaultName

    $nvc = [System.Collections.Specialized.NameValueCollection]::new()
    $json = $script:keeperSecret.Files | ConvertFrom-Json
    
    foreach ($prop in $json.psobject.properties) {
        $nvc.Add($prop.Name, $prop.Value) 
    }
    $script:keeperSecret.Files = $nvc

    $script:keeperSecret["$($script:secretName).Files[license.key]"] = `
        [System.Text.Encoding]::UTF8.GetBytes('RealFileContent')
}

Describe 'Integration Tests' {

    Context 'Input Validation' {
        It 'Should accept valid hostnames or IPs' {
            { & $script:scriptPath -Command 'Get-Date' -Computers 'localhost','127.0.0.1' -User 'svc_account$' } |
                Should -Not -Throw
        }

        It 'Should reject invalid characters in computer names' {
            $expectedErr = "Cannot validate argument on parameter 'Computers'. Creativity meets catastrophe, invalid computer name: bad_host!"
            { & $script:scriptPath -Command 'Get-Date' -Computers 'bad_host!' -User 'svc_account$' } |
                Should -Throw $expectedErr
        }

        It 'Should reject invalid characters in orb names' {
            $expectedErr = "Cannot validate argument on parameter 'Orbs'. For FQDN's sake, invalid computer name: bad_orb!"
            { & $script:scriptPath -Command 'Get-Date' -Computers 'localhost' -User 'svc_account$' -Orbs 'bad_orb!' } |
                Should -Throw $expectedErr
        }

        It 'Should output a semantic version number' {
            $output = & $script:scriptPath -v 6>&1
            $output | Should -Match '^Version: \d+\.\d+\.\d+$'
        }
    }

    Context 'Keeper Vault Integration' {
        BeforeAll {
            Mock Get-Secret {
                [CmdletBinding()]
                param(
                    [Parameter(Position=0)]$Vault,
                    [Parameter(Position=1)]$Name,
                    [switch]$AsPlainText
                )

                if ($AsPlainText) {
                    return $script:keeperSecret
                }

                return $script:keeperSecret[$Name]
            }
        }

        It 'Should retrieve secrets and process files when -Keeper is used' {
            Mock Remove-Item -ParameterFilter { $Path -like '*\?*-?*-?*-?*-?*' } -MockWith {}

            & $script:scriptPath -Command 'hostname' -Computers 'localhost' `
                -User 'gmsa$' -Keeper $script:secretName -Vault 'devops'

            $sysTemp = [System.IO.Path]::GetTempPath()
            $foundFile = Get-ChildItem -Path $sysTemp -Filter 'license.key' -Recurse -File |
                         Sort-Object CreationTime -Descending |
                         Select-Object -First 1

            $foundFile | Should -Not -BeNullOrEmpty
            $foundFile.Name | Should -Be 'license.key'

            $fileContent = [System.Text.Encoding]::UTF8.GetString(
                [System.IO.File]::ReadAllBytes($foundFile.FullName)
            )
            $fileContent | Should -Be 'RealFileContent'

            if ($foundFile) { 
                Remove-Item -Path $foundFile.DirectoryName -Recurse -Force
            }
        }

        It 'Should inject KEEPER_ variables into the scriptblock' {
            & $script:scriptPath -Command 'whoami' -Computers 'localhost' `
                -User 'gmsa$' -Keeper $script:secretName 6>&1 | Out-String

            [Environment]::GetEnvironmentVariable(
                'KEEPER_API_KEY', [System.EnvironmentVariableTarget]::User
            ) | Should -Be $script:keeperSecret.API_KEY

            [Environment]::GetEnvironmentVariable(
                'KEEPER_DB_PASS', [System.EnvironmentVariableTarget]::User
            ) | Should -Be $script:keeperSecret.DB_PASS
        }
    }

    Context 'Logic Branching' {
        It 'Should execute the orbs logic when provided' {
            Mock Invoke-Command { return 'Jump Host Success' }

            & $script:scriptPath -Command 'whoami' -Computers 'target1' -User 'gmsa$' -Orbs 'jump1'

            Should -Invoke Invoke-Command -Times 1 -Exactly
        }

        It 'Should retry with -IncludePortInSPN if a specific SPN error occurs' {
            Mock Invoke-Command -ParameterFilter {
                -not ($SessionOption.IncludePortInSPN)
            } -MockWith {
                $err = [System.Management.Automation.ErrorRecord]::new(
                    [Exception]::new('SPN Error'),
                    '-2144108387,PSSessionStateBroken',
                    [System.Management.Automation.ErrorCategory]::OpenError,
                    $null
                )
                throw $err
            }

            Mock Invoke-Command -MockWith { return 'Retry Successful' }

            & $script:scriptPath -Command 'hostname' -Computers 'localhost' -User 'gmsa$'

            Should -Invoke Invoke-Command -Times 2 -Exactly
            Should -Invoke Invoke-Command -ParameterFilter {
                $SessionOption.IncludePortInSPN -eq $true
            } -Times 1 -Exactly
        }
    }
}
