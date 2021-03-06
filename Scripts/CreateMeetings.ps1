<#
DISCLAIMER: 
----------------------------------------------------------------
This sample is provided as is and is not meant for use on a production environment.
It is provided only for illustrative purposes. The end user must test and modify the
sample to suit their target environment. 
Microsoft can make no representation concerning the content of this sample. Microsoft
is providing this information only as a convenience to you. This is to inform you that
Microsoft has not tested the sample and therefore cannot make any representations 
regarding the quality, safety, or suitability of any code or information found here.    
#>

<#
INSTRUCTIONS:
Please see https://github.com/SmartterHealth/Virtual-Rounding/
#>


Import-Module AzureAD
Import-Module SharePointPnPPowerShellOnline
#--------------------------Variables---------------------------#

$configFilePath = ".\Scripts\RunningConfig.json"

$configFile = Get-Content -Path $configFilePath | ConvertFrom-Json

#sharePoint site your team has been provisioned for you. 
$sharepointSiteUrl = $configFile.TenantInfo.SPOUrl
$tenantName = $configFile.TenantInfo.TenantName

#azure App ID client ids and secrets
$clientID = $configFile.ClientCredential.Id
$clientSecret = $configFile.ClientCredential.Secret

$meetingSchedulerUserName = $configFIle.TenantInfo.MeetingSchedulingUser

#date/time values below
$utcOffset = $configFile.TimeZoneInfo.UTCOffset
$timezoneName = $configFile.TimeZoneInfo.TimeZoneName
$daysOutForMeetings = $configFile.MeetingInfo.DaysOutToSchedule

#links to the json templates
$teamsMeetingRequestBodyFile = "Scripts\NewMeetingRequest.json"
$eventRequestBodyFile = "Scripts\NewCalendarEventRequest.json"
#-------------------------Script Setup-------------------------#


$today = Get-Date -Format o
$meetingExpirationDate = (Get-Date).AddDays($daysOutForMeetings)
$meetingExpirationDate = Get-Date $meetingExpirationDate -Format o


if($null -eq $credentials)
{
    $Credentials = Get-Credential
}

Connect-AzureAD -Credential $Credentials

$scriptUser = Get-AzureAdUser -ObjectId $meetingSchedulerUserName

$scriptUserId =  $scriptUser.ObjectId


$ReqTokenBody = @{
    Grant_Type    = "client_credentials"
    Scope         = "https://graph.microsoft.com/.default"
    client_Id     = $clientID
    Client_Secret = $clientSecret
} 
$TokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$TenantName/oauth2/v2.0/token" -Method POST -Body $ReqTokenBody

function New-TeamsMeeting($SchedulingAccountId, $MeetingTitle)
{
    $teamsRequestBody = Get-Content -Path $teamsMeetingRequestBodyFile
    $teamsRequestBody = $teamsRequestBody.Replace("{0}", $today)
    $teamsRequestBody = $teamsRequestBody.Replace("{1}", $meetingExpirationDate)
    $teamsRequestBody = $teamsRequestBody.Replace("{2}", $MeetingTitle)
    $teamsRequestBody = $teamsRequestBody.Replace("{3}", $scriptUser.ObjectId)

    $teamsRequestBody | ConvertFrom-Json | Out-Null

    $newMeeting = Invoke-RestMethod -Method POST -Uri "https://graph.microsoft.com/beta/communications/onlineMeetings" -Body $teamsRequestBody -Headers @{Authorization = "Bearer $($Tokenresponse.access_token)" } -ContentType "application/json"
    
    return $newMeeting
}

function New-CalendarEvent($RoomAccountId, $EventTitle, $meetingUrl)
{
    $eventRequestBody = Get-Content -Path $eventRequestBodyFile
    $eventRequestBody = $eventRequestBody.Replace("{0}", $EventTitle)
    $eventRequestBody = $eventRequestBody.Replace("{1}", $meetingUrl)
    $eventRequestBody = $eventRequestBody.Replace("{2}", $today)
    $eventRequestBody = $eventRequestBody.Replace("{3}", $timezoneName)
    $eventRequestBody = $eventRequestBody.Replace("{4}", $meetingExpirationDate)
    
    $eventRequestBody | ConvertFrom-Json | Out-Null
    
    $newEvent = Invoke-RestMethod -Method POST "https://graph.microsoft.com/beta/users/$RoomAccountId/calendar/events" -Body $eventRequestBody -Headers @{Authorization = "Bearer $($Tokenresponse.access_token)" } -ContentType "application/json"

    return $newEvent
}

#-------Connect to SharePoint and get all of our location lists--------------------#

Connect-PnPOnline -Url $sharepointSiteUrl -Credentials $Credentials

Get-PnpList -Includes ContentTypes,ItemCount | foreach-object {
    $list = $_
    $roomsToUpdate = @()

    if($list.ContentTypes | Where-Object Name -eq "VirtualRoundingRoom")
    {
        Write-Host "Preparing to schedule events for " $list.Title
        $listItems = Get-PnPListItem -List $list
        $listItems | ForEach-Object  {
            $roundingListItem = $_
            #get the room account associated with the room list item. 
            $roundingRoomAccount = $roundingLIstItem["RoomAccount"].Email
            $roundingRoomAccountAADUser = Get-AzureAdUser -ObjectId $roundingRoomAccount
            
            Write-Host "Preparing to deploy meetings for Room " $roundingListItem["Title"]

            #create the teams meeting
            $meeting = New-TeamsMeeting -SchedulingAccountId $scriptUserId -MeetingTitle $roundingListItem["Title"]
            $joinUrl = $meeting.joinUrl

            #create the calendar event, sending it to the room account
            $calendarEvent = New-CalendarEvent -RoomAccountId $roundingRoomAccountAADUser.ObjectId -EventTitle $roundingLIstItem["Title"] -meetingUrl $joinUrl
            
            #build out our info we will use to update the SharePoint list
            $roomObject = New-Object psobject -Property @{
                ListItemId = $RoundingListItem.Id
                JoinUrl =  "$joinUrl, Join Room"
                EventId = $calendarEvent.EventId
            }
            
            $roomsToUpdate += $roomObject

            Write-Host "Deployed Meetings for Room " $roundingListItem["Title"]
        }
        
        #update the SharePoint list with the rooms. Note we have to do this in a separate loop to avoid breaking the PnP update process while looping the parent list objects
        if($roomsToUpdate.Count -ge 1)
            {
            $roomsToUpdate | ForEach-Object {
                Set-PnpListItem -List $list.Title -Identity $_.ListItemId -Values @{"MeetingLink" = $_.JoinUrl; "EventID"=$_.EventId}
                Write-Host "List Update for Meetings for Room " $roundingListItem["Title"]
            }
        }
    }
}