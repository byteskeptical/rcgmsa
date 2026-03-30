BeforeAll {
    $keeperSecret = @{
        API_KEY  = '06ed1705-a2d5-4d16-b3b2-1a2814e7ef67'
        DB_PASS  = 'SuperSecretPass'
        Files    = '{"license.key": [System.Text.Encoding]::UTF8.GetBytes("RealFileContent")}'
        Keys     = 'Files'
    }
    $scriptPath = "$PSScriptRoot/../rcgmsa.ps1"
    $secretName = '9vb_wew-d6_AmgUNmIO6Ez'
    $setupPath = "$PSScriptRoot/../vault.ps1"
    $vaultName = 'devops'
    $vaultPassword  = 'VaultPassword123'

    function Get-Credential {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory=$false)]
            [string]$UserName,

            [Parameter(Mandatory=$false)]
            [string]$Message
        )
        $securePass = ConvertTo-SecureString $vaultPassword -AsPlainText -Force
        return [PSCredential]::new($UserName, $securePass)
    }

    $credFile = [System.IO.Path]::GetTempFileName()
    . $setupPath -Path $credFile -Vault $vaultName

    Remove-Item Function:\Get-Credential -ErrorAction Stop

    [Environment]::SetEnvironmentVariable(
        "VAULT",
        $vaultPassword,
        [System.EnvironmentVariableTarget]::User
    )

    $securePass = ConvertTo-SecureString $vaultPassword -AsPlainText -Force
    Unlock-SecretStore -Password $securePass

    Set-Secret -Name $secretName -Secret $keeperSecret -Vault $vaultName
    $keeperSecret.Files = @($keeperSecret.Files | ConvertFrom-Json)
}

Describe 'Integration Tests' {

    Context 'Input Validation' {
        It 'Should accept valid hostnames or IPs' {
            { & $scriptPath -Command 'Get-Date' -Computers 'localhost','127.0.0.1' -User 'svc_account$' } | Should -Not -Throw
        }

        It 'Should reject invalid characters in computer names' {
            $expectedErr = "Cannot validate argument on parameter 'Computers'. Creativity meets catastrophe, invalid computer name: bad_host!"
            { & $scriptPath -Command 'Get-Date' -Computers 'bad_host!' -User 'svc_account$' } | Should -Throw $expectedErr
        }

        It 'Should reject invalid characters in orb names' {
            $expectedErr = "Cannot validate argument on parameter 'Orbs'. For FQDN's sake, invalid computer name: bad_orb!"
            { & $scriptPath -Command 'Get-Date' -Computers 'localhost' -User 'svc_account$' -Orbs 'bad_orb!' } | Should -Throw $expectedErr
        }

        It 'Should output a semantic version number' {
            $output = & $scriptPath -v 6>&1
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
                    return $keeperSecret
                }

                return $keeperSecret[$FieldID]
            }
            Mock Invoke-Command { return 'Remote Execution Successful' }
            Mock Join-Path { param($Path, $ChildPath) return "$Path\$ChildPath" }
            Mock New-Item { return 'C:\Mock\Temp' }
            Mock Remove-Item {}
            Mock Set-Content {}
        }

        It 'Should retrieve secrets and process files when -Keeper is used' {
            & $scriptPath -Command 'hostname' -Computers 'localhost' -User 'gmsa$' -Keeper $secretName -Vault 'devops'

            $api_key = [Environment]::GetEnvironmentVariable('KEEPER_API_KEY', 'User')
            $api_key | Should -Be $keeperSecret.API_KEY

            [Environment]::SetEnvironmentVariable('KEEPER_API_KEY', $null, 'User')

            Assert-MockCalled Set-Content -ParameterFilter {
                $Path -match 'license.key'
            } -Times 1
        }

        It 'Should inject KEEPER_ variables into the scriptblock' {
            Mock Invoke-Command -MockWith { 
                param($ScriptBlock) 
                return $ScriptBlock.ToString() 
            }

            $sbContent = & $scriptPath -Command 'echo hi' -Computers 'localhost' -User 'gmsa$' -Keeper $secretName

            $sbContent | Should -Match 'KEEPER_'
            $sbContent | Should -Match '\[Environment\]::SetEnvironmentVariable'
        }
    }

    Context 'Logic Branching' {
        BeforeAll {
            Mock New-Item { return 'C:\Mock\Temp' }
            Mock Remove-Item {}
            Mock Set-Content {}
        }

        It 'Should execute the orbs logic when provided' {
            Mock Invoke-Command { return 'Jump Host Success' }

            & $scriptPath -Command 'whoami' -Computers 'target1' -User 'gmsa$' -Orbs 'jump1'

            Assert-MockCalled Invoke-Command -Times 1
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

            & $scriptPath -Command 'hostname' -Computers 'localhost' -User 'gmsa$'

            Assert-MockCalled Invoke-Command -Times 2
            Assert-MockCalled Invoke-Command -ParameterFilter { 
                $SessionOption.IncludePortInSPN -eq $true 
            } -Times 1
        }
    }
}
