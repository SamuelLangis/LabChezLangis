# Script pour convertir un groupe de device en "Shared Mode"
# Samuel Langis - 26 avril 2026

[CmdletBinding()]
param(
    [switch]$PreviewOnly
)

$ErrorActionPreference = 'Stop'

function Get-MissingScopes {
    param(
        [string[]]$Required,
        [string[]]$Granted
    )
    $Required | Where-Object { $_ -notin $Granted }
}

function Connect-OrSwitchTenant {
    param(
        [Parameter(Mandatory)]
        [string[]]$RequiredScopes,

        [string]$TenantId,

        [int]$MaxAttempts = 3
    )

    $connectParams = @{
        Scopes       = $RequiredScopes
        ContextScope = 'CurrentUser'
        NoWelcome    = $true
    }

    if ($TenantId) {
        $connectParams['TenantId'] = $TenantId
    }

    try { $ctx = Get-MgContext } catch { $ctx = $null }

    if (-not $ctx -or -not $ctx.Account) {
        Write-Host "`n🔐 Aucune session Microsoft Graph active." -ForegroundColor Yellow
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Write-Host "🔄 Connexion Microsoft Graph..." -ForegroundColor Yellow
        Connect-MgGraph @connectParams
    }

    $attempt = 0

    do {
        if ($attempt -ge $MaxAttempts) {
            throw "❌ Nombre maximum de tentatives atteint ($MaxAttempts). Arrêt du script."
        }

        $ctx = Get-MgContext

        $missingScopes = Get-MissingScopes -Required $RequiredScopes -Granted $ctx.Scopes
        if ($missingScopes) {
            Write-Host "`n⚠️  Scopes requis manquants :" -ForegroundColor Yellow
            $missingScopes | ForEach-Object { Write-Host "   ❌ $_" -ForegroundColor Red }

            Write-Host "`n🔄 Reconnexion avec les scopes manquants..." -ForegroundColor Yellow
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            Connect-MgGraph @connectParams
            $attempt++
            continue
        }

        try {
            $org = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/organization" -ErrorAction Stop
            $tenantName = $org.value[0].displayName
        }
        catch {
            $tenantName = "(nom du tenant indisponible)"
            Write-Host "`n⚠️  Impossible de récupérer le nom du tenant : $_" -ForegroundColor DarkYellow
        }

        Write-Host "`n✅ Connecté en tant que :" -ForegroundColor Green
        Write-Host "`t$($ctx.Account)" -ForegroundColor Yellow
        Write-Host "✅ Tenant :" -ForegroundColor Green
        Write-Host "`t'$tenantName' ($($ctx.TenantId))" -ForegroundColor Yellow

        $keep = Read-Host "`nVoulez-vous conserver cette connexion ? (O/N)"

        if ($keep -match '^(o|oui|y|yes)$') {
            Write-Host "`n🔒 Connexion conservée." -ForegroundColor Green
            break
        }

        Write-Host "`n🔄 Changement de tenant..." -ForegroundColor Yellow
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Connect-MgGraph @connectParams
        $attempt++

    } while ($true)

    $ctx = Get-MgContext
    $activeScopes = $RequiredScopes | Where-Object { $_ -in $ctx.Scopes }

    Write-Host "`n🔑 Scopes requis actifs :" -ForegroundColor Green
    $activeScopes | Sort-Object | ForEach-Object {
        Write-Host "   ✔ $_" -ForegroundColor DarkGreen
    }
    Write-Host "`n"

    if ($activeScopes.Count -ne $RequiredScopes.Count) {
        throw "❌ Tous les scopes requis ne sont pas actifs. Arrêt du script."
    }
}

function Get-GraphErrorMessage {
    param(
        [Parameter(Mandatory)]
        $ErrorRecord
    )

    $messages = @()

    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $messages += $ErrorRecord.ErrorDetails.Message
    }

    if ($ErrorRecord.Exception -and $ErrorRecord.Exception.Message) {
        $messages += $ErrorRecord.Exception.Message
    }

    if (-not $messages) {
        $messages += ($ErrorRecord | Out-String).Trim()
    }

    return ($messages | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) -join ' | '
}

function Convert-GraphResponseObject {
    param(
        [Parameter(Mandatory)]
        $Response
    )

    if ($Response -is [string]) {
        try {
            return ($Response | ConvertFrom-Json -Depth 20)
        }
        catch {
            return $Response
        }
    }

    return $Response
}

function Get-GraphPropertyValue {
    param(
        [Parameter(Mandatory)]
        $Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        return $null
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) {
        return $prop.Value
    }

    return $null
}

