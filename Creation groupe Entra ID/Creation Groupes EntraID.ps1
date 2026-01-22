<#
Création automatique de groupes Entra ID à partir d’un .CSV en format UTF-8 Comma delimited
=======================================================================
Version 19 décembre 2025

------------------------------------------
# === Configuration par defaut  ===,,
PREFIX = Devices-WIN-,,
DESCRIPTION = Groupe d'Appareils Windows,,
,,
# === Définition des groupes ===,,
# Format a respecter,,
#Nom du groupe (obligatoire),Groupe parent (facultatif),Description (facultatif)
,,
# Groupes des laboratoires,,
Labs,,Appareils Windows de tous les laboratoires
,,
# Groupes des laboratoires 1000,,
Labs 1000,Labs,Appareils Windows de tous les laboratoires 1000
Lab 1001,Labs 1000,Appareils Windows du Laboratoire 1001
Lab 1002,Labs 1000,Appareils Windows du Laboratoire 1002
...

Règles :
- Les lignes vides, celles ne contenant que des ';' (ex.: ';;') et celles commençant par '#'
  sont ignorées.
- Le nom de groupe est obligatoire; le parent et la description sont facultatifs.

Exécution :
& ".\Creation Groupes EntraID.ps1" -path ".\Groupes Lab ChezLangis.csv"

#>

[CmdletBinding()]
param([Parameter(Mandatory)] [string]$Path)

# ------------------------
# Fonctions utilitaires
# ------------------------
function Write-Info   { param($m) Write-Host "[INFO ] $m" -ForegroundColor Cyan }
function Write-Ok     { param($m) Write-Host "[ OK  ] $m" -ForegroundColor Green }
function Write-Warn   { param($m) Write-Host "[WARN ] $m" -ForegroundColor Yellow }
function Write-ErrorX { param($m) Write-Host "[ERR  ] $m" -ForegroundColor Red }

function Slugify {
  param([string]$s)
  return ($s -replace '[^a-zA-Z0-9]','').ToLower()
}

# Fonction à inclure dans les scripts pour gérer une connexion MgGraph
# Validation des scopes, affichage de la connexion actuelle et option pour se connecter dans un autre tenant.
# Samuel Langis 15 décembre 2025
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
# ------------------------
# Vérification et lecture du fichier CSV (UTF-8-BOM Excel)
# ------------------------
if (-not (Test-Path $Path)) {
    throw "Fichier introuvable: $Path"
}

$content = Get-Content -Path $Path -Encoding UTF8

if (-not $content -or $content.Count -eq 0) {
    throw "Le fichier est vide ou illisible."
}

# ------------------------
# Extraire PREFIX / DESCRIPTION (Excel UTF-8-BOM safe)
# ------------------------
$GlobalPrefix = ""
$GlobalDesc   = ""
$groupLines   = @()

foreach ($line in $content) {

    $l = $line.Trim()

    # ignorer commentaires / lignes vides
    if ($l -eq "" -or $l.StartsWith("#")) {
        continue
    }

    # Nettoyer les virgules multiples à la fin
    $l = $l -replace ',+$', ''

    # PREFIX = xxx
    if ($l -match '^(?i)PREFIX\s*=\s*(.*)$') {
        $GlobalPrefix = $Matches[1].Trim()
        continue
    }

    # DESCRIPTION = xxx (peut être vide)
    if ($l -match '^(?i)DESCRIPTION\s*=\s*(.*)$') {
        $GlobalDesc = $Matches[1].Trim()
        continue
    }

    # sinon => ligne de groupe
    $groupLines += $l
}

Write-Host "PREFIX='$GlobalPrefix' | DESC par défaut='$GlobalDesc'" -ForegroundColor Cyan

# ------------------------
# Lecture des groupes
# ------------------------
$rows = @()

foreach ($line in $groupLines) {

    $l = $line.Trim()

    # garde-fous
    if ($l -eq "" -or $l -match '^\s*,+\s*$') { continue }

    # Découpage CSV manuel et sûr
    $p = $l -split ','

    # Nom du groupe = TOUJOURS la première colonne, nettoyée
    $name = ($p[0] -replace '[^a-zA-Z0-9À-ÿ _-]', '').Trim()

    if ([string]::IsNullOrWhiteSpace($name)) {
        continue
    }

    $rows += [PSCustomObject]@{
        Nom               = $name
        Parents           = if ($p.Count -gt 1) { $p[1].Trim() } else { "" }
        DescriptionGroupe = if ($p.Count -gt 2) { $p[2].Trim() } else { "" }
    }

}

