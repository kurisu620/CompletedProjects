#Removes any existing variables within the session to make sure that the session is opening fresh
Remove-Variable * -ErrorAction SilentlyContinue

#looks for the folders APICredentials folder and the TwitchDocs folder in your my documents, if these folders do not exist it creates them
Try{
    get-item "$env:USERPROFILE\Documents\APICredentials" -ErrorAction Stop
}catch{
    New-Item "$env:USERPROFILE\Documents" -Name "APICredentials" -ItemType "directory"
}
Try{
    Get-item "$env:USERPROFILE\Documents\TwitchDocs" -ErrorAction Stop
}catch{
    New-Item "$env:USERPROFILE\Documents" -Name "TwitchDocs" -ItemType "directory"
}

#Checks to see if you have credentials and will provide a popup window to enter your CID and SID if they do not currently exist. This does need to be run while the window is visible
try{
    $test=(New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList 'Fake', (Get-Content "$env:USERPROFILE\Documents\APICredentials\TwitchCID.txt" -ErrorAction Stop | ConvertTo-SecureString)).GetNetworkCredential().Password
    $test=(New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList 'Fake', (Get-Content "$env:USERPROFILE\Documents\APICredentials\TwitchSID.txt" -ErrorAction Stop | ConvertTo-SecureString)).GetNetworkCredential().Password
    $test=@()
}Catch{
    Read-Host -Prompt "Please Enter your clientID for Twitch" -AsSecureString | ConvertFrom-SecureString | Out-File "$env:USERPROFILE\Documents\APICredentials\TwitchCID.txt"
    Read-Host -Prompt "Please Enter your secretID for Twitch" -AsSecureString | ConvertFrom-SecureString | Out-File "$env:USERPROFILE\Documents\APICredentials\TwitchSID.txt"
}


#This creates a function to send a windows toast notification
Function Windows-ToastPopup {
    Param(
        $PopupTitle,
        $PopupContent,
        $Url
    )

    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
    $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
    $toastXml = [xml] $template.GetXml()
    
    #$PopupContent will be the content that is sent in the main body of the notification
    $toastXml.GetElementsByTagName("text")[1].AppendChild($toastXml.CreateTextNode($PopupContent)) > $null

    $actionsElement = $toastXml.CreateElement("actions")
    $actionElement = $toastXml.CreateElement("action")
    $actionElement.SetAttribute("content", "Open")

    #This is the URL that will be sent to the notification
    $actionElement.SetAttribute("arguments", $Url)
    
    $actionElement.SetAttribute("activationType", "protocol")
    $actionsElement.AppendChild($actionElement) > $null
    $toastXml.DocumentElement.AppendChild($actionsElement) > $null

    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml($toastXml.OuterXml)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
    $toast.Tag = "Twitch"
    $toast.Group = "Games"
    $toast.ExpirationTime = [DateTimeOffset]::Now.AddSeconds(5)
    
    #This is the primary title for the notification
    $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("$PopupTitle Twitch")
    $notifier.Show($toast)
    sleep 7
}



#Creates a function to grab an access token, default lifespan for token is 2 months
Function Get-TwitchHeaders{

    #this pulls your CID and SID located in your \Documents\APICredentials\ direcory, and decrypts them
    $CID = (New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList 'Fake', (Get-Content "$env:USERPROFILE\Documents\APICredentials\TwitchCID.txt" -ErrorAction Stop | ConvertTo-SecureString)).GetNetworkCredential().Password
    $SID = (New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList 'Fake', (Get-Content "$env:USERPROFILE\Documents\APICredentials\TwitchSID.txt" -ErrorAction Stop | ConvertTo-SecureString)).GetNetworkCredential().Password

    $headersAuthtoken = @{
        'Content-Type' = 'application/x-www-form-urlencoded'
    }
    $Body = "client_id=$CID&client_secret=$SID&grant_type=client_credentials"
    
    try{
        #This pulls the the Access token based on the the CID and SID
        $Global:accessToken=(Invoke-RestMethod -Body $Body -Uri "https://id.twitch.tv/oauth2/token" -Method Post -ErrorAction Stop -Headers $headersAuthtoken).access_token
    }catch{

        #Thiss will work with some error correction, if error 400 this would be an authentication issue and will prompt you to re-add your CID and SID. If the error is 429 this indicates that you have reached your limit for the app and waits 30 seconds before trying to pull the authtoken again
        if($_.Exception -imatch "400"){
            Windows-ToastPopup -PopupTitle "SecretID or ClientID issue" -PopupContent "There was an issue with your SecretID or your clientID supplied please re-add these"
            Read-Host -Prompt "Please Enter your clientID for Twitch" -AsSecureString | ConvertFrom-SecureString | Out-File "$env:USERPROFILE\Documents\APICredentials\TwitchCID.txt"
            Read-Host -Prompt "Please Enter your secretID for Twitch" -AsSecureString | ConvertFrom-SecureString | Out-File "$env:USERPROFILE\Documents\APICredentials\TwitchSID.txt"
            $Global:accessToken=(Invoke-RestMethod -Body $Body -Uri "https://id.twitch.tv/oauth2/token" -Method Post -ErrorAction Stop -Headers $headersAuthtoken).access_token
        }elseif($_.exception -imatch "429"){
            sleep 30
            $Global:accessToken=(Invoke-RestMethod -Body $Body -Uri "https://id.twitch.tv/oauth2/token" -Method Post -ErrorAction Stop -Headers $headersAuthtoken).access_token
        }elseif($_.eception -imatch "401"){
            $Global:accessToken=(Invoke-RestMethod -Body $Body -Uri "https://id.twitch.tv/oauth2/token" -Method Post -ErrorAction Stop -Headers $headersAuthtoken).access_token
        }else{
            Windows-ToastPopup -PopupTitle "Uncaught error" -PopupContent $_.Exception
        }
    }
    $Global:headers=@{
            'Authorization' = 'Bearer ' + $Global:AccessToken
            'Client-Id' = $CID
            'Content-Type' = 'application/json'
        }
}