function Invoke-GraphGetAllPages {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [hashtable]$Headers
    )

    $allItems = @()
    $nextLink = $Uri

    while ($nextLink) {
        $params = @{
            Method      = 'GET'
            Uri         = $nextLink
            ErrorAction = 'Stop'
        }

        if ($Headers) {
            $params.Headers = $Headers
        }

        $rawResponse = Invoke-MgGraphRequest @params
        $response = Convert-GraphResponseObject -Response $rawResponse

        $value = Get-GraphPropertyValue -Object $response -Name 'value'
        if ($null -ne $value) {
            $allItems += @($value)
        }
        else {
            $allItems += ,$response
        }

        $odataNextLink = Get-GraphPropertyValue -Object $response -Name '@odata.nextLink'
        if (-not [string]::IsNullOrWhiteSpace([string]$odataNextLink)) {
            $nextLink = [string]$odataNextLink
        }
        else {
            $nextLink = $null
        }
    }

    return @($allItems)
}

function Select-EntraGroup {
    while ($true) {
        Write-Host ""
        $groupName = (Read-Host "Entrez le nom exact du groupe Entra ID à traiter").Trim()

        if ([string]::IsNullOrWhiteSpace($groupName)) {
            Write-Warning "Le nom du groupe ne peut pas être vide."
            continue
        }

        try {
            $escapedGroupName = $groupName.Replace("'", "''")
            $filter = [System.Uri]::EscapeDataString("displayName eq '$escapedGroupName'")
            $uri = "https://graph.microsoft.com/v1.0/groups?`$filter=$filter&`$select=id,displayName,description,mailEnabled,securityEnabled,groupTypes"

            $rawResponse = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
            $response = Convert-GraphResponseObject -Response $rawResponse

            $value = Get-GraphPropertyValue -Object $response -Name 'value'
            $groups = @()

            foreach ($item in @($value)) {
                $id = Get-GraphPropertyValue -Object $item -Name 'id'
                if ([string]::IsNullOrWhiteSpace([string]$id)) {
                    continue
                }

                $groups += [pscustomobject]@{
                    id              = [string]$id
                    displayName     = [string](Get-GraphPropertyValue -Object $item -Name 'displayName')
                    description     = Get-GraphPropertyValue -Object $item -Name 'description'
                    mailEnabled     = [bool](Get-GraphPropertyValue -Object $item -Name 'mailEnabled')
                    securityEnabled = [bool](Get-GraphPropertyValue -Object $item -Name 'securityEnabled')
                    groupTypes      = @((Get-GraphPropertyValue -Object $item -Name 'groupTypes'))
                }
            }

            if ($groups.Count -eq 0) {
                Write-Host "❌ Aucun groupe trouvé avec le nom exact '$groupName'." -ForegroundColor Yellow
                continue
            }

            if ($groups.Count -eq 1) {
                Write-Host "✅ Groupe validé : $($groups[0].displayName)" -ForegroundColor Green
                return $groups[0]
            }

            Write-Warning "Plusieurs groupes portent exactement ce nom. Sélectionne celui à utiliser :"

            for ($i = 0; $i -lt $groups.Count; $i++) {
                $g = $groups[$i]

                $groupType = 'Autre'
                if ($g.groupTypes -and ($g.groupTypes -contains 'Unified')) {
                    $groupType = 'Microsoft 365'
                }
                elseif ($g.securityEnabled) {
                    $groupType = 'Sécurité'
                }

                Write-Host ("[{0}] {1} | Type: {2} | Id: {3}" -f ($i + 1), $g.displayName, $groupType, $g.id)
            }

            while ($true) {
                [int]$choice = 0
                $answer = Read-Host "Entre le numéro du groupe à traiter"

                if ([int]::TryParse($answer, [ref]$choice) -and $choice -ge 1 -and $choice -le $groups.Count) {
                    return $groups[$choice - 1]
                }

                Write-Warning "Choix invalide."
            }
        }
        catch {
            Write-Warning ("Erreur lors de la validation du groupe : {0}" -f (Get-GraphErrorMessage -ErrorRecord $_))
        }
    }
}

function Get-EntraDevicesFromGroup {
    param(
        [Parameter(Mandatory)]
        [string]$GroupId
    )

    $uri = "https://graph.microsoft.com/v1.0/groups/$GroupId/transitiveMembers/microsoft.graph.device?`$select=id,deviceId,displayName,trustType&`$top=999"
    $devices = @(Invoke-GraphGetAllPages -Uri $uri)

    $uniqueDevices = @{}

    foreach ($device in $devices) {
        if (-not $device) { continue }
        if ([string]::IsNullOrWhiteSpace($device.deviceId)) { continue }

        if (-not $uniqueDevices.ContainsKey($device.deviceId)) {
            $uniqueDevices[$device.deviceId] = [pscustomobject]@{
                id          = $device.id
                deviceId    = $device.deviceId
                displayName = $device.displayName
                TrustType   = $device.trustType
            }
        }
    }

    return @($uniqueDevices.Values | Sort-Object displayName, deviceId)
}

