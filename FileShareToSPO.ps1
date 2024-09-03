#Original Script from SharePoint Diaries: https://www.sharepointdiary.com/2020/07/sync-file-share-to-sharepoint-online-using-powershell.html
#Fixed issues with datetime formatting for non-US dates and updated to use PnP.PowerShell 


Import-Module PnP.PowerShell 
#Function to Import Files from Fileshare to SharePoint Online
Function Import-FileShareToSPO
{
 param
    (
        [Parameter(Mandatory=$true)] [string] $SiteURL,
        [Parameter(Mandatory=$true)] [string] $SourceFolderPath,
        [Parameter(Mandatory=$true)] [string] $TargetLibraryName,            
        [Parameter(Mandatory=$true)] [string] $LogFile
    )
 
    Try {
        Add-content $Logfile -value "`n---------------------- Import FileShare Script Started: $(Get-date -format 'dd/MM/yyy hh:mm:ss tt')-------------------"  
     
        #Get Number of Source Items from the Source Folder
        $SourceItemsCount =  (Get-ChildItem -Path $SourceFolderPath -Recurse).count
 
        #Get the Target Library to Upload
        $Web = Get-PnPWeb
        $Library = Get-PnPList $TargetLibraryName -Includes RootFolder
        $TargetFolder = $Library.RootFolder
 
        #Get the site relative path of the target folder
        If($web.ServerRelativeURL -eq "/")
        {
            $TargetFolderSiteRelativeURL = $TargetFolder.ServerRelativeUrl
        }
        Else
        {        
            $TargetFolderSiteRelativeURL = $TargetFolder.ServerRelativeURL.Replace($Web.ServerRelativeUrl,[string]::Empty) 
        }  
  
        #Get All Items from the Source
        $SourceItems = Get-ChildItem -Path $SourceFolderPath -Recurse
        $Source = @($SourceItems | Select FullName,  PSIsContainer,
                                     @{Label='TargetItemURL';Expression={$_.FullName.Replace($SourceFolderPath,$TargetFolderSiteRelativeURL).Replace("\","/")}}, 
                                            @{Label='LastUpdated';Expression={$_.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ss')}})
 
        #Get All Files from the target document library - In batches of 2000
        $TargetFiles = Get-PnPListItem -List $TargetLibraryName -PageSize 2000
        $Target = @($TargetFiles | Select @{Label='FullName';Expression={$_.FieldValues.FileRef.Replace($TargetFolder.ServerRelativeURL,$SourceFolderPath).Replace("/","\")}},
                                                @{Label='PSIsContainer';Expression={$_.FileSystemObjectType -eq "Folder"}},
                                                    @{Label='TargetItemURL';Expression={$_.FieldValues.FileRef.Replace($Web.ServerRelativeUrl,[string]::Empty)}},
                                                        @{Label='LastUpdated';Expression={$_.FieldValues.Modified.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')}})
 
        #Compare Source and Target and upload/update files that are not in the target
        $Counter = 1
        $FilesDiff = Compare-Object -ReferenceObject $Source -DifferenceObject $Target -Property FullName, PSIsContainer, TargetItemURL, LastUpdated
        #$FilesDiff | Export-csv -path "C:\Temp\diff.csv" -NoTypeInformation
        $SourceDelta = @($FilesDiff | Where {$_.SideIndicator -eq "<="}) 
        $SourceDeltaCount = $SourceDelta.Count
 
        #Check if Source Files are changed
        If($SourceDeltaCount -gt 0)
        {
            Write-host "Found $SourceDeltaCount new differences in the Source!"
            Add-content $Logfile -value "Found $SourceDeltaCount new differences in the Source!"  
     
            $SourceDelta | Sort-Object TargetItemURL | ForEach-Object {
                #Calculate Target Folder URL for the file
                $TargetFolderURL = (Split-Path $_.TargetItemURL -Parent).Replace("\","/")
                If($TargetFolderURL.StartsWith("/")) {$TargetFolderURL = $TargetFolderURL.Remove(0,1) }
                $ItemName = Split-Path $_.FullName -leaf
                #Replace Invalid Characters
                $ItemName = [RegEx]::Replace($ItemName, "[{0}]" -f ([RegEx]::Escape([String]'\*:<>?/\|')), '_')
 
                #Display Progress bar
                $Status  = "Importing $ItemName to $TargetFolderURL $($Counter) of $($SourceDeltaCount)"
                Write-Progress -Activity "Importing Files from the Source..." -Status $Status -PercentComplete (($Counter / $SourceDeltaCount) * 100)
 
                If($_.PSIsContainer)
                {
                    #Ensure Folder
                    $Folder  = Resolve-PnPFolder -SiteRelativePath ($TargetFolderURL+"/"+$ItemName) -Includes ListItemAllFields
                     
                    Set-PnPListItem -List $TargetLibraryName -Identity $Folder.ListItemAllFields.Id -Values @{"Modified"=  ([DateTime]$_.LastUpdated).ToLocalTime()} | Out-null
                    Write-host "Ensured Folder '$($ItemName)' to Folder $TargetFolderURL"
                    Add-content $Logfile -value "Ensured Folder '$($ItemName)' to Folder $TargetFolderURL"
                }
                Else
                {
                    #Upload File
                    $File  = Add-PnPFile -Path $_.FullName -Folder $TargetFolderURL -Values @{"Modified"=  ([DateTime]$_.LastUpdated).ToLocalTime()}
                    Write-host "Ensured File '$($_.FullName)' to Folder $TargetFolderURL"
                    Add-content $Logfile -value "Ensured File '$($_.FullName)' to Folder $TargetFolderURL"
                }
                $Counter++
            }
        }
        Else
        {
            Write-host "Found no new Items in the Source! Total Items in Source: $SourceItemsCount , Number Items in Target: $($Library.Itemcount)"
            Add-content $Logfile -value "Found no new Items in the Source! Items in Source: $SourceItemsCount ,  Number Items in Target: $($Library.Itemcount)"
        }      
    }
    Catch {
        Write-host -f Red "Error:" $_.Exception.Message 
        Add-content $Logfile -value "Error:$($_.Exception.Message)"
    }
    Finally {
       Add-content $Logfile -value "---------------------- Import File Share Script Completed: $(Get-date -format 'dd/MM/yyy hh:mm:ss tt')-----------------"
    }
}
 
#Function to Remove Files Delta in SharePoint Online (Files that are no longer exists in FileShare )
Function Remove-FileShareDeltaInSPO
{
 param
    (
        [Parameter(Mandatory=$true)] [string] $SiteURL,
        [Parameter(Mandatory=$true)] [string] $SourceFolderPath,
        [Parameter(Mandatory=$true)] [string] $TargetLibraryName,            
        [Parameter(Mandatory=$true)] [string] $LogFile
    )
 
    Try {
        Add-content $Logfile -value "`n---------------------- Remove FileShare Delta Script Started: $(Get-date -format 'dd/MM/yyy hh:mm:ss tt')-------------------"  
 
        #Get Number of Source Items from the Source Folder
        $SourceItemsCount =  (Get-ChildItem -Path $SourceFolderPath -Recurse).count
 
        #Get the Target Library
        $Web = Get-PnPWeb
        $Library = Get-PnPList $TargetLibraryName -Includes RootFolder
        $TargetFolder = $Library.RootFolder
 
        #Get the site relative path of the target folder
        If($web.ServerRelativeURL -eq "/")
        {
            $TargetFolderSiteRelativeURL = $TargetFolder.ServerRelativeUrl
        }
        Else
        {        
            $TargetFolderSiteRelativeURL = $TargetFolder.ServerRelativeURL.Replace($Web.ServerRelativeUrl,[string]::Empty) 
        }        
  
        #Get All Items from the Source
        $SourceItems = Get-ChildItem -Path $SourceFolderPath -Recurse
        $Source = @($SourceItems | Select FullName,  PSIsContainer,
                                     @{Label='TargetItemURL';Expression={$_.FullName.Replace($SourceFolderPath,$TargetFolderSiteRelativeURL).Replace("\","/")}}, 
                                            @{Label='LastUpdated';Expression={$_.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ss')}})
 
        #Get All Files from the target document library - In batches of 2000
        $TargetFiles = Get-PnPListItem -List $TargetLibraryName -PageSize 2000
        $Target = @($TargetFiles | Select @{Label='FullName';Expression={$_.FieldValues.FileRef.Replace($TargetFolder.ServerRelativeURL,$SourceFolderPath).Replace("/","\")}},
                                                @{Label='PSIsContainer';Expression={$_.FileSystemObjectType -eq "Folder"}},
                                                    @{Label='TargetItemURL';Expression={$_.FieldValues.FileRef.Replace($Web.ServerRelativeUrl,[string]::Empty)}},
                                                        @{Label='LastUpdated';Expression={$_.FieldValues.Modified.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')}})
 
        #Compare Source and Target and remove files that are not in the Source
        $Counter = 1
        $FilesDiff = Compare-Object -ReferenceObject $Source -DifferenceObject $Target -Property FullName, PSIsContainer, TargetItemURL, LastUpdated     
        $TargetDelta = @($FilesDiff | Where {$_.SideIndicator -eq "=>"})
        $TargetDeltaCount = $TargetDelta.Count
 
        #Check if Target Files Needs to be deleted
        If($TargetDeltaCount -gt 0)
        {
            Write-host "Found $TargetDeltaCount differences in the Target!"
            Add-content $Logfile -value "Found $TargetDeltaCount differences in the Target!"  
     
            $TargetDelta | Sort-Object TargetItemURL -Descending | ForEach-Object {
                #Display Progress bar
                $Status  = "Removing Item " + $_.TargetItemURL +" ($($Counter) of $($TargetDeltaCount))"
                Write-Progress -Activity "Removing Items in the Target..." -Status $Status -PercentComplete (($Counter / $TargetDeltaCount) * 100)
 
                If($_.PSIsContainer)
                {
                    #Empty and Remove the Folder
                    $Folder  = Get-PnPFolder -Url $_.TargetItemURL -ErrorAction SilentlyContinue
                    If($Folder -ne $Null)
                    {
                        $Folder.Recycle() | Out-Null
                        Invoke-PnPQuery
 
                        Write-host "Removed Folder '$($_.TargetItemURL)'"
                        Add-content $Logfile -value "Removed Folder '$($_.TargetItemURL)'"
                    }
                }
                Else
                {
                    $File = Get-PnPFile -Url $_.TargetItemURL -ErrorAction SilentlyContinue
                    If($File -ne $Null)
                    {
                        #Remove the File
                        Remove-PnPFile -SiteRelativeUrl $_.TargetItemURL -Force
                        Write-host "Removed File '$($_.TargetItemURL)'"
                        Add-content $Logfile -value "Removed File '$($_.TargetItemURL)'"
                    }
                }
                $Counter++
            }
        }
        Else
        {
            Write-host "Found no differences in the Target! Total Items in Source: $SourceItemsCount , Number Items in Target: $($Library.Itemcount)"
            Add-content $Logfile -value "Found no differences in the Target! Items in Source: $SourceItemsCount ,  Number Items in Target: $($Library.Itemcount)"
        }
    }
    Catch {
        Write-host -f Red "Error:" $_.Exception.Message 
        Add-content $Logfile -value "Error:$($_.Exception.Message)"
    }
    Finally {
       Add-content $Logfile -value "---------------------- Remove FileShare Delta Script Completed: $(Get-date -format 'dd/MM/yyy hh:mm:ss tt')-----------------"
    }
}
 
Function Sync-FileShareToSPO()
{
 param
    (
        [Parameter(Mandatory=$true)] [string] $SiteURL,
        [Parameter(Mandatory=$true)] [string] $SourceFolderPath,
        [Parameter(Mandatory=$true)] [string] $TargetLibraryName,            
        [Parameter(Mandatory=$true)] [string] $LogFile
    )
 
    Try {
        #Connect to PnP Online
        Connect-PnPOnline -Url $SiteURL -Interactive
 
        #Call the function to Import New Files from Fileshare to SPO
        Import-FileShareToSPO -SiteURL $SiteURL -SourceFolderPath $SourceFolderPath -TargetLibraryName $TargetLibraryName -LogFile $LogFile
 
        #Call the function to Remove Files in SPO that are moved/deleted in Fileshare
        Remove-FileShareDeltaInSPO -SiteURL $SiteURL -SourceFolderPath $SourceFolderPath -TargetLibraryName $TargetLibraryName -LogFile $LogFile
    }
    Catch {
        Write-host -f Red "Error:" $_.Exception.Message
    }
}
 
#Call the Function to Sync Files from Fileshare to SharePoint Online
Sync-FileShareToSPO -SiteURL "https://yoursite.sharepoint.com/sites/libraryname" -SourceFolderPath "\\fileserver\share" -TargetLibraryName "Documents" -LogFile "C:\Temp\SyncFileShare-LOG.log"
