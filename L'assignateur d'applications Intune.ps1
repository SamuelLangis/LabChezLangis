<#
.SYNOPSIS
============== L'assignateur d'applications Intune ==============

1) Assigner une application aux groupes par défaut
2) Afficher les assignations d'une application
3) Supprimer toutes les assignations d'une application

4) Configurer le préfixe des groupes par défaut
5) Configurer l'option Packageur

6) Quitter
=================================================

Samuel Langis 1 septembre 2025

Notes:
- PS 5.1+ compatible
- Le préfixe est requis pour l’assignation et est stocké dans %APPDATA%\AssignateurIntune\config.json

Prérequis
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
Install-Module Microsoft.Graph.Groups -Scope CurrentUser
Install-Module Microsoft.Graph.DeviceManagement -Scope CurrentUser

#>

Clear-Host

# ================== CONFIG PERSISTANTE (profil utilisateur) ==================
$AppDataRoot = Join-Path $env:APPDATA 'AssignateurIntune'
$ConfigPath = Join-Path $AppDataRoot 'config.json'
if (-not (Test-Path $AppDataRoot)) { New-Item -Path $AppDataRoot -ItemType Directory -Force | Out-Null }

function Load-Config {
	if (Test-Path $ConfigPath) {
		try { return Get-Content $ConfigPath -Raw | ConvertFrom-Json -ErrorAction Stop } catch { return [pscustomobject]@{} }
	}
	return [pscustomobject]@{}
}
function Save-Config {
	param([Parameter(Mandatory)]$Config)
	($Config | ConvertTo-Json -Depth 10) | Set-Content -Path $ConfigPath -Encoding UTF8
}

# Charge config existante (peut être vide)
$Config = Load-Config
if (-not $Config.PSObject.Properties['UsePackagersGroup']) {
	$Config | Add-Member -NotePropertyName UsePackagersGroup -NotePropertyValue $false
}
if (-not $Config.PSObject.Properties['PackagersGroupName']) {
	$Config | Add-Member -NotePropertyName PackagersGroupName -NotePropertyValue 'GGRP-Intune-APPS-Packageurs'
}


# ================== Modules Microsoft Graph Vérification et Importation ==================
$ModulesNeeded = @(
  'Microsoft.Graph.Authentication',
  'Microsoft.Graph.Groups',
  'Microsoft.Graph.DeviceManagement'
)

foreach ($m in $ModulesNeeded) {
  if (-not (Get-Module -ListAvailable -Name $m)) {
    throw "Module requis manquant: $m. Installe-le avant d'exécuter le script."
  }
  Import-Module $m -ErrorAction Stop
}