Write-Host "Groupes détectés: $($rows.Count)" -ForegroundColor Green


# Connexion Microsoft Graph
Connect-OrSwitchTenant -RequiredScopes @(
  "Group.ReadWrite.All",
  "GroupMember.ReadWrite.All",
  "Directory.Read.All"
)

# ------------------------
# Utilitaires d'appartenance (idempotents et robustes)
# ------------------------
function Get-GroupMemberIdSet {
  param([string]$GroupId)
  # Toujours retourner un HashSet (never-throw)
  $ids = New-Object System.Collections.Generic.HashSet[string]
  $uri = "https://graph.microsoft.com/v1.0/groups/$GroupId/members?`$select=id"

  while ($true) {
    $resp = $null
    for ($try = 1; $try -le 3; $try++) {
      try { $resp = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop; break }
      catch {
        $msg = $_.Exception.Message
        if ($try -lt 3 -and ($msg -match '429' -or $msg -match '5\d\d')) { Start-Sleep -Milliseconds (400*$try); continue }
        return $ids
      }
    }
    if (-not $resp) { break }

    if ($resp.PSObject.Properties.Match('value').Count -gt 0 -and $resp.value) {
      foreach ($m in $resp.value) {
        if ($m -and $m.PSObject.Properties.Match('id').Count -gt 0 -and $m.id) { [void]$ids.Add([string]$m.id) }
      }
    }

    if ($resp.PSObject.Properties.Match('@odata.nextLink').Count -gt 0 -and $resp.'@odata.nextLink') {
      $uri = $resp.'@odata.nextLink'
    } else {
      break
    }
  }
  return $ids
}

function Test-TransitiveMembership {
  param(
    [Parameter(Mandatory)][string]$ParentId,
    [Parameter(Mandatory)][string]$ChildId
  )
  try {
    $body = @{ ids = @($ChildId) } | ConvertTo-Json
    $resp = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/groups/$ParentId/checkMemberObjects" -Body $body -ErrorAction Stop
    # L’API renvoie un tableau d’IDs présents (transitifs). Si $ChildId est dedans ⇒ déjà membre.
    if ($resp -and $resp.value -and ($resp.value -contains $ChildId)) { return $true }
  } catch {
    # En cas d’erreur, on considère “inconnu” ⇒ $false, l’appelant décidera
    return $false
  }
  return $false
}


