function Resolve-DbaNetworkName {
    <#
    .SYNOPSIS
        Returns information about the network connection of the target computer including NetBIOS name, IP Address, domain name and fully qualified domain name (FQDN).

    .DESCRIPTION
        Retrieves the IPAddress, ComputerName from one computer.
        The object can be used to take action against its name or IPAddress.

        First ICMP is used to test the connection, and get the connected IPAddress.

        Multiple protocols (e.g. WMI, CIM, etc) are attempted before giving up.

        Important: Remember that FQDN doesn't always match "ComputerName dot Domain" as AD intends.
        There are network setup (google "disjoint domain") where AD and DNS do not match.
        "Full computer name" (as reported by sysdm.cpl) is the only match between the two,
        and it matches the "DNSHostName"  property of the computer object stored in AD.
        This means that the notation of FQDN that matches "ComputerName dot Domain" is incorrect
        in those scenarios.
        In other words, the "suffix" of the FQDN CAN be different from the AD Domain.

        This cmdlet has been providing good results since its inception but for lack of useful
        names some doubts may arise.
        Let this clear the doubts:
        - InputName: whatever has been passed in
        - ComputerName: hostname only
        - IPAddress: IP Address
        - DNSHostName: hostname only, coming strictly from DNS (as reported from the calling computer)
        - DNSDomain: domain only, coming strictly from DNS (as reported from the calling computer)
        - Domain: domain only, coming strictly from AD (i.e. the domain the ComputerName is joined to)
        - DNSHostEntry: Fully name as returned by DNS [System.Net.Dns]::GetHostEntry
        - FQDN: "legacy" notation of ComputerName "dot" Domain (coming from AD)
        - FullComputerName: Full name as configured from within the Computer (i.e. the only secure match between AD and DNS)

        So, if you need to use something, go with FullComputerName, always, as it is the most correct in every scenario.

    .PARAMETER ComputerName
        The target SQL Server instance or instances.
        This can be the name of a computer, a SMO object, an IP address or a SQL Instance.

    .PARAMETER Credential
        Credential object used to connect to the SQL Server as a different user

    .PARAMETER Turbo
        Resolves without accessing the server itself. Faster but may be less accurate because it relies on DNS only,
        so it may fail spectacularly for disjoin-domain setups. Also, everyone has its own DNS (i.e. results may vary
        changing the computer where the function runs)

    .PARAMETER EnableException
        By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
        This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
        Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

    .NOTES
        Tags: Network, Resolve
        Author: Klaas Vandenberghe (@PowerDBAKlaas) | Simone Bizzotto (@niphold)

        Website: https://dbatools.io
        Copyright: (c) 2018 by dbatools, licensed under MIT
        License: MIT https://opensource.org/licenses/MIT

    .LINK
        https://dbatools.io/Resolve-DbaNetworkName

    .EXAMPLE
        PS C:\> Resolve-DbaNetworkName -ComputerName ServerA

        Returns a custom object displaying InputName, ComputerName, IPAddress, DNSHostName, DNSDomain, Domain, DNSHostEntry, FQDN, DNSHostEntry for ServerA

    .EXAMPLE
        PS C:\> Resolve-DbaNetworkName -SqlInstance sql2016\sqlexpress

        Returns a custom object displaying InputName, ComputerName, IPAddress, DNSHostName, DNSDomain, Domain, DNSHostEntry, FQDN, DNSHostEntry  for the SQL instance sql2016\sqlexpress

    .EXAMPLE
        PS C:\> Resolve-DbaNetworkName -SqlInstance sql2016\sqlexpress, sql2014

        Returns a custom object displaying InputName, ComputerName, IPAddress, DNSHostName, DNSDomain, Domain, DNSHostEntry, FQDN, DNSHostEntry  for the SQL instance sql2016\sqlexpress and sql2014

    .EXAMPLE
        PS C:\> Get-DbaCmsRegServer -SqlInstance sql2014 | Resolve-DbaNetworkName

        Returns a custom object displaying InputName, ComputerName, IPAddress, DNSHostName, Domain, FQDN for all SQL Servers returned by Get-DbaCmsRegServer

    #>
    [CmdletBinding()]
    param (
        [parameter(ValueFromPipeline)]
        [Alias('cn', 'host', 'ServerInstance', 'Server', 'SqlInstance')]
        [DbaInstanceParameter[]]$ComputerName = $env:COMPUTERNAME,
        [PSCredential]$Credential,
        [Alias('FastParrot')]
        [switch]$Turbo,
        [Alias('Silent')]
        [switch]$EnableException
    )
    begin {
        Function Get-ComputerDomainName {
            Param (
                $FQDN,
                $ComputerName
            )
            # deduce the domain name based on resolved name + original request
            if ($fqdn -notmatch "\.") {
                if ($ComputerName -match "\.") {
                    return $ComputerName.Substring($ComputerName.IndexOf(".") + 1)
                } else {
                    if ($env:USERDNSDOMAIN) {
                        return $env:USERDNSDOMAIN.ToLower()
                    }
                }
            } else {
                return $fqdn.Substring($fqdn.IndexOf(".") + 1)
            }
        }
    }
    process {
        if (-not (Test-Windows -NoWarn)) {
            Write-Message -Level Verbose -Message "Non-Windows client detected. Turbo (DNS resolution only) set to $true"
            $Turbo = $true
        }

        foreach ($computer in $ComputerName) {
            if ($computer.IsLocalhost) {
                $cName = $env:COMPUTERNAME
            } else {
                $cName = $computer.ComputerName
            }

            # resolve IP address
            try {
                Write-Message -Level VeryVerbose -Message "Resolving $cName using .NET.Dns GetHostEntry"
                $resolved = [System.Net.Dns]::GetHostEntry($cName)
                $ipaddresses = $resolved.AddressList | Sort-Object -Property AddressFamily # prioritize IPv4
                $ipaddress = $ipaddresses[0].IPAddressToString
            } catch {
                Stop-Function -Message "DNS name $cName not found" -Continue -ErrorRecord $_
            }

            # try to resolve IP into a hostname
            try {
                Write-Message -Level VeryVerbose -Message "Resolving $ipaddress using .NET.Dns GetHostByAddress"
                $fqdn = [System.Net.Dns]::GetHostByAddress($ipaddress).HostName
            } catch {
                Write-Message -Level Debug -Message "Failed to resolve $ipaddress using .NET.Dns GetHostByAddress"
                $fqdn = $resolved.HostName
            }

            $dnsDomain = Get-ComputerDomainName -FQDN $fqdn -ComputerName $cName
            # augment fqdn if needed
            if ($fqdn -notmatch "\." -and $dnsDomain) {
                $fqdn = "$fqdn.$dnsdomain"
            }

            $hostname = $fqdn.Split(".")[0]
            if ($Turbo) {
                # that's a finish line for a Turbo mode
                return [PSCustomObject]@{
                    InputName        = $computer
                    ComputerName     = $hostname.ToUpper()
                    IPAddress        = $ipaddress
                    DNSHostname      = $hostname
                    DNSDomain        = $dnsdomain
                    Domain           = $dnsdomain
                    DNSHostEntry     = $fqdn
                    FQDN             = $fqdn
                    FullComputerName = $fqdn
                }
            }

            # finding out which IP to use by pinging all of them. The first to respond is the one.
            $ping = New-Object System.Net.NetworkInformation.Ping
            $timeout = 1000 #milliseconds
            foreach ($ip in $ipaddresses) {
                $reply = $ping.Send($ip, $timeout)
                if ($reply.Status -eq 'Success') {
                    $ipaddress = $ip.IPAddressToString
                    break
                }
            }

            # re-try DNS reverse zone lookup if the IP to use is not the first one
            if ($ipaddresses[0].IPAddressToString -ne $ipaddress) {
                try {
                    Write-Message -Level VeryVerbose -Message "Resolving $ipaddress using .NET.Dns GetHostByAddress"
                    $fqdn = [System.Net.Dns]::GetHostByAddress($ipaddress).HostName
                } catch {
                    Write-Message -Level VeryVerbose -Message "Failed to obtain a new name from $ipaddress, re-using $fqdn"
                }
            }

            # re-adjust DNS domain again
            $dnsDomain = Get-ComputerDomainName -FQDN $fqdn -ComputerName $cName
            # augment fqdn if needed
            if ($fqdn -notmatch "\." -and $dnsDomain) {
                $fqdn = "$fqdn.$dnsdomain"
            }
            $hostname = $fqdn.Split(".")[0]

            Write-Message -Level Debug -Message "Getting domain name from the remote host $fqdn"
            try {
                $ScBlock = {
                    return [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName
                }
                $cParams = @{
                    ComputerName = $fqdn
                }
                if ($Credential) { $cParams.Credential = $Credential }

                $conn = Get-DbaCmObject @cParams -ClassName win32_ComputerSystem -EnableException
                if ($conn) {
                    # update dns vars accordingly
                    $hostname = $conn.DNSHostname
                    $dnsDomain = $conn.Domain
                    $fqdn = "$hostname.$dnsDomain".TrimEnd('.')
                }
                try {
                    Write-Message -Level Debug -Message "Getting DNS domain from the remote host $fqdn"
                    $dnsSuffix = Invoke-Command2 @cParams -ScriptBlock $ScBlock -ErrorAction Stop -Raw
                } catch {
                    Write-Message -Level Verbose -Message "Unable to get DNS domain information from $fqdn"
                    $dnsSuffix = $dnsDomain
                }
            } catch {
                Write-Message -Level Verbose -Message "Unable to get domain name from $fqdn"
            }

            # building a finalized name from all the pieces
            if ($dnsSuffix) {
                $fullComputerName = $hostname + "." + $dnsSuffix
            } else {
                $fullComputerName = $fqdn
            }

            # getting a DNS host entry for the full name
            try {
                Write-Message -Level VeryVerbose -Message "Resolving $fullComputerName using .NET.Dns GetHostEntry"
                $hostentry = ([System.Net.Dns]::GetHostEntry($fullComputerName)).HostName
            } catch {
                Stop-Function -Message ".NET.Dns GetHostEntry failed for $fullComputerName" -ErrorRecord $_
                $hostentry = $null
            }

            # returning the final result
            return [PSCustomObject]@{
                InputName        = $computer
                ComputerName     = $fqdn
                IPAddress        = $ipaddress
                DNSHostName      = $hostname
                DNSDomain        = $dnsSuffix
                Domain           = $dnsDomain
                DNSHostEntry     = $hostentry
                FQDN             = $fqdn
                FullComputerName = $fullComputerName
            }
        }
    }
}