function Connect-OrSwitchTenant {
    param(
        [Parameter(Mandatory)]
        [string[]]$RequiredScopes
    )

    # --- Fonction interne : scopes manquants ---
    function Get-MissingScopes {
        param(
            [string[]]$Required,
            [string[]]$Granted
        )
        $Required | Where-Object { $_ -notin $Granted }
    }

    # --- Connexion initiale si nécessaire ---
    try {
        $ctx = Get-MgContext
    } catch {
        $ctx = $null
    }

    if (-not $ctx -or -not $ctx.Account) {
        Write-Host "`n🔐 Aucune session Microsoft Graph active." -ForegroundColor Yellow
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null

        Write-Host "`n🔄 Connexion Microsoft Graph..." -ForegroundColor Yellow
        Connect-MgGraph `
            -Scopes $RequiredScopes `
            -ContextScope CurrentUser `
            -NoWelcome
    }

    # --- Boucle unique : tant que la connexion n’est pas conservée ---
    do {
        $ctx = Get-MgContext

        # Validation des scopes
        $missingScopes = Get-MissingScopes -Required $RequiredScopes -Granted $ctx.Scopes
        if ($missingScopes) {
            Write-Host "`n⚠️ Scopes requis manquants :" -ForegroundColor Yellow
            $missingScopes | ForEach-Object {
                Write-Host "   ❌ $_" -ForegroundColor Red
            }

            Write-Host "`n🔄 Reconnexion avec les bons scopes..." -ForegroundColor Yellow
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null

            Connect-MgGraph `
                -Scopes $RequiredScopes `
                -ContextScope CurrentUser `
                -NoWelcome

            continue
        }

        # Affichage du contexte
        $tenant = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/organization"

        Write-Host "`n✅ Connecté en tant que :" -ForegroundColor Green
        Write-Host "`t$($ctx.Account)" -ForegroundColor Yellow
        Write-Host "✅ Sur le tenant :" -ForegroundColor Green
        Write-Host "`t'$($tenant.value[0].displayName)' ($($ctx.TenantId))" -ForegroundColor Yellow

        # Question unique
        $keep = Read-Host "`nVoulez-vous conserver cette connexion ? (O/N)"

        if ($keep -match '^(o|oui|y|yes)$') {
            Write-Host "`n🔒 Connexion conservée." -ForegroundColor Green
            break
        }

        # Changement de tenant
        Write-Host "`n🔄 Changement de tenant..." -ForegroundColor Yellow
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null

        Connect-MgGraph `
            -Scopes $RequiredScopes `
            -ContextScope CurrentUser `
            -NoWelcome

    }
    while ($true)

    # --- Validation finale ---
    $ctx = Get-MgContext
    $activeRequiredScopes = $RequiredScopes | Where-Object { $_ -in $ctx.Scopes }

    Write-Host "`n🔑 Scopes requis actifs :" -ForegroundColor Green
    $activeRequiredScopes | Sort-Object | ForEach-Object {
        Write-Host "   ✔ $_" -ForegroundColor DarkGreen        
    }
    Write-Host "`n`n"

    if ($activeRequiredScopes.Count -ne $RequiredScopes.Count) {
        throw "❌ Tous les scopes requis ne sont pas actifs. Arrêt du script.`n"
    }
}


# Appel
Connect-OrSwitchTenant -RequiredScopes @(
	'DeviceManagementApps.ReadWrite.All',
	'Group.ReadWrite.All'
)


# ================== UTILITAIRES INTUNE ==================
try { Select-MgProfile -Name 'v1.0' } catch {}
if (-not (Get-Command Get-MgDeviceAppManagementMobileApp -ErrorAction SilentlyContinue)) {
	try { Import-Module Microsoft.Graph.DeviceManagement -Force -ErrorAction SilentlyContinue } catch {}
}

function Get-IntuneMobileAppById {
	param([Parameter(Mandatory)][string]$Id)

	# 1) Essai via cmdlet Graph
	if (Get-Command Get-MgDeviceAppManagementMobileApp -ErrorAction SilentlyContinue) {
		try {
			$obj = Get-MgDeviceAppManagementMobileApp -MobileAppId $Id -ErrorAction Stop
			if ($obj) {
				$odata = $null
				try {
					# Certains objets exposent directement @odata.type
					if ($obj.PSObject.Properties.Match('@odata.type')) {
						$odata = $obj.'@odata.type'
					}
				} catch {}
				if (-not $odata -and $obj.PSObject.Properties.Name -contains 'AdditionalProperties') {
					try { $odata = $obj.AdditionalProperties['@odata.type'] } catch {}
					if (-not $odata) { try { $odata = $obj.AdditionalProperties.'@odata.type' } catch {} }
				}

				return [pscustomobject]@{
					Id          = $obj.Id
					DisplayName = $obj.DisplayName
					ODataType   = $odata
				}
			}
		} catch {}
	}

	# 2) Fallback REST (léger)
	$uri = "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps/$Id"
	try {
		$resp = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
		if ($resp) {
			return [pscustomobject]@{
				Id          = $resp.id
				DisplayName = $resp.displayName
				ODataType   = $resp.'@odata.type'
			}
		}
	} catch {}

	return $null
}



function Get-AppAssignments {
	param([Parameter(Mandatory)][string]$AppId)
	$uri = "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps/$AppId/assignments"
	try { (Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop).value } catch { @() }
}

function Add-AppAssignment {
	param(
		[Parameter(Mandatory)][string]$AppId,
		[Parameter(Mandatory)][string]$GroupId,
		[Parameter(Mandatory)][string]$GroupName,
		[Parameter(Mandatory)][ValidateSet('required', 'available', 'uninstall')][string]$Intent,
		[Parameter(Mandatory)][ValidateSet('foreground', 'background')][string]$DOPriority,
		[string]$AppODataType = ''   # optionnel (peut être vide pour Store (new))
	)

	try { Select-MgProfile -Name 'v1.0' } catch {}

	$isWin32 = ($AppODataType -match 'win32LobApp')
	$uriBase = "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps/$AppId/assignments"

	# Notifications côté Win32 :
	# - available  -> showAll
	# - required/uninstall -> showReboot
	$notifToUse = if ($Intent -eq 'available') { 'showAll' } else { 'showReboot' }

	$body = @{
		'@odata.type' = '#microsoft.graph.mobileAppAssignment'
		intent        = $Intent
		target        = @{
			'@odata.type' = '#microsoft.graph.groupAssignmentTarget'
			groupId       = $GroupId
		}
	}

	if ($isWin32) {
		# Win32 : on remet les notifications + DO selon l’intent
		$settings = @{
			'@odata.type' = '#microsoft.graph.win32LobAppAssignmentSettings'
			notifications = $notifToUse
		}

		if ($Intent -in @('available', 'uninstall')) {
			# Foreground pour Available/Uninstall
			$settings.deliveryOptimizationPriority = 'foreground'
		}
		# Required : ne pas forcer DO => background par défaut (évite les 400)

		$body.settings = $settings
	}
	# Non-Win32 (Store/WinGet/etc.) : on n’envoie PAS de settings (évite les soucis de compatibilité)

	try {
		$json = $body | ConvertTo-Json -Depth 15
		$resp = Invoke-MgGraphRequest -Method POST -Uri $uriBase -Body $json -ContentType 'application/json' -OutputType HttpResponseMessage -ErrorAction Stop
		if ([int]$resp.StatusCode -ge 200 -and [int]$resp.StatusCode -lt 300) {
			Write-Host "✅ Assignation '$Intent' appliquée pour le groupe $GroupName" -ForegroundColor Green
		} else {
			$errText = $null; try { $errText = $resp.Content.ReadAsStringAsync().Result } catch {}
			Write-Host "❌ Échec assignation '$Intent' ($([int]$resp.StatusCode)) pour le groupe $GroupName" -ForegroundColor Red
			if ($errText) { Write-Host "   ↳ ERREUR GRAPH: $errText" -ForegroundColor DarkYellow }
		}
	} catch {
		$errText = $null
		try {
			$exResp = $_.Exception.Response
			if ($exResp) {
				$sr = New-Object System.IO.StreamReader($exResp.GetResponseStream())
				$errText = $sr.ReadToEnd()
			}
		} catch {}
		Write-Host "❌ Échec assignation '$Intent' pour le groupe $GroupName : $($_.Exception.Message)" -ForegroundColor Red
		if ($errText) { Write-Host "   ↳ ERREUR GRAPH: $errText" -ForegroundColor DarkYellow }
	}
}



function Action-RemoveAllAssignments {
	param([Parameter(Mandatory)][string]$AppId)

	# Afficher l'app ciblée
	$app = Get-IntuneMobileAppById -Id $AppId
	if ($app) {
		Write-Host ('Application ciblée : {0} (Id: {1})' -f $app.DisplayName, $app.Id) -ForegroundColor Cyan
	} else {
		Write-Host "Application ciblée : <inconnue> (Id: $AppId)" -ForegroundColor Cyan
	}

	# Récupérer les assignations
	Write-Host 'Recherche des assignations...' -ForegroundColor Cyan
	$assignments = Get-AppAssignments -AppId $AppId
	if (-not $assignments -or $assignments.Count -eq 0) {
		Write-Host "ℹ️  Aucune assignation trouvée pour l'application." -ForegroundColor Yellow
		return
	}

	# Résumé avant confirmation
	Write-Host "📌 Assignations trouvées : $($assignments.Count)" -ForegroundColor Cyan
	foreach ($a in $assignments) {
		$intent = $a.intent
		$gName = $null
		try {
			if ($a.target.groupId) {
				$gid = $a.target.groupId
				try {
					$grp = Get-MgGroup -GroupId $gid -ErrorAction SilentlyContinue
					$gName = if ($grp) { $grp.DisplayName } else { $gid }
				} catch { $gName = $gid }
			}
		} catch {}
		$dispGroup = if ([string]::IsNullOrWhiteSpace($gName)) { '<inconnu>' } else { $gName }
		Write-Host ("   - {0}`t→ {1}" -f $intent, $dispGroup) -ForegroundColor White
	}

	Write-Host ''
	Write-Host "⚠️  $($assignments.Count) assignation(s) seront supprimées." -ForegroundColor Yellow
	$confirm = Read-Host 'Confirmer la suppression ? (O/N)'
	if ($confirm -notin @('O', 'o', 'Y', 'y', 'Oui', 'yes')) {
		Write-Host 'Opération annulée.' -ForegroundColor Yellow
		return
	}

	foreach ($a in $assignments) {
		$aid = $null; $gName = $null; $intent = $null
		try { $aid = $a.id } catch {}
		try { $intent = $a.intent } catch {}
		try {
			if ($a.PSObject.Properties['target']) {
				$gid = $a.target.groupId
				if ($gid) {
					try {
						$grp = Get-MgGroup -GroupId $gid -ErrorAction SilentlyContinue
						if ($grp) { $gName = $grp.DisplayName } else { $gName = $gid }
					} catch { $gName = $gid }
				}
			}
		} catch {}
		if (-not $aid) { continue }

		$uri = "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps/$AppId/assignments/$aid"
		try {
			Invoke-MgGraphRequest -Method DELETE -Uri $uri -ErrorAction Stop | Out-Null
			if ($gName) { Write-Host "🗑️  Suppression '$intent' pour groupe $gName : OK" -ForegroundColor Green }
			else { Write-Host "🗑️  Suppression assignation $aid : OK" -ForegroundColor Green }
		} catch {
			Write-Host "❌ Échec suppression assignation $aid : $($_.Exception.Message)" -ForegroundColor Red
		}
	}
}


# ================== ACTIONS (flux métier) ==================
function Ensure-Group {
	param([Parameter(Mandatory)][string]$DisplayName)

	# Échapper les apostrophes pour OData (' -> '')
	$escaped = $DisplayName -replace "'", "''"

	$existing = Get-MgGroup -Filter "displayName eq '$escaped'" -ConsistencyLevel eventual -CountVariable Count
	if ($existing) { return $existing.Id }

	$mailNick = ($DisplayName -replace '\s', '')
	$newg = New-MgGroup -DisplayName $DisplayName -MailEnabled:$false -MailNickname $mailNick -SecurityEnabled:$true -GroupTypes @()
	return $newg.Id
}


function Action-AssignAppToDefaultGroups {
	param([Parameter(Mandatory)][string]$AppId)

	# 0) Préfixe requis
	$prefix = $Config.GroupPrefix
	if (-not $prefix) {
		Write-Host "❌ Préfixe de groupes non défini. Configure-le d'abord via le menu (option 4)." -ForegroundColor Red
		return
	}

	# 1) App
	Write-Host "`nRecherche de l'application avec AppId $AppId..." -ForegroundColor Cyan
	$App = Get-IntuneMobileAppById -Id $AppId
	if (-not $App) { Write-Host "❌ Application introuvable avec l'AppId $AppId" -ForegroundColor Red; return }
	$AppName = $App.DisplayName
	Write-Host "✅ Application trouvée : $AppName" -ForegroundColor Green

	# 2) Groupes (création si nécessaire)
	$GroupsNeeded = @(
		"$prefix$AppName-Required",
		"$prefix$AppName-Available",
		"$prefix$AppName-Uninstall"
	)
	if ($Config.UsePackagersGroup) {
		$GroupsNeeded += $Config.PackagersGroupName
	}

	$GroupIds = @{}
	foreach ($GroupName in $GroupsNeeded) {
		Write-Host "Vérification du groupe $GroupName..." -ForegroundColor Cyan
		$gid = Ensure-Group -DisplayName $GroupName
		$GroupIds[$GroupName] = $gid
		if ($gid) { Write-Host "✅ Groupe prêt : $GroupName" -ForegroundColor Green }
	}

	# 3) Assignations
	Write-Host "Assignation de l'application $AppName aux groupes..." -ForegroundColor Cyan

	$grpName = "$prefix$AppName-Required"
	Add-AppAssignment -AppId $AppId -GroupId $GroupIds[$grpName] -GroupName $grpName `
		-Intent 'required' -DOPriority 'background' -AppODataType $App.ODataType

	$grpName = "$prefix$AppName-Available"
	Add-AppAssignment -AppId $AppId -GroupId $GroupIds[$grpName] -GroupName $grpName `
		-Intent 'available' -DOPriority 'foreground' -AppODataType $App.ODataType

	$grpName = "$prefix$AppName-Uninstall"
	Add-AppAssignment -AppId $AppId -GroupId $GroupIds[$grpName] -GroupName $grpName `
		-Intent 'uninstall' -DOPriority 'foreground' -AppODataType $App.ODataType

	if ($Config.UsePackagersGroup) {
		$grpName = $Config.PackagersGroupName
		Add-AppAssignment -AppId $AppId -GroupId $GroupIds[$grpName] -GroupName $grpName `
			-Intent 'available' -DOPriority 'foreground' -AppODataType $App.ODataType
	}

	Write-Host "🎉 Terminé. Application $AppName assignée." -ForegroundColor Green
}

