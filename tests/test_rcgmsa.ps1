BeforeAll {
    $env:VAULT = 'VaultPassword'
    $keeperSecret = @{
        API_KEY  = '06ed1705-a2d5-4d16-b3b2-1a2814e7ef67'
        DB_PASS  = 'SuperSecretPass'
        Files    = @{
            'license.key' = 'RECORD_ID_FOR_FILE'
        }
        Keys     = @('API_KEY', 'DB_PASS', 'Files')
    }
    $scriptPath = "$PSScriptRoot/../rcgmsa.ps1"
}

Describe 'Integration Tests' {

    Context 'Input Validation' {
        It 'Should accept valid hostnames or IPs' {
            { & $scriptPath -Command 'Get-Date' -Computers 'localhost','10.0.0.1' -User 'svc_account$' -v } | Should -Not -Throw
        }

        It 'Should reject invalid characters in computer names' {
            { & $scriptPath -Command 'Get-Date' -Computers 'bad_host!' -User 'svc_account$' -v } | Should -Throw 'Creativity meets catastrophe'
        }

        It 'Should reject invalid characters in orb names' {
            { & $scriptPath -Command 'Get-Date' -Computers 'localhost' -User 'svc_account$' -Orbs 'bad_orb!' -v } | Should -Throw "For FQDN's sake"
        }
    }

    Context 'Keeper Vault Integration' {
        BeforeAll {
            Mock New-Object {
                return [PSCredential]::new('User',
                                           (ConvertTo-SecureString 'pass' -AsPlainText -Force)
                )
            }
            Mock Import-Module {}
            Mock Install-Module {}
            Mock Invoke-Command { return 'Remote Execution Successful' }
            Mock Join-Path { param($Path, $ChildPath) return "$Path\$ChildPath" }
            Mock New-Item { return 'C:\Mock\Temp' }
            Mock Remove-Item {}
            Mock Set-Content {}
            Mock Unlock-SecretStore {}
        }

        It 'Should retrieve secrets and process files when -Keeper is used' {
            Mock Get-Secret -MockWith { 
                if ($args[1] -match 'RECORD_ID_FOR_FILE') {
                    return [System.Text.Encoding]::UTF8.GetBytes('FileContent')
                }
                return $keeperSecret
            }

            & $scriptPath -Command 'hostname' -Computers 'server1' -User 'gmsa$' -Keeper 'RecordID' -Vault 'devops'

            Assert-MockCalled Unlock-SecretStore -Times 1
            Assert-MockCalled Get-Secret -ParameterFilter { $Name -eq 'RecordID' } -Times 1
            Assert-MockCalled Get-Secret -ParameterFilter { $Name -eq 'RECORD_ID_FOR_FILE' } -Times 1
            Assert-MockCalled Set-Content -ParameterFilter { $Path -match 'license.key' } -Times 1
        }
    }

    Context 'Logic Branching' {
        BeforeAll {
            Mock New-Object {
                return [PSCredential]::new('User',
                                           (ConvertTo-SecureString 'pass' -AsPlainText -Force)
                )
            }
            Mock Import-Module {}
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
            Mock Invoke-Command -ParameterFilter { -not $IncludePortInSPN } -MockWith {
                $err = [System.Management.Automation.ErrorRecord]::new(
                    [Exception]::new('SPN Error'),
                    '-2144108387,PSSessionStateBroken',
                    [System.Management.Automation.ErrorCategory]::OpenError,
                    $null
                )
                throw $err
            }

            Mock Invoke-Command -ParameterFilter { $IncludePortInSPN } -MockWith { return 'Retry Successful' }

            $result = & $scriptPath -Command 'hostname' -Computers 'server1' -User 'gmsa$' 

            Assert-MockCalled Invoke-Command -Times 2
            $result | Should -Be 'Retry Successful'
        }
    }

    Context 'Environment Variable Injection' {
        It 'Should inject KEEPER_ variables into the scriptblock' {
            Mock Get-Secret -Return $keeperSecret
            Mock Invoke-Command -MockWith { 
                param($ScriptBlock) 
                return $ScriptBlock.ToString() 
            }
            Mock New-Item { return 'C:\Mock\Temp' }
            Mock Remove-Item {}
            Mock Set-Content {}
            Mock Unlock-SecretStore {}

            $sbContent = & $scriptPath -Command 'echo hi' -Computers 'server1' -User 'gmsa$' -Keeper 'rec1'

            $sbContent | Should -Match 'KEEPER_'
            $sbContent | Should -Match '\[Environment\]::SetEnvironmentVariable'
        }
    }
}
