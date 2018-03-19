Param (

	[Parameter(Mandatory=$True)]
	[string]$SiteCollectionURL,
	[Parameter(Mandatory=$True)]
	[string]$SiteCollectionOwnerAlias,
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

##Clean up user name
if($SiteCollectionOwnerAlias.Contains('\')){
	$SiteCollectionOwnerAlias = $SiteCollectionOwnerAlias.Split('\')[1]
	$SiteCollectionOwnerAlias = $SiteCollectionOwnerAlias.Trim();
}
else{
	$SiteCollectionOwnerAlias = $SiteCollectionOwnerAlias.Trim();
}

##Create SH Site Collection
function CreateSite(){
	
	###Default WSP Location and Info
	$wspFilePath = 'D:\Scripts\Template.wsp';
	$wspFile = 'Template.wsp';
	$TemplateTitle = 'Template';

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

			#### Install and Add Site Solution to new site
			Write-Host -ForegroundColor White "Adding and Installing Site Template"
			Add-SPUserSolution -LiteralPath $wspFilePath -Site $SiteCollectionURL 

			do
			{
			  Write-Host "..." -NoNewline -ForeGroundColor Green;
			  Start-Sleep -Seconds 5;                                
			  try
			  {
				$testsolution = Get-SPUserSolution -Identity $wspFile -Site $SiteCollectionURL 
			  }
			  catch{
				Write-Host 'Get Solution Failed.' -ForegroundColor Red
			  }
			}while(!$testsolution);
			$ErrorActionPreference = "stop"

			Install-SPUserSolution -Identity $wspFile -Site $SiteCollectionURL
			Write-Host -ForegroundColor GREEN "Done installing Site Template."

			#### Apply Newly Installed Template
			$site = Get-SPSite $SiteCollectionURL
			$loc= [System.Int32]::Parse(1033)
			$WebTemplate = $site.GetWebTemplates($loc) | ?{$_.Title -eq $TemplateTitle};
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
	$ownerGroup.AllowMembersEditMembership = $true
	$ownerGroup.Update()

	## Members Group
	$web.SiteGroups.Add("$web Members", $web.Site.Owner, $web.Site.Owner, "Use this group to grant people contribute permissions to the $web site")
	$membersGroup = $web.SiteGroups["$web Members"]
	$membersGroup.AllowMembersEditMembership = $true
	$membersGroup.Update()

	## Visitors Group
	$web.SiteGroups.Add("$web Visitors", $web.Site.Owner, $web.Site.Owner, "Use this group to grant people read permissions to the $web site")
	$visitorsGroup = $web.SiteGroups["$web Visitors"]
	$visitorsGroup.AllowMembersEditMembership = $true
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

##Start Scripts
CreateSite
CreateSiteGroups
Write-Host "Site Collection Creation Completed." -ForegroundColor Green