function Action-RemoveAllAssignments {
	param([Parameter(Mandatory)][string]$AppId)

	# Récupère l'app pour afficher son nom
	$app = Get-IntuneMobileAppById -Id $AppId
	if ($app) {
		Write-Host ('Application ciblée : {0} (Id: {1})' -f $app.DisplayName, $app.Id) -ForegroundColor Cyan
	} else {
		Write-Host "Application ciblée : <inconnue> (Id: $AppId)" -ForegroundColor Cyan
	}

	# Liste des assignations
	Write-Host 'Recherche des assignations...' -ForegroundColor Cyan
	$assignments = Get-AppAssignments -AppId $AppId
	if (-not $assignments -or $assignments.Count -eq 0) {
		Write-Host "ℹ️  Aucune assignation trouvée pour l'application." -ForegroundColor Yellow
		return
	}

	# Affiche un résumé avant confirmation
	# ...
	Write-Host "📌 Assignations trouvées : $($assignments.Count)" -ForegroundColor Cyan
	foreach ($a in $assignments) {
		$intent = $a.intent
		$gName = $null
		try {
			if ($a.target.groupId) {
				$gid = $a.target.groupId
				try {
					$grp = Get-MgGroup -GroupId $gid -ErrorAction SilentlyContinue
					$gName = if ($grp) { $grp.DisplayName } else { $gid }
				} catch { $gName = $gid }
			}
		} catch {}
		$dispGroup = if ([string]::IsNullOrWhiteSpace($gName)) { '<inconnu>' } else { $gName }
		Write-Host ("   - {0}`t→ {1}" -f $intent, $dispGroup) -ForegroundColor White
	}
	# ...


	Write-Host ''
	Write-Host "⚠️  $($assignments.Count) assignation(s) seront supprimées." -ForegroundColor Yellow
	$confirm = Read-Host 'Confirmer la suppression ? (O/N)'
	if ($confirm -notin @('O', 'o', 'Y', 'y', 'Oui', 'yes')) {
		Write-Host 'Opération annulée.' -ForegroundColor Yellow
		return
	}

	foreach ($a in $assignments) {
		$aid = $null; $gName = $null; $intent = $null
		try { $aid = $a.id } catch {}
		try { $intent = $a.intent } catch {}
		try {
			if ($a.PSObject.Properties['target']) {
				$gid = $a.target.groupId
				if ($gid) {
					try {
						$grp = Get-MgGroup -GroupId $gid -ErrorAction SilentlyContinue
						if ($grp) { $gName = $grp.DisplayName } else { $gName = $gid }
					} catch { $gName = $gid }
				}
			}
		} catch {}
		if (-not $aid) { continue }

		$uri = "https://graph.microsoft.com/v1.0/deviceAppManagement/mobileApps/$AppId/assignments/$aid"
		try {
			Invoke-MgGraphRequest -Method DELETE -Uri $uri -ErrorAction Stop | Out-Null
			if ($gName) { Write-Host "🗑️  Suppression '$intent' pour groupe $gName : OK" -ForegroundColor Green }
			else { Write-Host "🗑️  Suppression assignation $aid : OK" -ForegroundColor Green }
		} catch {
			Write-Host "❌ Échec suppression assignation $aid : $($_.Exception.Message)" -ForegroundColor Red
		}
	}
}