#Gets Access Token for the Twitch API
Get-TwitchHeaders
$StreamingGames=@()

$infiniteLoop="True"
while($infiniteLoop){
    $TestVariableExists=@()

    #Pulls a list of Game names from a file located in the user's Documents called GameList
    try{
        $GameList=Get-Content $env:USERPROFILE\Documents\TwitchDocs\GameList.txt -ErrorAction Stop
    }Catch{
        New-Item $env:USERPROFILE\Documents\TwitchDocs -Name GameList.txt -ItemType "file"
        $GameList=Get-Content $env:USERPROFILE\Documents\TwitchDocs\GameList.txt
    }


    if(!$GameList -and ($num1 -ne 1)){
        Windows-ToastPopup -PopupTitle "GameList.txt" -PopupContent "Please make sure there is content in $env:USERPROFILE\Documents\TwitchDocs\GameList.txt"
    }
    $num1=1
    $page1=1
    #This is where the magic happens where is starts going through each game to pull the streams
    foreach($Game in $GameList){
    Write-Progress -Activity "Currently working on getting data for $Game" -Status "Working on $num1 of $($GameList.count)" -Id 1 -PercentComplete ($num1/$gamelist.count * 100)
        $newstreams=@()
        $URLtoCategory=$("https://www.twitch.tv/directory/category/" + $Game.replace("'","").replace(" ","-")).ToLower() + "?sort=RECENT"
        #Finds the GameID based on the name of the games in your list
        try{
            $gameID=(Invoke-RestMethod -Uri "https://api.twitch.tv/helix/games?name=$Game" -Method Get -ErrorAction Stop -Headers $headers).data.id
        }Catch{
            #Error correction in case you have hit your API limits or if you need to reauthenticate
            if($_.Exception -imatch "429"){
                sleep 30
                $gameID=(Invoke-RestMethod -Uri "https://api.twitch.tv/helix/games?name=$Game" -Method Get -ErrorAction Stop -Headers $headers).data.id
            }
            if($_.Exception -imatch "401"){
                Get-TwitchHeaders -CID $clientID -SID $SecretID
                $gameID=(Invoke-RestMethod -Uri "https://api.twitch.tv/helix/games?name=$Game" -Method Get -ErrorAction Stop -Headers $headers).data.id
            }
        }
        
        #Uses the gameID to get streams for that game
        try{
            $streams=Invoke-RestMethod -Uri "https://api.twitch.tv/helix/streams?game_id=$gameID&first=100&language=en" -Method Get -ErrorAction Stop -Headers $headers
        }catch{
            #Error correction in case you have hit your API limits or if you need to reauthenticate
            if($_.Exception -imatch "429"){
                sleep 30
                $streams=Invoke-RestMethod -Uri "https://api.twitch.tv/helix/streams?game_id=$gameID&first=100&language=en" -Method Get -ErrorAction Stop -Headers $headers
            }elseif($_.Exception -imatch "401"){
                Get-TwitchHeaders -CID $clientID -SID $SecretID
                $streams=Invoke-RestMethod -Uri "https://api.twitch.tv/helix/streams?game_id=$gameID&first=100&language=en" -Method Get -ErrorAction Stop -Headers $headers
            }Else{
                Windows-ToastPopup -PopupTitle "Uncaught error" -PopupContent $_.Exception
            }

        }

        #Writes the streams to a variable for use later
        $data=$streams.data

        #Paginates the data
        while ($streams.pagination.cursor){
            Write-Progress "Currently looping through the pages of streams for $game" -Status "Currently working on Page $page1" -Id 2 -ParentId 1
            try{
                $streams=Invoke-RestMethod -Uri "https://api.twitch.tv/helix/streams?game_id=$gameID&first=100&after=$($streams.pagination.cursor)&language=en" -Method Get -ErrorAction Stop -Headers $headers
            }Catch{
                if($_.Exception -imatch "429"){
                    sleep 30
                    $streams=Invoke-RestMethod -Uri "https://api.twitch.tv/helix/streams?game_id=$gameID&first=100&after=$($streams.pagination.cursor)&language=en" -Method Get -ErrorAction Stop -Headers $headers
                }elseif($_.Exception -imatch "401"){
                    Get-TwitchHeaders -CID $clientID -SID $SecretID
                    $streams=Invoke-RestMethod -Uri "https://api.twitch.tv/helix/streams?game_id=$gameID&first=100&after=$($streams.pagination.cursor)&language=en" -Method Get -ErrorAction Stop -Headers $headers
                }else{
                    Windows-ToastPopup -PopupTitle "Uncaught error" -PopupContent $_.Exception
                }
            }
            $data+=$streams.data
            $page1++
        }

        #Filters the streams down to all streams within the last 10 minutes
        $streamsInTheLast10minutes=$data | where {(get-date $_.started_at) -gt $((Get-Date).AddMinutes(-10))}
        $hashtableofStreams=@{}
        try{
            #Creates a hashtable from the previous data if the loop has already run once skips if there is no previous data to work with
            $TestifGameExists=$StreamingGames | where {$_.game_name -imatch $game}
            foreach($Streaming in $StreamingGames.id){
                if($Streaming){
                    $hashtableofStreams+=@{
                        $Streaming="True"
                    }
                }
            }
            
            #Creates a list of only new streams that started in the last 10 minutes
            foreach($streamID in $streamsInTheLast10minutes){
                if($hashtableofStreams.$($streamID.id) -ne "True"){
                    $newstreams+=$streamID
                }
            }

            #Sends a Windows toast popup on your primary display
            if($($newstreams.count) -eq 1){
                Windows-ToastPopup -PopupTitle $($streamsInTheLast10minutes[0].game_name) -PopupContent "There is $($newstreams.count) new stream of $($streamsInTheLast10minutes[0].game_name)" -Url $("https://www.twitch.tv/" + $newstreams[0].user_login)
            }elseif($($newstreams.count) -gt 1){
                Windows-ToastPopup -PopupTitle $($streamsInTheLast10minutes[0].game_name) -PopupContent "There are $($newstreams.count) new streams of $($streamsInTheLast10minutes[0].game_name)" -Url $URLtoCategory
            }else{
                #Windows-ToastPopup -PopupTitle $game -PopupContent "There are no recent streams for $game"
            }
        }Catch{

            #If the script has not cycled yet it will send information about all streams that started within the last 10 minutes
            try{
                if($($streamsInTheLast10minutes.count) -eq 1){
                    Windows-ToastPopup -PopupTitle $($streamsInTheLast10minutes[0].game_name) -PopupContent "There is $($streamsInTheLast10minutes.count) new stream of $($streamsInTheLast10minutes[0].game_name)" -Url $("https://www.twitch.tv/" + $newstreams[0].user_login)
                }elseif($streamsInTheLast10minutes.count){
                    Windows-ToastPopup -PopupTitle $($streamsInTheLast10minutes[0].game_name) -PopupContent "There are $($streamsInTheLast10minutes.count) new streams of $($streamsInTheLast10minutes[0].game_name)" -Url $URLtoCategory
                }
            }Catch{
                #Windows-ToastPopup -PopupTitle $game -PopupContent "There are no recent streams for $game"
            }
        }
        if($newstreams){
            foreach($newstream in $newstreams){
                $StreamingGames=$StreamingGames,$newstream
                    #id=$newstreams.id
                    #user_login=$newstream.user_login
                    #user_name=$newstream.user_name
                    #game_name=$newstream.game_name
                    #started_at=$newstream.started_at
                #}
            }
        }
        $StreamingGames=$StreamingGames | sort -Unique id
        
    $num1++
    }
    #Delays 60 seconds between loops
    sleep 30
}