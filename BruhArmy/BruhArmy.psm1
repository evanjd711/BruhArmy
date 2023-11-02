function Invoke-WebClone {
    param(
        [Parameter(Mandatory)]
        [String] $SourceResourcePool,
        [Parameter(Mandatory)]
        [String] $Target,
        [Parameter(Mandatory)]
        [int] $PortGroup,
        [Parameter(Mandatory)]
        [String] $Domain,
        [Parameter(Mandatory)]
        [String] $WanPortGroup,
        [Parameter(Mandatory)]
        [String] $Username
    )

    if (Get-TagAssignment -Entity (Get-ResourcePool $SourceResourcePool) -Tag koth-attacker -ErrorAction Stop) {
        $IP = Invoke-KothClone -SourceResourcePool $SourceResourcePool -Domain $Domain -Username $Username
        return $IP
    }

    # Creating the Tag
    $Tag = -join ($PortGroup, "_", $SourceResourcePool.ToLower(), "_lab_$Username")

    try {
        Get-Tag -Name $Tag -ErrorAction Stop | Out-Null
    }
    catch {
        New-Tag -Name $Tag -Category (Get-TagCategory -Name CloneOnDemand) | Out-Null
    }

    # Creating the Port Group
    $PortGroupOptions = @{
        VDSwitch = 'Main_DSW';
        Name = ( -join ($PortGroup, '_PodNetwork'));
        VlanId = $PortGroup;
    }

    New-VDPortgroup @PortGroupOptions | New-TagAssignment -Tag (Get-Tag -Name $Tag) | Out-Null

    # Create the vApp
    $VAppOptions = @{
        Name = $Tag;
        Location = (Get-ResourcePool -Name $Target -ErrorAction Stop);
        InventoryLocation = (Get-Inventory -Name "07-Kamino");
    }
    New-VApp @VAppOptions -ErrorAction Stop | New-TagAssignment -Tag $Tag
    
    # Creating the Router
    $IsNatted = $false
    if (Get-TagAssignment -Entity (Get-ResourcePool -Name $SourceResourcePool) -Tag 'natted' -ErrorAction stop) {
        $IsNatted = $true
    }

    $Tasks = @()
    if (!(Get-ResourcePool -Name $SourceResourcePool | Get-VM -Name "*PodRouter")) {
        if ($IsNatted) {
            $Tasks += New-PodRouter -Target $SourceResourcePool -PFSenseTemplate '1:1NAT_PodRouter'
        } else {
            $Tasks += New-PodRouter -Target $SourceResourcePool -PFSenseTemplate 'pfSense blank'
        }
    }

    # Cloning the VMs
    $VMsToClone = Get-ResourcePool -Name $SourceResourcePool | Get-VM

    Set-Snapshots -VMsToClone $VMsToClone

    $Tasks += foreach ($VM in $VMsToClone) {
        $VMOptions = @{
            VM = $VM;
            Name = (-join ($PortGroup, "_", $VM.name));
            ResourcePool = $Tag;
            ReferenceSnapshot = "SnapshotForCloning";
            Location = (Get-Inventory -Name "07-Kamino");
        }
        New-VM @VMOptions -LinkedClone -RunAsync 
    }

    Wait-Task -Task $Tasks -ErrorAction Stop

    if ((Get-ADUser -Identity $Username -Properties MemberOf | Select-Object -ExpandProperty MemberOf) -cnotcontains "CN=SDC Admins,CN=Users,DC=sdc,DC=cpp") {
        #Hidding VMs
        $hidden = $VMsToClone | Get-TagAssignment -Tag 'hidden' | Select-Object -ExpandProperty Entity | Select-Object -ExpandProperty Name
        $hidden | ForEach-Object {
            $VMRoleOptions = @{
                Role = (Get-VIRole -Name 'NoAccess' -ErrorAction Stop);
                Entity = (Get-VM -Name (-join ($PortGroup, '_', $_)));
                Principal = ($Domain.Split(".")[0] + '\' + $Username)
            }
            New-VIPermission @VMRoleOptions | Out-Null
        }
        # Creating the VApp Role Assignment
        $VAppRoleOptions = @{
            Role = (Get-VIRole -Name '07_KaminoUsers' -ErrorAction Stop);
            Entity = (Get-VApp -Name $Tag);
            Principal = ($Domain.Split(".")[0] + '\' + $Username)
        }
        New-VIPermission @VAppRoleOptions | Out-Null
    }

    # Configuring the VMs
    if ($IsNatted) {
        Configure-VMs -Target $Tag -WanPortGroup $WanPortGroup -Nat
    } else {
        Configure-VMs -Target $Tag -WanPortGroup $WanPortGroup
    }
    Snapshot-NewVMs -Target $Tag

    Configure-StartOrder -tag $Tag
}

function Invoke-KothClone {
    param(
        [Parameter(Mandatory)]
        [String] $SourceResourcePool,
        [Parameter(Mandatory=$false)]
        [String] $Target="07-02_Pods",
        [Parameter(Mandatory)]
        [String] $Domain,
        [Parameter(Mandatory=$false)]
        [String] $WanPortGroup="0040_RvBCoreNetwork",
        [Parameter(Mandatory)]
        [String] $Username
    )

    # Creating the Tag
    $Tag = -join ($Username, "_", $SourceResourcePool.ToLower())

    try {
        Get-Tag -Name $Tag -ErrorAction Stop | Out-Null
    }
    catch {
        New-Tag -Name $Tag -Category (Get-TagCategory -Name CloneOnDemand) | Out-Null
    }

    # Create the vApp
    $VAppOptions = @{
        Name = $Tag;
        Location = (Get-ResourcePool -Name $Target -ErrorAction Stop);
        InventoryLocation = (Get-Inventory -Name "07-Kamino");
    }
    New-VApp @VAppOptions -ErrorAction Stop | New-TagAssignment -Tag $Tag | Out-Null

    # Cloning the VMs
    $VMsToClone = Get-ResourcePool -Name $SourceResourcePool | Get-VM

    Set-Snapshots -VMsToClone $VMsToClone | Out-Null
 
    foreach ($VM in $VMsToClone) {
        $VMOptions = @{
            VM = $VM;
            Name = (-join ($Username, "_", $VM.name));
            ResourcePool = $Tag;
            ReferenceSnapshot = "SnapshotForCloning";
            Location = (Get-Inventory -Name "07-Kamino");
            VMHost = (Get-VMHost -Name "rex.sdc.cpp")
        }
        New-VM @VMOptions -LinkedClone | Out-Null
    }
    
    # Configure VMs
    Get-NetworkAdapter -VM (-join ($Username, "_", $VM.name)) -Name "Network adapter 1" -ErrorAction Stop | 
        Set-NetworkAdapter -Portgroup (Get-VDPortGroup -name $WanPortGroup) -Confirm:$false -RunAsync | Out-Null

    Snapshot-NewVMs -Target $Tag | Out-Null

    Get-VApp -Name $Tag | Get-VM | Start-VM -Confirm:$false | Out-Null

    while (!$IP) {    
        $IP = (Get-VM -Name (-join ($Username, "_", $VM.name))).guest.IPAddress[0]
        Start-Sleep 5
    }
    return $IP
}

function Snapshot-NewVMs {
    param(
        [Parameter(Mandatory)]
        [String] $Target
    )

    $task = Get-VApp -Name $Target | Get-VM | ForEach-Object { New-Snapshot -VM $_ -Name 'Base' -Confirm:$false -RunAsync }
    Wait-Task -task $task
}

function Configure-VMs {
    param(
        [Parameter(Mandatory)]
        [String] $Target,
        [Parameter(Mandatory)]
        [String] $WanPortGroup,
        [switch] $Nat
    )

    #Set Variables
    $Routers = Get-VApp -Name $Target -ErrorAction Stop | Get-VM | Where-Object -Property Name -Like '*pfSense*'
    $Routers += Get-VApp -Name $Target -ErrorAction Stop | Get-VM | Where-Object -Property Name -Like '*1:1*'
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
    if ($Routers) {
    
    $Routers | 
        ForEach-Object {

        #Set Port Groups
        Get-NetworkAdapter -VM $_ -Name "Network adapter 1" -ErrorAction Stop | 
            Set-NetworkAdapter -Portgroup (Get-VDPortgroup -Name $WanPortGroup) -Confirm:$false | Out-Null
        Get-NetworkAdapter -VM $_ -Name "Network adapter 2" -ErrorAction Stop | 
            Set-NetworkAdapter -Portgroup (Get-VDPortGroup -name ( -join ($_.Name.Split("_")[0], '_PodNetwork'))) -Confirm:$false | Out-Null
        }

        if ($Nat) {
            $tasks = Get-VApp -Name $Target | Get-VM -Name "*1:1*" | Start-VM -RunAsync

            Wait-Task -Task $tasks -ErrorAction Stop | Out-Null

            $credpath = $env:ProgramFiles + "\Kamino\lib\creds\pfsense_cred.xml"

            Get-VApp -Name $Target | 
                Get-VM -Name "*1:1*" |
                    Select-Object -ExpandProperty name | 
                        ForEach-Object { 
                            $oct = $_.split("_")[0].substring(2)
                            $oct = $oct -replace '^0+', ''
                            $task = Invoke-VMScript -VM $_ -ScriptText "sed 's/172.16.254/172.16.$Oct/g' /cf/conf/config.xml > tempconf.xml; cp tempconf.xml /cf/conf/config.xml; rm /tmp/config.cache; /etc/rc.reload_all start" -GuestCredential (Import-CliXML -Path $credpath) -ScriptType Bash -ToolsWaitSecs 120 -RunAsync
                            Wait-Task -Task $task
                        }
        }
    }
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

# Creates a pfSense Router for the vApp 
function New-PodRouter {

    param (
        [Parameter(Mandatory = $true)]
        [String] $Target,
        [Parameter(Mandatory = $true)]
        [String] $PFSenseTemplate

    )

    if ($PFSenseTemplate -eq "1:1NAT_PodRouter") { 
        $VMParameters = @{
            Datastore = 'Ursula';
            Template = (Get-Template -Name $PFSenseTemplate);
            Name = $Target.Split("_")[0] + "_1:1_PodRouter";
            ResourcePool = $Target
        } 
    } else {
        $VMParameters = @{
            Datastore = 'Ursula';
            Template = (Get-Template -Name $PFSenseTemplate);
            Name = $Target.Split("_")[0] + "_pfSense_PodRouter";
            ResourcePool = $Target
        }
    }

    $task = New-VM @VMParameters -RunAsync
    return $task  
} 

function New-PodUser {

    param(
        [Parameter(Mandatory = $true)]
        [String] $Username,
        [Parameter(Mandatory = $true)]
        [String] $Password
    )

    
    try { 
        Get-ADUser -Identity $Username
        Write-Error "Username $Username is not available."
        exit 1
    }
    catch {
        $Domain='sdc.cpp'
        # Creating the User Accounts
        $SecurePassword = ConvertTo-SecureString -AsPlainText $Password -Force
        New-ADUser -Name $Username -ChangePasswordAtLogon $false -AccountPassword $SecurePassword -Enabled $true -Description "Registered Kamino User" -UserPrincipalName (-join ($Username, '@', $Domain)) -Path "OU=Kamino Users,DC=sdc,DC=cpp"
        Add-AdGroupMember -Identity 'Kamino Users' -Members $Username
    }
    
}

function Invoke-OrderSixtySix {
    param (
        [String] $Username,
        [String] $Tag
    )

    if (!$Tag) {
        if ($Username) {
            $Targets = "*lab_$Username"
            $task = Get-VApp -Tag $Targets | Get-VM | Stop-VM -Confirm:$false -RunAsync -ErrorAction Ignore
            Wait-Task -Task $task -ErrorAction Ignore
            $task = Get-VApp -Tag $Targets | Remove-VApp -DeletePermanently -Confirm:$false
            Wait-Task -Task $task -ErrorAction Ignore
            Get-VDPortgroup -Name $Targets | Remove-VDPortgroup -Confirm:$false
        }
    }   

    if ($Tag) {
        $Targets = -join ('*', $Tag, '*')
        $task = Get-VApp -Tag $Targets | Get-VM | Stop-VM -Confirm:$false -RunAsync
        Wait-Task -Task $task -ErrorAction Ignore
        $task = Get-VApp -Tag $Targets | Remove-VApp -DeletePermanently -Confirm:$false
        Wait-Task -Task $task -ErrorAction Ignore
        $task = Get-VDPortgroup -Tag $Targets | Remove-VDPortgroup -Confirm:$false
        Wait-Task -Task $task -ErrorAction Ignore
        Get-Tag -Name $Targets | Remove-Tag -Confirm:$false
    }
}


function Invoke-CustomPod {
    param(
        [Parameter(Mandatory)]
        [String] $LabName,
        [Parameter(Mandatory)]
        [String[]] $VMsToClone,
        [Parameter(Mandatory)]
        [String] $Target,
        [Parameter(Mandatory)]
        [int] $PortGroup,
        [Parameter(Mandatory)]
        [String] $Domain,
        [Parameter(Mandatory)]
        [Boolean] $Natted,
        [Parameter(Mandatory)]
        [String] $WanPortGroup,
        [Parameter(Mandatory)]
        [String] $Username
    )

    # Creating the Tag
    $Tag = -join ($PortGroup, "_", $LabName, "_lab_$Username")

    try {
        Get-Tag -Name $Tag -ErrorAction Stop | Out-Null
    }
    catch {
        New-Tag -Name $Tag -Category (Get-TagCategory -Name CloneOnDemand) | Out-Null
    }

    # Creating the Port Group
    $PortGroupOptions = @{
        VDSwitch = 'Main_DSW';
        Name = ( -join ($PortGroup, '_PodNetwork'));
        VlanId = $PortGroup;
    }

    New-VDPortgroup @PortGroupOptions | New-TagAssignment -Tag (Get-Tag -Name $Tag) | Out-Null

    $VAppOptions = @{
        Name = $Tag;
        Location = (Get-ResourcePool -Name $Target -ErrorAction Stop);
        InventoryLocation = (Get-Inventory -Name "07-Kamino");
    }

    New-VApp @VAppOptions -ErrorAction Stop | New-TagAssignment -Tag $Tag

    # Cloning the VMs
    $Tasks += foreach ($VM in $VMsToClone) {
        $VMOptions = @{
            Name = (-join ($PortGroup, '_', $VM.Substring(0, $VM.Length - 6)));
            Template = (Get-Template -Name $VM);
            Datastore = 'Ursula';
            DiskStorageFormat = 'Thin';
            ResourcePool = $Tag;
            Location = (Get-Inventory -Name "07-Kamino")
        }
        New-VM @VMOptions -RunAsync
    }
    Wait-Task -Task $Tasks

    if ((Get-ADUser -Identity $Username -Properties MemberOf | Select-Object -ExpandProperty MemberOf) -cnotcontains "CN=SDC Admins,CN=Users,DC=sdc,DC=cpp") {
        $PermissionOptions = @{
            Role = (Get-VIRole -Name '08_KaminoUsersCustomPod');
            Entity = (Get-VApp -Name $Tag);
            Principal = ($Domain.Split(".")[0] + '\' + $Username)
        }
        New-VIPermission @PermissionOptions | Out-Null
    }
    
    if ($Natted) {
        Configure-VMs -Target $Tag -WanPortGroup $WanPortGroup -Nat
    } else {
        Configure-VMs -Target $Tag -WanPortGroup $WanPortGroup
    }
    
    Snapshot-NewVMs -Target $Tag

    # Set VM Start Order
    Configure-StartOrder -tag $Tag
}

function Configure-StartOrder {
    param (
        [Parameter(Mandatory)]
        [String] $tag
    )

    # Set VM Start Order
    $VApp = Get-VApp -Name $Tag
    $spec = New-Object VMware.Vim.VAppConfigSpec
    $spec.EntityConfig = $VApp.ExtensionData.VAppConfig.EntityConfig
    $spec.EntityConfig | ForEach-Object {
        $_.StartOrder = 1
    }
    $VApp.ExtensionData.UpdateVAppConfig($spec)
}