function Action-ConfigureGroupPrefix {
	$new = Read-Host "`nEntrer le préfixe des groupes (ex: Intune-APPS-Win-)"
	if (-not $new) { Write-Host '❌ Préfixe non modifié (entrée vide).' -ForegroundColor Red; return }
	if (-not $Config.GroupPrefix) {
		$Config | Add-Member -NotePropertyName GroupPrefix -NotePropertyValue $new
	} else {
		$Config.GroupPrefix = $new
	}
	Save-Config -Config $Config
	Write-Host "✅ Préfixe enregistré: $($Config.GroupPrefix)" -ForegroundColor Green
}

function Action-ConfigurePackagersGroup {
	Write-Host "`n`nCette option permet de définir si un groupe 'Packageurs' est utilisé pour une assignation 'Available' supplémentaire." -ForegroundColor Cyan
	$ans = Read-Host 'Utiliser un groupe pour les Packageurs ? (O/N)'

	if ($ans -in @('O', 'o', 'Y', 'y', 'Oui', 'yes')) {
		if (-not $Config.GroupPrefix) {
			Write-Host "❌ Impossible de configurer le groupe Packageurs : aucun préfixe défini. Configure d'abord le préfixe (option 4)." -ForegroundColor Red
			return
		}

		# Toujours re-demander le nom lorsqu'on (ré)active l'option
		$defaultName = "$($Config.GroupPrefix)Packageurs"
		$current = if ($Config.PackagersGroupName) { " (actuel: $($Config.PackagersGroupName))" } else { '' }
		$prompt = "Entrer le nom du groupe Packageurs à utiliser$current"

		# $prompt = "`nEntrer le nom du groupe Packageurs à utiliser$current"
		$name = Read-Host $prompt
		if ([string]::IsNullOrWhiteSpace($name)) { $name = $defaultName }

		$Config.UsePackagersGroup = $true
		$Config.PackagersGroupName = $name
		Save-Config -Config $Config

		Write-Host "✅ Groupe Packageurs activé: $($Config.PackagersGroupName)" -ForegroundColor Green
	} else {
		$Config.UsePackagersGroup = $false
		Save-Config -Config $Config
		Write-Host "✅ L'assignation via un groupe Packageurs est désactivée." -ForegroundColor Green
	}
}


