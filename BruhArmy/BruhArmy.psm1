function Invoke-WebClone {
    param(
        [Parameter(Mandatory)]
        [String] $SourceResourcePool,
        [Parameter(Mandatory)]
        [String] $Target,
        [Parameter(Mandatory)]
        [int] $PortGroup,
        [Boolean] $CompetitionSetup=$True,
        [String] $Domain='sdc.cpp',
        [String] $WanPortGroup='0010_DefaultNetwork',
        [String] $Username,
        [String] $Password
    )

    $Tag = $SourceResourcePool.ToLower() + "_lab"

    Set-Tag $Tag

    New-VDPortgroup -VDSwitch Main_DSW -Name ( -join ($j, '_PodNetwork')) -VlanId $PortGroup | New-TagAssignment -Tag (Get-Tag -Name $Tag) | Out-Null

    New-PodUsers -Username $Username -Password $Password -Description $Tag -Domain $Domain

    $VAppName = -join ($PortGroup, '_Pod')
    New-VApp -Name $VAppName -Location (Get-ResourcePool -Name $Target -ErrorAction Stop) -ErrorAction Stop | New-TagAssignment -Tag $Tag

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

function Set-Tag {
    param(
        [Parameter(Mandatory)]
        [String] $Tag
    )

    try {
        Get-Tag -Name $Tag -ErrorAction Continue | Out-Null
    }
    catch {
        New-Tag -Name $Tag -Category (Get-TagCategory -Name CloneOnDemand) | Out-Null
    }
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
    if (!(Get-ResourcePool -Name $Target | Get-VM -Name *PodRouter)) {
        $name = $Target + "_PodRouter"
        $task = New-VM -Name $name `
            -ResourcePool $Target `
            -Datastore Ursula `
            -Template (Get-Template -Name $PFSenseTemplate) -RunAsync
        Wait-Task -Task $task | Out-Null
    }

    
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
    $SecurePassword = ConvertTo-SecureString -AsPlainText $Password -Force
    New-ADUser -Name $Username -ChangePasswordAtLogon $false -AccountPassword $SecurePassword -Enabled $true -Description $Description -UserPrincipalName (-join ($Username, '@', $Domain))
    Add-ADGroupMember -Identity 'RvB Competitors' -Members $Username

}