function Add-ChildToParent-Idempotent {
  param([string]$ParentId, [string]$ChildId)

  if ([string]::IsNullOrWhiteSpace($ParentId) -or [string]::IsNullOrWhiteSpace($ChildId)) { return }
  if ($ParentId -eq $ChildId) { Write-Warn "Ignoré (parent == enfant)."; return }

  # 1) Déjà membre (transitif) ? → skip (couvre direct et indirect)
  if (Test-TransitiveMembership -ParentId $ParentId -ChildId $ChildId) {
    Write-Warn "Déjà membre (transitif — skippé)."
    return
  }

  # 2) Boucle ? (le parent est-il déjà dans les membres transitifs de l'enfant ?)
  if (Test-TransitiveMembership -ParentId $ChildId -ChildId $ParentId) {
    Write-ErrorX "Le groupe est déjà membre du groupe parent"
    return
  }

  # 3) Tentative d’ajout avec 2 retries courts (éventuelle latence de création)
  $refJson = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$ChildId" } | ConvertTo-Json
  $ok = $false
  for ($try=1; $try -le 3 -and -not $ok; $try++) {
    try {
      Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/groups/$ParentId/members/`$ref" -Body $refJson -ErrorAction Stop | Out-Null
      $ok = $true
    } catch {
      if ($try -lt 3) { Start-Sleep -Milliseconds (400 * $try) }  # backoff léger
      else {
        # 4) Dernier échec → re-teste membership transitive :
        if (Test-TransitiveMembership -ParentId $ParentId -ChildId $ChildId) {
          Write-Warn "Déjà membre (transitif — skippé)."
        } else {
          # Extraire un message lisible si Graph en fournit un
          $msg = $_.Exception.Message
          if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            try { $j = $_.ErrorDetails.Message | ConvertFrom-Json; if ($j.error.message) { $msg = $j.error.message } } catch {}
          }
          if ($msg -match 'added object references already exist') {
            Write-Warn "Déjà membre (skippé)."
          } else {
            Write-ErrorX "Ajout membre a échoué : $msg"
          }
        }
        return
      }
    }
  }

  if ($ok) { Write-Ok "Ajouté" }
}


# ------------------------
# Création / MàJ des groupes
# ------------------------
$GroupCache   = @{}  # clé = nom SANS préfixe (CSV), valeur = groupId
$DisplayCache = @{}  # clé = DisplayName complet, valeur = groupId

foreach ($g in $rows) {

  # DisplayName
  $displayName = if ([string]::IsNullOrWhiteSpace($GlobalPrefix)) {
      $g.Nom
  } else {
      "$GlobalPrefix$($g.Nom)"
  }

  # Description finale (peut être vide)
  $description = if (-not [string]::IsNullOrWhiteSpace($g.DescriptionGroupe)) {
      $g.DescriptionGroupe
  } elseif (-not [string]::IsNullOrWhiteSpace($GlobalDesc)) {
      $GlobalDesc
  } else {
      ""
  }

  if ([string]::IsNullOrWhiteSpace($displayName)) {
      Write-Warn "Ligne ignorée (nom vide)."
      continue
  }

  # Cache local
  if ($DisplayCache.ContainsKey($displayName)) {
      $GroupCache[$g.Nom] = $DisplayCache[$displayName]
      Write-Info "✓ Groupe existant (cache): $displayName"
      continue
  }

  # Recherche Graph
  $safeName = $displayName.Replace("'","''")
  $existing = (Invoke-MgGraphRequest -Method GET `
      -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$safeName'" `
      -ErrorAction SilentlyContinue).value

  if ($existing) {
      $id = $existing[0].id
      $GroupCache[$g.Nom]           = $id
      $DisplayCache[$displayName]   = $id
      Write-Info "✓ Groupe existant: $displayName"
      continue
  }

  # mailNickname OBLIGATOIRE et valide
  $mailNickname = ($displayName -replace '[^a-zA-Z0-9]', '').ToLower()
  if ($mailNickname.Length -gt 64) {
      $mailNickname = $mailNickname.Substring(0,64)
  }
  if ($mailNickname.Length -eq 0) {
      $mailNickname = "grp$(Get-Random -Minimum 10000 -Maximum 99999)"
  }

  # Corps Graph
  $body = @{
      displayName     = $displayName
      mailEnabled     = $false
      mailNickname    = $mailNickname
      securityEnabled = $true
  }

  # Description UNIQUEMENT si non vide
  if (-not [string]::IsNullOrWhiteSpace($description)) {
      $body.description = $description
  }

  try {
      $newGroup = Invoke-MgGraphRequest -Method POST `
          -Uri "https://graph.microsoft.com/v1.0/groups" `
          -Body ($body | ConvertTo-Json -Depth 5)

      $GroupCache[$g.Nom]         = $newGroup.id
      $DisplayCache[$displayName] = $newGroup.id
      Write-Ok "Créé: $displayName"
  }
  catch {
      Write-ErrorX "Erreur création groupe $displayName : $($_.Exception.Message)"
  }
}


# ------------------------
# Gestion des appartenances (idempotent)
# ------------------------
foreach ($g in $rows) {
  if (-not $g.Parents) { continue }

  $parentKey = $g.Parents
  $childKey  = $g.Nom

  if (-not $GroupCache.ContainsKey($parentKey)) {
    Write-ErrorX "Parent '$parentKey' non défini (aucun groupe de ce nom trouvé/créé)."
    continue
  }
  if (-not $GroupCache.ContainsKey($childKey)) {
    Write-ErrorX "Enfant '$childKey' non défini (aucun groupe de ce nom trouvé/créé)."
    continue
  }

  $parentId = $GroupCache[$parentKey]
  $childId  = $GroupCache[$childKey]

  $parentName = if ([string]::IsNullOrWhiteSpace($GlobalPrefix)) { $parentKey } else { "$GlobalPrefix$parentKey" }
  $childName  = if ([string]::IsNullOrWhiteSpace($GlobalPrefix)) { $childKey }  else { "$GlobalPrefix$childKey"  }

  Write-Info "Ajout membre: $childName → $parentName"
  Add-ChildToParent-Idempotent -ParentId $parentId -ChildId $childId
}

Write-Ok "Terminé."