function Show-AppInfo {
	param([Parameter(Mandatory)][string]$AppId)

	Write-Host "`nRecherche de l'application avec AppId $AppId..." -ForegroundColor Cyan
	$App = Get-IntuneMobileAppById -Id $AppId
	if (-not $App) { Write-Host "❌ Application introuvable avec l'AppId $AppId" -ForegroundColor Red; return }
	Write-Host "✅ Application trouvée : $($App.DisplayName)" -ForegroundColor Green
	Write-Host "   ↳ Type: $($App.ODataType)" -ForegroundColor DarkGray

	$assigns = Get-AppAssignments -AppId $AppId
	if (-not $assigns -or $assigns.Count -eq 0) {
		Write-Host 'ℹ️  Aucune assignation trouvée.' -ForegroundColor Yellow
		return
	}

	Write-Host '📌 Assignations actuelles:' -ForegroundColor Cyan
	foreach ($a in $assigns) {
		$intent = $a.intent
		$gName = $null
		try {
			if ($a.target.groupId) {
				$gid = $a.target.groupId
				try {
					$grp = Get-MgGroup -GroupId $gid -ErrorAction SilentlyContinue
					$gName = if ($grp) { $grp.DisplayName } else { $gid }
				} catch { $gName = $gid }
			}
		} catch {}
		Write-Host ("   - {0}`t→ {1}" -f $intent, $gName) -ForegroundColor White
	}
}

