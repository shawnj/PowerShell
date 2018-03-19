Param (

	[Parameter(Mandatory=$True)]
	[string]$SiteCollectionURL,
	[Parameter(Mandatory=$True)]
	[string]$SiteCollectionOwnerAlias,
	[Parameter(Mandatory=$True)]
	[string]$SiteCollectionSecondaryOwnerAlias,
	[Parameter(Mandatory=$True)]
	[string]$SiteCollectionTitle
)

Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction SilentlyContinue


#region Setup Site

function GetUserId($user){
	$userclaimID = ''
	$dll = [reflection.assembly]::LoadFrom("C:\Windows\Microsoft.NET\assembly\GAC_64\OptimalIdM.VIS.ClaimsProvider\v4.0_3.0.0.0__250ddff01267d7a5\OptimalIdM.VIS.ClaimsProvider.dll")
	$caSite = [System.Uri] (Get-spwebapplication -includecentraladministration | where {$_.DisplayName -eq "SharePoint Central Administration v4"}).Url
	$optimal = New-Object OptimalIdM.VIS.ClaimsProvider.opVISClaimsProvider("VDS")
	if($optimal -ne $null -and $caSite)
	{
		$Searchuser = $optimal.Resolve($caSite, $optimal.EntityTypes(), $user)
		if($Searchuser.Count -gt 0)
		{
			$userclaimID = $Searchuser.Key
			return $userclaimID;
		}
		else
		{
			write-host "Could not find the User Claim ID: " $user
			return $userclaimID;
		}
	}
}

