#Requires -Version 5.1
<#
.SYNOPSIS
  Adds the first domain controller of a child domain to an existing lab forest.

.DESCRIPTION
  Creates a dynamically sized L2 VM from the Windows Server 2025 golden image,
  configures networking through two-hop PowerShell Direct, and runs
  Install-ADDSDomain to create a child domain. The operation is idempotent: an
  existing VM is reused and an already promoted controller is left unchanged.

  Run this on the L0 Hyper-V host with PowerShell 7, just like the other
  hyperv-nestlab provisioning scripts.

.EXAMPLE
  .\scripts\Add-LabChildDomainController.ps1

  Creates brdc01 (10.10.0.12) for branch.corp.contoso.local.
#>
[CmdletBinding()]
param(
    [string]$L1Name           = 'nested-lab-01',
    [string]$Name             = 'brdc01',
    [string]$IPAddress        = '10.10.0.12',
    [int]$PrefixLength        = 24,
    [string]$Gateway          = '10.10.0.1',
    [string]$ParentDcIp       = '10.10.0.10',
    [string]$ParentDcName     = 'dc01',
    [string]$ParentDomainFqdn = 'corp.contoso.local',
    [string]$ParentNetBIOS    = 'CORP',
    [string]$ChildLabel       = 'branch',
    [string]$ChildNetBIOS     = 'BRANCH',
    [string]$GuestPassword    = 'P@ssw0rd-Lab-Change!',
    [string]$DsrmPassword     = 'P@ssw0rd-DSRM-Lab!',
    [string]$SwitchName       = 'LabNAT',
    [int]$MemoryGB            = 4,
    [int]$MinMemoryGB         = 2,
    [int]$CpuCount            = 2,
    [string]$GoldenPath       = 'L:\images\win2025-golden-en-us.vhdx',
    [string]$VmRoot           = 'L:\vms'
)

$ErrorActionPreference = 'Stop'
$childDomainFqdn = "$ChildLabel.$ParentDomainFqdn"

function Write-LabLog {
    param([string]$Message)
    Write-Host "  [add-child-dc] $Message" -ForegroundColor DarkCyan
}

$l1Credential = New-Object System.Management.Automation.PSCredential(
    'Administrator', (ConvertTo-SecureString $GuestPassword -AsPlainText -Force))