# ================== MENU ==================
function Show-Menu {
	Write-Host ''
	Write-Host "============== L'assignateur d'applications Intune ==============" -ForegroundColor Cyan
	Write-Host "Préfixe courant: $($Config.GroupPrefix | ForEach-Object { if ($_){$_} else {'<non défini>'} })"
	$packState = if ($Config.UsePackagersGroup) { "Oui ($($Config.PackagersGroupName))" } else { 'Non' }
	Write-Host "Option Packageurs active: $packState"
	Write-Host ''   # ligne vide après les infos
	Write-Host '1) Assigner une application aux groupes par défaut'
	Write-Host "2) Afficher les assignations d'une application"
	Write-Host "3) Supprimer toutes les assignations d'une application"
	Write-Host ''
	Write-Host '4) Configurer le préfixe des groupes par défaut'
	Write-Host "5) Configurer l'option Packageur"
	Write-Host ''
	Write-Host '6) Quitter'
	Write-Host '================================================='
}

# Boucle principale
while ($true) {
	Show-Menu
	$choice = Read-Host 'Choix'
	switch ($choice) {
		'1' {
			$appIdInput = Read-Host "`nEntrer l'AppId de l'application Intune"
			if (-not $appIdInput) { Write-Host '❌ AppId requis.' -ForegroundColor Red; break }
			Action-AssignAppToDefaultGroups -AppId $appIdInput
		}
		'2' {
			$appIdInput = Read-Host "`nEntrer l'AppId de l'application Intune"
			if (-not $appIdInput) { Write-Host '❌ AppId requis.' -ForegroundColor Red; break }
			Show-AppInfo -AppId $appIdInput
		}
		'3' {
			$appIdInput = Read-Host "`nEntrer l'AppId de l'application Intune"
			if (-not $appIdInput) { Write-Host '❌ AppId requis.' -ForegroundColor Red; break }
			Action-RemoveAllAssignments -AppId $appIdInput
		}
		'4' { Action-ConfigureGroupPrefix }
		'5' { Action-ConfigurePackagersGroup }
		'6' {
			Write-Host 'Au revoir 👋' -ForegroundColor Green
			exit
		}
		default { Write-Host 'Choix invalide.' -ForegroundColor Yellow }
	}
}
