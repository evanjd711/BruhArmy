function Invoke-WebClone {
    param(
        [Parameter(Mandatory)]
        [String] $SourceResourcePool,
        [Parameter(Mandatory)]
        [String] $Target,
        [Parameter(Mandatory)]
        [int] $FirstPodNumber,
        [Boolean] $CompetitionSetup=$True,
        [String] $Domain='sdc.cpp',
        [String] $WanPortGroup='0010_DefaultNetwork',
        [String] $Username,
        [String] $Password
    )

    $Tag = $SourceResourcePool.ToLower() + "_lab"
    $RandomTag = Generate-Tag

    Set-Tag $Tag
    Set-Tag $RandomTag

    $PortGroup = New-PodPortGroups -Portgroups 1 -StartPort $FirstPodNumber -EndPort ($FirstPodNumber + 100) -Tag $Tag -RandomTag $RandomTag -AssignPortGroups $true

    New-PodUsers -Username $Username -Password $Password -Description "$Tag $RandomTag" -Domain $Domain

    $VAppName = -join ($PortGroup[0], '_Pod')
    New-VApp -Name $VAppName -Location (Get-ResourcePool -Name $Target -ErrorAction Stop) -ErrorAction Stop | New-TagAssignment -Tag $Tag
    Get-VApp -Name $VAppName | New-TagAssignment -Tag $RandomTag

    # Creating the Roles Assignments on vSphere
    New-VIPermission -Role (Get-VIRole -Name '01_RvBCompetitors' -ErrorAction Stop) -Entity (Get-VApp -Name $VAppName) -Principal ($Domain.Split(".")[0] + '\' + $Username) | Out-Null

    New-PodRouter -Target $SourceResourcePool -PFSenseTemplate '1:1NAT_PodRouter'

    $VMsToClone = Get-ResourcePool -Name $SourceResourcePool | Get-VM

    Set-Snapshots -VMsToClone $VMsToClone

    $Tasks = foreach ($VM in $VMsToClone) {
        New-VM -VM $VM -Name ( -join (($PortGroup[0]), "_" + $VM.name)) -ResourcePool (Get-VApp -Name $VAppName).Name -LinkedClone -ReferenceSnapshot "SnapshotForCloning" -RunAsync
    }

    Wait-Task -Task $Tasks -ErrorAction Stop

    Configure-VMs -Target $VAppName -WanPortGroup $WanPortGroup

    Snapshot-NewVMs -Target $VAppName

}

function Snapshot-NewVMs {
    param(
        [Parameter(Mandatory)]
        [String] $Target
    )

    Get-VApp -Name $Target | Get-VM | ForEach-Object { New-Snapshot -VM $_ -Name 'Base' -Confirm:$false -RunAsync }
}

function Configure-VMs {
    param(
        [Parameter(Mandatory)]
        [String] $Target,
        [Parameter(Mandatory)]
        [String] $WanPortGroup
    )

    #Set Variables
    $Routers = Get-VApp -Name $Target -ErrorAction Stop | Get-VM | Where-Object -Property Name -Like '*PodRouter*'
    $VMs = Get-VApp -Name $Target -ErrorAction Stop | Get-VM | Where-Object -Property Name -NotLike '*PodRouter*'
                
    #Set VM Port Groups
    if ($VMs) {
        $VMs | 
            ForEach-Object { 
                Get-NetworkAdapter -VM $_ -Name "Network adapter 1" -ErrorAction Stop | 
                    Set-NetworkAdapter -Portgroup (Get-VDPortGroup -name ( -join ($_.Name.Split("_")[0], '_PodNetwork'))) -Confirm:$false -RunAsync | Out-Null
            }
    }
    #Configure Routers
    $Routers | 
        ForEach-Object {

        #Set Port Groups
        Get-NetworkAdapter -VM $_ -Name "Network adapter 1" -ErrorAction Stop | 
            Set-NetworkAdapter -Portgroup (Get-VDPortgroup -Name $WanPortGroup) -Confirm:$false | Out-Null
        Get-NetworkAdapter -VM $_ -Name "Network adapter 2" -ErrorAction Stop | 
            Set-NetworkAdapter -Portgroup (Get-VDPortGroup -name ( -join ($_.Name.Split("_")[0], '_PodNetwork'))) -Confirm:$false | Out-Null
        }

        $tasks = Get-VApp -Name $Target | Get-VM -Name *PodRouter | Start-VM -RunAsync

        Wait-Task -Task $tasks -ErrorAction Stop | Out-Null

        $credpath = $env:USERPROFILE + "\pfsense_cred.xml"

        Get-VApp -Name $Target | 
            Get-VM -Name *PodRouter |
                Select -ExpandProperty name | 
                    ForEach-Object { 
                        $oct = $_.split("_")[0].substring(2)
                        $oct -replace '^0+', ''
                        Invoke-VMScript -VM $_ -ScriptText "sed 's/172.16.254/172.16.$Oct/g' /cf/conf/config.xml > tempconf.xml; cp tempconf.xml /cf/conf/config.xml; rm /tmp/config.cache; /etc/rc.reload_all start" -GuestCredential (Import-CliXML -Path $credpath) -ScriptType Bash -ToolsWaitSecs 120 -RunAsync | Out-Null
                    }
}

function Create-NewVMs {
    param(
        [Parameter(Mandatory)]
        [String[]] $VMsToClone,
        [Parameter(Mandatory)]
        [String] $Target,
        [Parameter(Mandatory)]
        [String] $PortGroup
    )

    

    return $Tasks
}

function Set-Snapshots {
    param(
        [Parameter(Mandatory)]
        [String[]] $VMsToClone
    )

    $VMsToClone | ForEach-Object {
        if (Get-Snapshot -VM $_ | Where-Object name -eq SnapshotForCloning) {
            return
        }
        New-Snapshot -VM $_ -Name SnapshotForCloning
    }
}

function Generate-Tag {
    $TokenSet = @{
        U = [Char[]]'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
        L = [Char[]]'abcdefghijklmnopqrstuvwxyz'
    }

    $Upper = Get-Random -Count 10 -InputObject $TokenSet.U
    $Lower = Get-Random -Count 10 -InputObject $TokenSet.L

    $StringSet = $Upper + $Lower

    return (Get-Random -Count 20 -InputObject $StringSet) -join ''
    
}

function Set-Tag {
    param(
        [Parameter(Mandatory)]
        [String] $Tag
    )

    try {
        Get-Tag -Name $Tag -ErrorAction Stop | Out-Null
    }
    catch {
        New-TagCategory -Name $Tag -Description $tag -EntityType VApp, DistributedPortGroup, VM | Out-Null
        New-Tag -Name $Tag -Category (Get-TagCategory -Name $Tag) | Out-Null
    }
}

#Create Port Groups
function New-PodPortGroups {

    param(
        [ValidateRange(1, 100)]
        [Parameter(Mandatory = $true)]
        [int] $Portgroups,
        [ValidateRange(1000, 4000)]
        [Parameter(Mandatory = $true)]
        [int] $StartPort,
        [ValidateRange(1000, 4000)]
        [Parameter(Mandatory = $true)]
        [int] $EndPort,
        [String] $Tag,
        [String] $RandomTag,
        [Boolean] $AssignPortGroups

    )

    $ErrorActionPreference = "Stop"

    # Gets the list of existing port groups in the range
    $PortGroupList = Get-VDPortgroup -VDSwitch Main_DSW | Select-Object -ExpandProperty name | Sort-Object
    $PortGroupList = $PortGroupList | 
    ForEach-Object {
        [int]$PortGroupList[$PortGroupList.indexOf($_)].Substring(0, $PortGroupList[$PortGroupList.indexOf($_)].indexOf('_'))
    }
    $PortGroupList = $PortGroupList.where{ $_ -IN $StartPort..$EndPort }
    # Check if Port Groups can be created
    if ($EndPort - $StartPort - $PortGroupList.Count + 1 -lt $Portgroups) {
        $temp = $EndPort - $StartPort - $PortGroupList.Count + 1
        Write-Error -Message "There are not enough port groups available in this range. Only $temp can be created."
    }

    # Creates the port groups
    $j = $StartPort
    $i = 0
    While ($i -le $Portgroups - 1) {
        if ($PortGroupList.IndexOf($j) -ne -1) { $j++; continue }
        if ($j -gt $EndPort) { Write-Error -Message "There are no more available port groups in the specified range." }
        else {
            if ($AssignPortGroups) {
                Write-Host "Creating Port Group $j..."
                New-VDPortgroup -VDSwitch Main_DSW -Name ( -join ($j, '_PodNetwork')) -VlanId $j | Out-Null
                if ($Tag) {
                    Get-VDPortGroup -Name ( -join ($j, '_PodNetwork')) | New-TagAssignment -Tag (Get-Tag -Name $Tag) | Out-Null
                    Get-VDPortGroup -Name ( -join ($j, '_PodNetwork')) | New-TagAssignment -Tag (Get-Tag -Name $RandomTag) | Out-Null
                }
            }
            $j
            $j++
            $i++
        }
    }
    return $CreatedPortGroups
}

# Creates a pfSense Router for the vApp 
function New-PodRouter {

    param (
        [Parameter(Mandatory = $true)]
        [String] $Target,
        [Parameter(Mandatory = $true)]
        [String] $PFSenseTemplate

    )

    # Creating the Router
    $name = $Target + "_PodRouter"
    $task = New-VM -Name $name `
        -ResourcePool $Target `
        -Datastore Ursula `
        -Template (Get-Template -Name $PFSenseTemplate) -RunAsync

    Wait-Task -Task $task
} 

function New-PodUsers {

    param(
        [Parameter(Mandatory = $true)]
        [String] $Description,
        [Parameter(Mandatory = $true)]
        [String] $Domain,
        [Parameter(Mandatory = $true)]
        [String] $Username,
        [Parameter(Mandatory = $true)]
        [String] $Password
    )

    # Creating the User Accounts
    Import-Module ActiveDirectory
    $file = ( -join ("$env:USERPROFILE\Desktop\", $Description , "Users.txt"))
    $SecurePassword = ConvertTo-SecureString -AsPlainText $Password -Force
    New-ADUser -Name $Username -ChangePasswordAtLogon $false -AccountPassword $SecurePassword -Enabled $true -Description $Description -UserPrincipalName (-join ($Username, '@', $Domain)) | Out-Null
    Add-ADGroupMember -Identity 'RvB Competitors' -Members $Username
    
    #Append User to CSV
    $out = "$Name,$Password"
    $out | Out-File $file -Append -Force

}

