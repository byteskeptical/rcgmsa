BeforeAll {
    $scriptPath = "$PSScriptRoot/../rcgmsa.ps1"
}

Describe "Validation" {

    Context "Parameter Validation" {
        It "valid computers" {
            { & $scriptPath -Command "echo hi" -Computers "localhost", "192.168.1.1" -User "gmsa$" -v } | Should -Not -Throw
        }

        It "invalid computers" {
            { & $scriptPath -Command "echo hi" -Computers "invalid_name!" -User "gmsa$" -v } | Should -Throw "Creativity meets catastrophe"
        }
    }

    Context "execution flow" {
        Mock New-Object {
            return [PSCredential]::new("User",
                                       (ConvertTo-SecureString "supersecret" -AsPlainText -Force)
            )
        }
        Mock Invoke-Command { return "Command Success" }
        Mock Import-Module {}
        Mock Install-Module {}
        Mock Get-Secret { return "FakeSecretData" }
        Mock Unlock-SecretStore {}

        Mock Get-Command -ParameterFilter { $Name -eq 'Get-Secret' } { return $true }

        It "keeper module" {
            & $scriptPath -Command "hostname" -Computers "server1" -User "gmsa$" -Keeper "RecordID" -Vault "devops"

            Assert-MockCalled Import-Module -ParameterFilter { $Name -eq "SecretManagement.Keeper" } -Times 1
        }

        It "script block" {
            Mock Invoke-Command {
                param($ScriptBlock)
                return $ScriptBlock.ToString()
            }

            $result = & $scriptPath -Command "Get-Process" -Computers "server1" -User "gmsa$"
            
            Assert-MockCalled Invoke-Command -Times 1
        }
    }
}