Write-LabLog "Connecting to L1 $L1Name"
$l1Session = New-PSSession -VMName $L1Name -Credential $l1Credential
try {
    $result = Invoke-Command -Session $l1Session -ScriptBlock {
        param(
            $Name, $IPAddress, $PrefixLength, $Gateway, $ParentDcIp, $ParentDcName,
            $ParentDomainFqdn, $ParentNetBIOS, $ChildLabel, $ChildNetBIOS,
            $ChildDomainFqdn, $GuestPassword, $DsrmPassword, $SwitchName,
            $MemoryGB, $MinMemoryGB, $CpuCount, $GoldenPath, $VmRoot
        )

        $ErrorActionPreference = 'Stop'
        $log = New-Object System.Collections.ArrayList
        function Add-Log {
            param([string]$Message)
            [void]$log.Add("$([datetime]::Now.ToString('HH:mm:ss')) $Message")
        }
        function New-LabCredential {
            param([string]$UserName)
            New-Object System.Management.Automation.PSCredential(
                $UserName, (ConvertTo-SecureString $GuestPassword -AsPlainText -Force))
        }
        function Connect-LabGuest {
            param([string]$VmName, $Credential, [int]$TimeoutSeconds = 1800)
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            while ((Get-Date) -lt $deadline) {
                try {
                    return New-PSSession -VMName $VmName -Credential $Credential -ErrorAction Stop
                } catch {
                    Start-Sleep -Seconds 10
                }
            }
            throw "PowerShell Direct connection to $VmName timed out after $TimeoutSeconds seconds"
        }

        $localCredential = New-LabCredential -UserName 'Administrator'
        $parentCredential = New-LabCredential -UserName "$ParentNetBIOS\Administrator"
        $childCredential = New-LabCredential -UserName "$ChildNetBIOS\Administrator"

        function Repair-ChildDomainDns {
            param($ParentVm, $ChildVm, $ParentCredential, $ChildCredential,
                  $ParentZone, $ChildZone, $ChildIp, $ParentIp)

            # Nested dcpromo occasionally leaves the child DNS application
            # partition and zone absent. First publish a delegation in the
            # parent zone so the child is authoritative from the forest root.
            $parentSession = Connect-LabGuest $ParentVm $ParentCredential 300
            try {
                Invoke-Command -Session $parentSession -ScriptBlock {
                    param($ParentZone, $ChildZone, $ChildHost, $ChildIp)
                    $label = $ChildZone.Substring(0, $ChildZone.Length - $ParentZone.Length - 1)
                    try {
                        Add-DnsServerZoneDelegation -Name $ParentZone -ChildZoneName $label `
                            -NameServer "$ChildHost.$ChildZone" -IPAddress $ChildIp -ErrorAction Stop
                    } catch {
                        # Add-DnsServerZoneDelegation is idempotent in intent but
                        # has no -Force/-Update switch. Existing NS/glue is fine.
                        $existing = Resolve-DnsName $ChildZone -Type NS -Server 127.0.0.1 -ErrorAction SilentlyContinue
                        if (-not $existing) { throw }
                    }
                } -ArgumentList $ParentZone, $ChildZone, $ChildVm, $ChildIp
            } finally {
                Remove-PSSession $parentSession
            }

            $childSession = Connect-LabGuest $ChildVm $ChildCredential 600
            try {
                return Invoke-Command -Session $childSession -ScriptBlock {
                    param($ChildZone, $OwnIp, $ParentIp)
                    Import-Module DnsServer
                    if (-not (Get-DnsServerZone -Name $ChildZone -ErrorAction SilentlyContinue)) {
                        try {
                            Add-DnsServerPrimaryZone -Name $ChildZone -ReplicationScope Domain `
                                -DynamicUpdate Secure -ErrorAction Stop
                        } catch {
                            # In constrained nested promotion, DomainDnsZones for
                            # the child can be missing (DNS error 9901/9571).
                            # A file-backed primary keeps DC locator functional so
                            # the replica can join; this is a lab recovery path.
                            Add-DnsServerPrimaryZone -Name $ChildZone `
                                -ZoneFile "$ChildZone.dns" -DynamicUpdate NonsecureAndSecure -ErrorAction Stop
                        }
                    }
                    $zone = Get-DnsServerZone -Name $ChildZone
                    if (-not $zone.IsDsIntegrated) {
                        # A file-backed zone is only a bootstrap fallback. Restore
                        # the child DomainDnsZones partition and convert it before
                        # declaring convergence, so additional child DCs receive it.
                        try { Add-DnsServerDirectoryPartition -Name "DomainDnsZones.$ChildZone" -ErrorAction Stop } catch { }
                        ConvertTo-DnsServerPrimaryZone -Name $ChildZone -ReplicationScope Domain `
                            -Force -ErrorAction Stop | Out-Null
                        Set-DnsServerPrimaryZone -Name $ChildZone -DynamicUpdate Secure -ErrorAction Stop
                        $zone = Get-DnsServerZone -Name $ChildZone
                        if (-not $zone.IsDsIntegrated) { throw "DNS zone $ChildZone remains file-backed" }
                    }
                    $adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
                    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @('127.0.0.1', $ParentIp)
                    Clear-DnsClientCache
                    Restart-Service Netlogon -Force
                    ipconfig /registerdns | Out-Null
                    Start-Sleep -Seconds 12
                    $srv = @(Resolve-DnsName "_ldap._tcp.dc._msdcs.$ChildZone" -Type SRV `
                        -Server 127.0.0.1 -ErrorAction SilentlyContinue)
                    if ($srv.Count -eq 0) { throw "Child-domain DC locator SRV is missing for $ChildZone" }
                    [pscustomobject]@{
                        Zone = $ChildZone
                        IsDsIntegrated = [bool]$zone.IsDsIntegrated
                        DcLocatorRecords = $srv.Count
                    }
                } -ArgumentList $ChildZone, $ChildIp, $ParentIp
            } finally {
                Remove-PSSession $childSession
            }
        }

        function Restart-LabGuestGracefully {
            param([string]$VmName, $RestartCredential, $ReconnectCredential)
            $session = Connect-LabGuest $VmName $RestartCredential 300
            $beforeBoot = $null
            $restartError = ''
            try {
                $beforeBoot = Invoke-Command -Session $session -ScriptBlock {
                    (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
                }
                try { Invoke-Command -Session $session -ScriptBlock { Restart-Computer -Force } -ErrorAction Stop }
                catch { $restartError = $_.Exception.Message } # Transport closure is expected.
            } finally { Remove-PSSession $session -ErrorAction SilentlyContinue }

            $deadline = (Get-Date).AddMinutes(15)
            Start-Sleep -Seconds 10
            while ((Get-Date) -lt $deadline) {
                try {
                    $probe = Connect-LabGuest $VmName $ReconnectCredential 30
                    try {
                        $afterBoot = Invoke-Command -Session $probe -ScriptBlock {
                            (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
                        }
                    } finally { Remove-PSSession $probe -ErrorAction SilentlyContinue }
                    if ([datetime]$afterBoot -gt [datetime]$beforeBoot) { return }
                } catch { }
                Start-Sleep -Seconds 10
            }
            throw "Windows restart for $VmName did not complete. Restart request: $restartError"
        }

        function Wait-ChildDcHealthy {
            param([string]$VmName, $Credential, [string]$ExpectedDomain,
                  [string]$OwnIp, [string]$ParentIp)
            $deadline = (Get-Date).AddMinutes(20)
            while ((Get-Date) -lt $deadline) {
                try {
                    $session = Connect-LabGuest $VmName $Credential 90
                    try {
                        $verified = Invoke-Command -Session $session -ScriptBlock {
                            param($ExpectedDomain, $OwnIp, $ParentIp)
                            Set-Service ADWS -StartupType Automatic -ErrorAction SilentlyContinue
                            Start-Service ADWS -ErrorAction SilentlyContinue
                            $adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
                            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @($OwnIp, $ParentIp)
                            Restart-Service Netlogon -Force -ErrorAction SilentlyContinue
                            Start-Sleep -Seconds 5
                            Import-Module ActiveDirectory
                            [pscustomobject]@{
                                Domain = (Get-ADDomain).DNSRoot
                                ForestDomains = @((Get-ADForest).Domains)
                                DomainRole = (Get-CimInstance Win32_ComputerSystem).DomainRole
                                ADWS = (Get-Service ADWS).Status.ToString()
                            }
                        } -ArgumentList $ExpectedDomain, $OwnIp, $ParentIp
                    } finally { Remove-PSSession $session }
                    if ($verified.Domain -eq $ExpectedDomain -and $verified.DomainRole -in 4, 5 -and $verified.ADWS -eq 'Running') { return $verified }
                } catch { }
                Start-Sleep -Seconds 15
            }
            throw "$VmName did not become a healthy controller for $ExpectedDomain"
        }

        # Create or start the VM. Dynamic memory is essential when several L2
        # controllers share the nested L1 host.
        $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
        $vmWasCreated = (-not $vm)
        if (-not $vm) {
            $vmDirectory = Join-Path $VmRoot $Name
            $vhdPath = Join-Path $vmDirectory "$Name-os.vhdx"
            New-Item -ItemType Directory -Path $vmDirectory -Force | Out-Null
            Add-Log "Copying golden image to $vhdPath"
            Copy-Item -LiteralPath $GoldenPath -Destination $vhdPath -Force
            New-VM -Name $Name -MemoryStartupBytes ($MinMemoryGB * 1GB) -Generation 2 `
                -VHDPath $vhdPath -SwitchName $SwitchName | Out-Null
            Set-VM -Name $Name -ProcessorCount $CpuCount -AutomaticCheckpointsEnabled $false
            Set-VMMemory -VMName $Name -DynamicMemoryEnabled $true `
                -MinimumBytes ($MinMemoryGB * 1GB) -StartupBytes ($MinMemoryGB * 1GB) `
                -MaximumBytes ($MemoryGB * 1GB)
            Start-VM -Name $Name
            Add-Log "Created and started VM $Name"
        } else {
            Add-Log "VM $Name already exists"
            if ($vm.State -ne 'Running') {
                Set-VMMemory -VMName $Name -DynamicMemoryEnabled $true `
                    -MinimumBytes ($MinMemoryGB * 1GB) -StartupBytes ($MinMemoryGB * 1GB) `
                    -MaximumBytes ($MemoryGB * 1GB)
                Start-VM -Name $Name
                Add-Log "Started VM $Name"
            }
        }

        # Check the final state before trying the local account, which no longer
        # exists after domain-controller promotion. A newly started VM needs time
        # before PowerShell Direct accepts connections.
        $state = $null
        try {
            if ($vmWasCreated) { throw 'New VM is not promoted yet' }
            $session = Connect-LabGuest -VmName $Name -Credential $childCredential -TimeoutSeconds 600
            try {
                $state = Invoke-Command -Session $session -ScriptBlock {
                    [pscustomobject]@{
                        Domain = (Get-CimInstance Win32_ComputerSystem).Domain
                        Role = (Get-CimInstance Win32_ComputerSystem).DomainRole
                    }
                }
            } finally { Remove-PSSession $session }
        } catch { }
        if ($state -and $state.Domain -eq $ChildDomainFqdn -and $state.Role -in 4, 5) {
            # DNS repair errors must not fall through into workgroup provisioning.
            $dnsState = Repair-ChildDomainDns -ParentVm $ParentDcName -ChildVm $Name `
                -ParentCredential $parentCredential -ChildCredential $childCredential `
                -ParentZone $ParentDomainFqdn -ChildZone $ChildDomainFqdn `
                -ChildIp $IPAddress -ParentIp $ParentDcIp
            $verified = Wait-ChildDcHealthy -VmName $Name -Credential $childCredential `
                -ExpectedDomain $ChildDomainFqdn -OwnIp $IPAddress -ParentIp $ParentDcIp
            Add-Log "$Name is already a healthy controller for $ChildDomainFqdn; DNS=$($dnsState.DcLocatorRecords), ADWS=$($verified.ADWS)"
            return $log.ToArray()
        }

        Add-Log 'Waiting for local Administrator sign-in'
        $session = Connect-LabGuest -VmName $Name -Credential $localCredential
        try {
            $networkResult = Invoke-Command -Session $session -ScriptBlock {
                param($ComputerName, $IpAddress, $Prefix, $DefaultGateway, $DnsServer)
                $messages = @()
                $adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
                if (-not $adapter) { $adapter = Get-NetAdapter | Select-Object -First 1 }
                $configured = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 `
                    -ErrorAction SilentlyContinue | Where-Object IPAddress -eq $IpAddress
                if (-not $configured) {
                    Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 `
                        -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
                    Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' `
                        -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
                    New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $IpAddress `
                        -PrefixLength $Prefix -DefaultGateway $DefaultGateway | Out-Null
                    $messages += "Configured $IpAddress/$Prefix"
                }
                Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $DnsServer
                if ($env:COMPUTERNAME -ne $ComputerName) {
                    Rename-Computer -NewName $ComputerName -Force
                    $messages += "Renamed computer to $ComputerName"
                }
                $messages
            } -ArgumentList $Name, $IPAddress, $PrefixLength, $Gateway, $ParentDcIp
            $networkResult | ForEach-Object { Add-Log $_ }
        } finally {
            Remove-PSSession $session
        }

        Restart-LabGuestGracefully -VmName $Name -RestartCredential $localCredential -ReconnectCredential $localCredential

        Add-Log "Creating child domain $ChildDomainFqdn"
        $session = Connect-LabGuest -VmName $Name -Credential $localCredential
        try {
            $promotionResult = Invoke-Command -Session $session -ScriptBlock {
                param($ParentDomain, $ChildName, $ChildNetBIOSName, $ParentNetBIOSName, $Password, $DsrmPassword)
                $messages = @()
                if (-not (Get-WindowsFeature AD-Domain-Services).Installed) {
                    Install-WindowsFeature AD-Domain-Services -IncludeManagementTools | Out-Null
                    $messages += 'Installed AD DS role'
                }
                Import-Module ADDSDeployment
                # Install-ADDSDomain validates the credential's domain through DNS.
                # A NetBIOS-qualified name can fail from a workgroup host even when
                # the parent DC and SRV records are reachable, so use a UPN here.
                $credential = New-Object System.Management.Automation.PSCredential(
                    "Administrator@$ParentDomain", (ConvertTo-SecureString $Password -AsPlainText -Force))
                Install-ADDSDomain -NewDomainName $ChildName -ParentDomainName $ParentDomain `
                    -NewDomainNetbiosName $ChildNetBIOSName -DomainType ChildDomain `
                    -Credential $credential `
                    -SafeModeAdministratorPassword (ConvertTo-SecureString $DsrmPassword -AsPlainText -Force) `
                    -InstallDns:$true -NoGlobalCatalog:$false -NoRebootOnCompletion:$true `
                    -Force -Confirm:$false | Out-Null
                $messages += 'Child-domain promotion completed; restart required'
                $messages
            } -ArgumentList $ParentDomainFqdn, $ChildLabel, $ChildNetBIOS, $ParentNetBIOS, $GuestPassword, $DsrmPassword
            $promotionResult | ForEach-Object { Add-Log $_ }
        } finally {
            Remove-PSSession $session
        }

        Restart-LabGuestGracefully -VmName $Name -RestartCredential $localCredential -ReconnectCredential $childCredential

        Add-Log 'Converging parent delegation and child DNS zone'
        $dnsState = Repair-ChildDomainDns -ParentVm $ParentDcName -ChildVm $Name `
            -ParentCredential $parentCredential -ChildCredential $childCredential `
            -ParentZone $ParentDomainFqdn -ChildZone $ChildDomainFqdn `
            -ChildIp $IPAddress -ParentIp $ParentDcIp
        Add-Log "DNS ready: zone=$($dnsState.Zone), AD-integrated=$($dnsState.IsDsIntegrated), locator=$($dnsState.DcLocatorRecords)"

        Add-Log 'Waiting for AD DS and ADWS'
        $verified = Wait-ChildDcHealthy -VmName $Name -Credential $childCredential `
            -ExpectedDomain $ChildDomainFqdn -OwnIp $IPAddress -ParentIp $ParentDcIp
        Add-Log "Verified domain=$($verified.Domain), forest=$($verified.ForestDomains -join ','), ADWS=$($verified.ADWS)"
        return $log.ToArray()
    } -ArgumentList @(
        $Name, $IPAddress, $PrefixLength, $Gateway, $ParentDcIp, $ParentDcName,
        $ParentDomainFqdn, $ParentNetBIOS, $ChildLabel, $ChildNetBIOS,
        $childDomainFqdn, $GuestPassword, $DsrmPassword, $SwitchName,
        $MemoryGB, $MinMemoryGB, $CpuCount, $GoldenPath, $VmRoot
    )

    $result | ForEach-Object { Write-LabLog $_ }
    Write-LabLog 'Completed'
} finally {
    Remove-PSSession $l1Session -ErrorAction SilentlyContinue
}
