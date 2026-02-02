BeforeAll {
    function Get-Secret {}
    function Install-Module {}
    function Unlock-SecretStore {}

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
            $expectedErr = "Connecting to remote server * failed with the following error message : The WinRM client cannot process the request.*"
            { & $scriptPath -Command 'Get-Date' -Computers 'localhost','127.0.0.1' -User 'svc_account$' } | Should -Throw $expectedErr
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
            function Install-Module {}
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
            Mock Invoke-Command -ParameterFilter { -not ($SessionOption.IncludePortInSPN) } -MockWith {
                $err = [System.Management.Automation.ErrorRecord]::new(
                    [Exception]::new('SPN Error'),
                    '-2144108387,PSSessionStateBroken',
                    [System.Management.Automation.ErrorCategory]::OpenError,
                    $null
                )
                throw $err
            }

            Mock Invoke-Command -ParameterFilter { $SessionOption.IncludePortInSPN -eq $true } -MockWith { return 'Retry Successful' }

            $result = & $scriptPath -Command 'hostname' -Computers 'localhost' -User 'gmsa$' 6>&1

            Assert-MockCalled Invoke-Command -Times 2
            $result | Should -Be 'Retry Successful'
        }
    }

    Context 'Environment Variable Injection' {
        It 'Should inject KEEPER_ variables into the scriptblock' {
            Mock Get-Secret -MockWith { return $keeperSecret }
            Mock Invoke-Command -MockWith { 
                param($ScriptBlock) 
                return $ScriptBlock.ToString() 
            }
            Mock New-Item { return 'C:\Mock\Temp' }
            Mock Remove-Item {}
            Mock Set-Content {}
            Mock Unlock-SecretStore {}

            $sbContent = & $scriptPath -Command 'echo hi' -Computers 'localhost' -User 'gmsa$' -Keeper 'rec1'

            $sbContent | Should -Match 'KEEPER_'
            $sbContent | Should -Match '\[Environment\]::SetEnvironmentVariable'
        }
    }
}