function Get-AllIntuneManagedDevices {
    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$select=id,deviceName,azureADDeviceId,userPrincipalName,userDisplayName,managedDeviceOwnerType,operatingSystem,serialNumber,lastSyncDateTime"
    $devices = @(Invoke-GraphGetAllPages -Uri $uri)
    return @($devices | Where-Object { $_ -and $_.id -and $_.azureADDeviceId })
}

function Get-ManagedDevicePrimaryUsers {
    param(
        [Parameter(Mandatory)]
        [string]$ManagedDeviceId
    )

    $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$ManagedDeviceId')/users?`$select=id,displayName,userPrincipalName"
    $users = @(Invoke-GraphGetAllPages -Uri $uri)

    return @($users | Where-Object { $_ -and $_.id })
}

function Remove-ManagedDevicePrimaryUsers {
    param(
        [Parameter(Mandatory)]
        [string]$ManagedDeviceId
    )

    $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$ManagedDeviceId')/users/`$ref"
    Invoke-MgGraphRequest -Method DELETE -Uri $uri -ErrorAction Stop | Out-Null
}

# Main

try {
    $requiredScopes = @(
        'Group.Read.All',
        'GroupMember.Read.All',
        'Device.Read.All',
        'DeviceManagementManagedDevices.Read.All',
        'DeviceManagementManagedDevices.ReadWrite.All'
    )

    Connect-OrSwitchTenant -RequiredScopes $requiredScopes

    $selectedGroup = Select-EntraGroup

    Write-Host ""
    Write-Host "Groupe sélectionné : $($selectedGroup.displayName)" -ForegroundColor Cyan
    Write-Host "Group ID          : $($selectedGroup.id)" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "Récupération des devices Entra ID (membres directs + groupes imbriqués)..." -ForegroundColor Yellow
    $entraDevices = @(Get-EntraDevicesFromGroup -GroupId $selectedGroup.id)

    if ($entraDevices.Count -eq 0) {
        Write-Warning "Aucun device Entra ID trouvé dans ce groupe, incluant les groupes imbriqués."
        return
    }

    Write-Host ("{0} device(s) Entra ID trouvé(s)." -f $entraDevices.Count) -ForegroundColor Green
    Write-Host ""

    Write-Host "Répartition par trustType :" -ForegroundColor Yellow
    $entraDevices |
        Group-Object TrustType |
        Sort-Object Name |
        Format-Table Count, Name -AutoSize

    Write-Host ""
    Write-Host "Récupération des managed devices Intune..." -ForegroundColor Yellow
    $allManagedDevices = @(Get-AllIntuneManagedDevices)

    $managedByAadId = @{}
    $duplicateAadIds = New-Object System.Collections.Generic.HashSet[string]

    foreach ($md in $allManagedDevices) {
        if ([string]::IsNullOrWhiteSpace($md.azureADDeviceId)) {
            continue
        }

        $key = $md.azureADDeviceId.ToLower()

        if ($managedByAadId.ContainsKey($key)) {
            [void]$duplicateAadIds.Add($key)
        }
        else {
            $managedByAadId[$key] = $md
        }
    }

    Write-Host ("{0} appareil(s) Intune total dans le tenant, utilisés pour comparer avec les {1} device(s) du groupe." -f $allManagedDevices.Count, $entraDevices.Count) -ForegroundColor Green
    if ($duplicateAadIds.Count -gt 0) {
        Write-Host ("⚠️  {0} azureADDeviceId en doublon détecté(s) dans Intune." -f $duplicateAadIds.Count) -ForegroundColor DarkYellow
    }
    Write-Host ""

    if ($PreviewOnly) {
        Write-Host "Mode prévisualisation actif : aucune modification ne sera faite." -ForegroundColor Magenta
        Write-Host ""
    }

    $confirmation = Read-Host "Voulez-vous poursuivre le traitement ? (O/N)"
    if ($confirmation -notmatch '^(o|oui|y|yes)$') {
        Write-Warning "Opération annulée par l'utilisateur."
        return
    }

    $results = New-Object System.Collections.Generic.List[object]
    $total = $entraDevices.Count
    $current = 0

    foreach ($entraDevice in $entraDevices) {
        $current++
        $percent = [math]::Round(($current / $total) * 100, 0)

        Write-Progress `
            -Activity "Conversion vers Shared Mode" `
            -Status ("Traitement {0}/{1} : {2}" -f $current, $total, $entraDevice.displayName) `
            -PercentComplete $percent

        $result = [ordered]@{
            GroupDisplayName    = $selectedGroup.displayName
            EntraDeviceName     = $entraDevice.displayName
            EntraObjectId       = $entraDevice.id
            EntraDeviceId       = $entraDevice.deviceId
            TrustType           = $entraDevice.TrustType
            IntuneDeviceName    = $null
            IntuneDeviceId      = $null
            IntunePrimaryUsers  = $null
            Status              = $null
            Details             = $null
        }

        try {
            if ([string]::IsNullOrWhiteSpace($entraDevice.deviceId)) {
                $result.Status  = 'Device Entra invalide'
                $result.Details = 'Le device Entra ne contient pas de deviceId.'
                [void]$results.Add([pscustomobject]$result)
                continue
            }

            if ($entraDevice.TrustType -notin @('AzureAd', 'ServerAd')) {
                $result.Status  = 'Ignoré (type non supporté)'
                $result.Details = "trustType = $($entraDevice.TrustType)"
                [void]$results.Add([pscustomobject]$result)
                continue
            }

            $lookupKey = $entraDevice.deviceId.ToLower()

            if ($duplicateAadIds.Contains($lookupKey)) {
                $duplicateDevices = @(
                    $allManagedDevices |
                    Where-Object {
                        $_.azureADDeviceId -and $_.azureADDeviceId.ToLower() -eq $lookupKey
                    }
                )

                $result.Status           = 'Correspondance Intune ambiguë'
                $result.Details          = "Plus d'un managedDevice trouvé pour azureADDeviceId = $($entraDevice.deviceId)."
                $result.IntuneDeviceName = ($duplicateDevices | ForEach-Object { $_.deviceName }) -join ' | '
                $result.IntuneDeviceId   = ($duplicateDevices | ForEach-Object { $_.id }) -join ' | '
                [void]$results.Add([pscustomobject]$result)
                continue
            }

            $managedDevice = $managedByAadId[$lookupKey]

            if (-not $managedDevice) {
                $result.Status  = 'Introuvable dans Intune'
                $result.Details = 'Aucun managedDevice correspondant à azureADDeviceId.'
                [void]$results.Add([pscustomobject]$result)
                continue
            }

            $result.IntuneDeviceName = $managedDevice.deviceName
            $result.IntuneDeviceId   = $managedDevice.id

            if ($managedDevice.managedDeviceOwnerType -eq 'shared') {
                $result.Status  = 'Déjà shared mode'
                $result.Details = 'Device déjà en mode partagé (managedDeviceOwnerType=shared).'
                [void]$results.Add([pscustomobject]$result)
                continue
            }

            $primaryUsers = @(Get-ManagedDevicePrimaryUsers -ManagedDeviceId $managedDevice.id)
            $result.IntunePrimaryUsers = ($primaryUsers | ForEach-Object {
                if ($_.userPrincipalName) { $_.userPrincipalName } else { $_.displayName }
            }) -join ' | '

            if ($primaryUsers.Count -eq 0) {
                $result.Status  = 'Déjà shared mode'
                $result.Details = 'Aucun primary user associé au device Intune.'
                [void]$results.Add([pscustomobject]$result)
                continue
            }

            if ($PreviewOnly) {
                $result.Status  = 'Prévisualisation seulement'
                $result.Details = 'Aucune suppression effectuée car -PreviewOnly a été utilisé.'
                [void]$results.Add([pscustomobject]$result)
                continue
            }

            Remove-ManagedDevicePrimaryUsers -ManagedDeviceId $managedDevice.id
            $result.Status  = 'Converti en shared mode'
            $result.Details = 'Association primary user supprimée via Microsoft Graph.'
        }
        catch {
            $errorMessage = Get-GraphErrorMessage -ErrorRecord $_

            if (
                $errorMessage -match 'Resource not found' -or
                $errorMessage -match 'No registered users' -or
                $errorMessage -match 'users/\$ref' -or
                $errorMessage -match 'does not exist' -or
                $errorMessage -match 'cannot be found'
            ) {
                $result.Status  = 'Déjà shared mode'
                $result.Details = "Aucun primary user exploitable pour ce device. Message Graph : $errorMessage"
            }
            else {
                $result.Status  = 'Erreur'
                $result.Details = $errorMessage
            }
        }

        [void]$results.Add([pscustomobject]$result)
    }

    Write-Progress -Activity "Conversion vers Shared Mode" -Completed

    Write-Host ""
    Write-Host "Résumé du traitement :" -ForegroundColor Cyan
    $results |
        Group-Object -Property Status |
        Sort-Object Name |
        Format-Table Count, Name -AutoSize

    Write-Host ""
    $results |
        Sort-Object Status, EntraDeviceName |
        Format-Table EntraDeviceName, TrustType, IntuneDeviceName, Status, IntunePrimaryUsers -AutoSize

    $csvPath = Join-Path -Path (Get-Location) -ChildPath ("Intune-SharedMode-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

    Write-Host ""
    Write-Host "Rapport exporté : $csvPath" -ForegroundColor Green
}
catch {
    Write-Error ("Erreur globale : {0}" -f (Get-GraphErrorMessage -ErrorRecord $_))
}