##Clean up user names
if($SiteCollectionOwnerAlias.Contains('\')){
	$SiteCollectionOwnerAlias = $SiteCollectionOwnerAlias.Split('\')[1]
	$SiteCollectionOwnerAlias = $SiteCollectionOwnerAlias.Trim();
}
else{
	$SiteCollectionOwnerAlias = $SiteCollectionOwnerAlias.Trim();
}

if($SiteCollectionSecondaryOwnerAlias.Contains('\')){
	$SiteCollectionSecondaryOwnerAlias = $SiteCollectionSecondaryOwnerAlias.Split('\')[1]
	$SiteCollectionSecondaryOwnerAlias = $SiteCollectionSecondaryOwnerAlias.Trim();
}
else{
	$SiteCollectionSecondaryOwnerAlias = $SiteCollectionSecondaryOwnerAlias.Trim();
}

##Create SH Site Collection
function CreateSite(){
	
	###Get Users VDS Key for Farm Account to be Site Admin
	$OwnerAlias = GetUserId('Farm-Account');

	if($OwnerAlias -ne ''){
		try{
			write-host "Checking if site exists..."
			if((Get-SPSite $SiteCollectionURL -ErrorAction SilentlyContinue) -ne $null){
				Write-Host "Site Exists.  Please create a site with a different name." -ForegroundColor Yellow
				break
			}
			
			Write-Host "Creating Site..." -ForegroundColor Green
			$site = New-SPSite -Url $SiteCollectionURL  -Name $SiteCollectionTitle -OwnerAlias $OwnerAlias
			if($site -eq $null){
				Write-Host "Site couldn't be created.  Please check URL and try again." -ForegroundColor Red
				break
			}

			#### Apply Newly Installed Template
			$site = Get-SPSite $SiteCollectionURL
			$loc= [System.Int32]::Parse(1033)
			$WebTemplate = $site.GetWebTemplates($loc) | ?{$_.Title -eq 'Team Site'};
			$site.Dispose()

			Write-Host "Applying Web Template to new Site..." -ForegroundColor Green

			$web = Get-SPWeb $SiteCollectionUrl
			$web.ApplyWebTemplate($WebTemplate.Name)

			$web.Dispose();

			Write-Host "Site Created Successfully." -ForegroundColor Green
			Write-Host "Site URL:" $SiteCollectionURL

		}
		catch{

			Write-Host "Error occured during site creation." -ForegroundColor Red
			Write-Host $_.Exception.Message -ForegroundColor Red

			#### Remove Site if created
			if((Get-SPSite $SiteCollectionURL -ErrorAction SilentlyContinue) -ne $null){
				#Remove-SPSite $SiteCollectionURL -Confirm:$false;
				#Write-Host "Site Removed." -ForegroundColor Red
			}
			break
		}

	}
	else{
	
		Write-Host "User does not exist." -ForegroundColor Red
		break

	}
}
#endregion

#region Create Groups
function CreateSiteGroups(){
	Write-Host "Creating Site Groups..."
	## Create the new groups
	$web = Get-SPWeb $SiteCollectionURL

	## Remove unnecessary groups/users from the site permissions
	for ($i = $web.RoleAssignments.Count > 1; $i -ge 0; $i++)
	{
		$web.RoleAssignments.Remove($i)
	} 

	## Owner Group
	$web.SiteGroups.Add("$web Owners", $web.Site.Owner, $web.Site.Owner, "Use this group to grant people full control permissions to the $web site")
	$ownerGroup = $web.SiteGroups["$web Owners"]
	$ownerGroup.AllowMembersEditMembership = $false
	$ownerGroup.OnlyAllowMembersViewMembership = $false
	$ownerGroup.Owner = $ownerGroup
	$ownerGroup.Update()

	## Members Group
	$web.SiteGroups.Add("$web Members", $web.Site.Owner, $web.Site.Owner, "Use this group to grant people contribute permissions to the $web site")
	$membersGroup = $web.SiteGroups["$web Members"]
	$membersGroup.AllowMembersEditMembership = $false
	$membersGroup.OnlyAllowMembersViewMembership = $false
	$membersGroup.Owner = $ownerGroup
	$membersGroup.Update()

	## Visitors Group
	$web.SiteGroups.Add("$web Visitors", $web.Site.Owner, $web.Site.Owner, "Use this group to grant people read permissions to the $web site")
	$visitorsGroup = $web.SiteGroups["$web Visitors"]
	$visitorsGroup.AllowMembersEditMembership = $false
	$visitorsGroup.OnlyAllowMembersViewMembership = $false
	$visitorsGroup.Owner = $ownerGroup
	$visitorsGroup.Update()

	###### Create a new assignment (group and permission level pair) which will be added to the web object

	$ownerGroupAssignment = new-object Microsoft.SharePoint.SPRoleAssignment($ownerGroup)
	$membersGroupAssignment = new-object Microsoft.SharePoint.SPRoleAssignment($membersGroup)
	$visitorsGroupAssignment = new-object Microsoft.SharePoint.SPRoleAssignment($visitorsGroup)

	###### Get the permission levels to apply to the new groups

	$ownerRoleDefinition = $web.Site.RootWeb.RoleDefinitions["Full Control"]
	$membersRoleDefinition = $web.Site.RootWeb.RoleDefinitions["Contribute"]
	$visitorsRoleDefinition = $web.Site.RootWeb.RoleDefinitions["Read"]

	###### Assign the groups the appropriate permission level

	$ownerGroupAssignment.RoleDefinitionBindings.Add($ownerRoleDefinition)
	$membersGroupAssignment.RoleDefinitionBindings.Add($membersRoleDefinition)
	$visitorsGroupAssignment.RoleDefinitionBindings.Add($visitorsRoleDefinition)

	###### Add the groups with the permission level to the site

	$web.RoleAssignments.Add($ownerGroupAssignment)
	$web.RoleAssignments.Add($membersGroupAssignment)
	$web.RoleAssignments.Add($visitorsGroupAssignment)

	##Add user to Owners Site
	try {
		$OwnerAlias = GetUserId($SiteCollectionOwnerAlias); 
		$user = $web.EnsureUser($OwnerAlias)
		$ownerGroup.AddUser($user)
		     
        Write-Host "$user.Name added to $ownerGroup "   
    } 
	catch {
        Write-Host "$OwnerAlias could not be added to $ownerGroup "
    }

	##Add Secondary Owner user to Owners Site
	if($SiteCollectionSecondaryOwnerAlias -ne $null)
	{
		try {
			$SecondaryOwnerAlias = GetUserId($SiteCollectionSecondaryOwnerAlias); 
			$user = $web.EnsureUser($SecondaryOwnerAlias)
			$ownerGroup.AddUser($user)
		     
			Write-Host "$user.Name added to $ownerGroup "   
		} 
		catch {
			Write-Host "$OwnerAlias could not be added to $ownerGroup "
		}
	}

	$web.Update()
	$web.Dispose()

	Write-Host "Site Groups Created." -ForegroundColor Green
}

#endregion

#region not used - Apply Alternate CSS URL
function ApplyAltCSS(){
	
	$Web = Get-SPWeb $SiteCollectionURL 	
	$web.AlternateCssUrl = "https://example.com/Assets/sh_custom.css" 
	$web.AllProperties["__InheritsAlternateCssUrl"] = $True 
	$web.Update() 
	$web.Dispose()

	Write-Host "CSS updated at:" $web.Url -foregroundcolor Green
}
#endregion

#region remove all Site Templates except Team Site
function RemoveWebTemplates(){
	Write-Host 'Removing Web Templates...' -ForegroundColor Green

	try{
		Start-SPAssignment -Global

		#Get Site and Team Site Template then Set that Template as only available template.
		$site = Get-SPSite $SiteCollectionURL
		$template = $site.GetWebTemplates(1033) | ?{$_.Title -eq 'Team Site'}
		$web = $site.RootWeb

		if($template -ne $null){
			$web.SetAvailableWebTemplates($template, 1033)
			$web.Update()
		}

		$web.Dispose()
		$site.Dispose()
		Stop-SPAssignment -Global
		Write-Host "Templates Removed." -ForegroundColor Green

	}
	catch{
		Write-Host "Error Removing Web Template" -ForegroundColor Red
		Write-Host $_.Exception.Message
	}
}

#endregion

#region
function RemoveSocialWebParts(){
	Write-Host "Removing Social Web Parts..."
	try{
		$webParts = @();
		$site = Get-SPSite $SiteCollectionURL
		$web = $site.RootWeb
		$wpCatlog =[Microsoft.SharePoint.SPListTemplateType]::WebPartCatalog
		$list = $site.GetCatalog($wpCatlog)

		$wpID = New-Object System.Collections.ObjectModel.Collection[System.Int32]

		foreach ($item in $list.Items)
		{
		  if($item.DisplayName.ToLower().Equals("sitefeed") `
			-or $item.DisplayName.ToLower().Equals("tagcloud") `
			-or $item.DisplayName.ToLower().Equals("socialcomment") `
			-or $item.DisplayName.ToLower().Equals("profilebrowser") `
			-or $item.DisplayName.ToLower().Equals("msusertasks") `
		  )
		  {   
			$wpID.Add($item.ID) 
		  }
		}

		foreach($wp in $wpID)
		{  
		   $wpItem = $list.GetItemById($wp)
		   $wpItem.Delete()
		}
		$list.Update()    

		Write-Host "Social Web Parts Removed"

	}
	catch{
		Write-Host "Error Removing Social Web Parts"
	}

}
#endregion

##Start Scripts
CreateSite
CreateSiteGroups
RemoveWebTemplates
RemoveSocialWebParts
Write-Host "Site Collection Creation Completed." -ForegroundColor Green