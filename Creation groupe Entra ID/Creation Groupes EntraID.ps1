<#
Création automatique de groupes Entra ID à partir d’un .CSV en format UTF-8 Comma delimited
=======================================================================
Version 19 décembre 2025 (rév. 25 novembre 2026 : gestion des accents + détection « déjà membre »
+ résumé avant connexion + commentaires alignés sur le gabarit "Groupes Template.csv")

Exemple de fichier CSV (Groupes Template.csv)
------------------------------------------
# ============================,,
# Création de groupes Entra ID,,
# Format : les lignes commençant par # et les lignes vides sont ignorees,,
# Sauvegarder en format - CSV UTF-8 Comma delimited,,
# ============================,,
,,
# === Configuration par defaut  ===,,
# Prefix utilisé pour le nom de chaque groupe,,
PREFIX = Device-WIN-,,
,,
# Description du groupe par defaut,,
DESCRIPTION = Groupe d'Appareils Windows,,
,,
# === Définition des groupes ===,,
#Nom du groupe (obligatoire),Groupe parent (facultatif),Description spécifique (facultatif)
,,
# Groupes des laboratoires,,
Tous,,Tous les appareils Windows
Labs,Tous,Appareils Windows de tous les laboratoires
,,
# Groupes des laboratoires,,
Lab 100,Labs,Appareils Windows du Laboratoire 100
Lab 200,Labs,Appareils Windows du Laboratoire 200
------------------------------------------

Configuration (en début de fichier) :
- PREFIX      : préfixe ajouté devant le nom de chaque groupe (colonnes A et B).
- DESCRIPTION : description par défaut des groupes.

Interprétation des colonnes :
- Colonne A : nom du groupe (obligatoire). Groupe créé : <PREFIX><Colonne A>  (ex.: Device-WIN-Lab 100)
- Colonne B : groupe parent (facultatif), désigné par son nom en colonne A (sans le préfixe).
  Le parent doit lui aussi être défini dans le fichier.
- Colonne C : description spécifique (facultatif); si vide, DESCRIPTION est utilisée.

Règles :
- Les lignes vides, celles ne contenant que des ',' (ex.: ',,') et celles commençant par '#'
  sont ignorées.
- Un résumé (nom, description, parent) est affiché avant la connexion à Microsoft Graph.
- Un groupe existant n'est pas modifié; si le groupe est déjà membre du parent, une information
  est affichée (pas d'erreur).

Exécution :
& ".\Creation Groupes EntraID.ps1" -Path ".\Groupes Template.csv"

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

# ------------------------
# Gestion des accents
# ------------------------
# Lecture du CSV avec détection de l'encodage :
#  - UTF-8 avec BOM (« CSV UTF-8 » d'Excel) ou UTF-8 sans BOM
#  - UTF-16 (« Texte Unicode » d'Excel)
#  - sinon Windows-1252 (« CSV séparateur virgule » d'Excel) au lieu de lettres corrompues
function Read-CsvLines {
  param([Parameter(Mandatory)][string]$Path)
  $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).ProviderPath)
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
  } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
    $text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
  } else {
    try {
      $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)   # lève une erreur si UTF-8 invalide
      $text = $strictUtf8.GetString($bytes)
    } catch {
      Write-Warn "Le CSV n'est pas en UTF-8 : lecture en Windows-1252. (Recommandé : enregistrer en « CSV UTF-8 (délimité par des virgules) ».)"
      try   { $enc = [System.Text.Encoding]::GetEncoding(1252) }
      catch { $enc = [System.Text.Encoding]::GetEncoding(28591) }       # Latin-1 si 1252 indisponible
      $text = $enc.GetString($bytes)
    }
  }
  return ($text -split "\r?\n")
}

# JSON pour Graph : tous les caractères non ASCII sont échappés en \uXXXX.
# Le corps envoyé est 100 % ASCII, donc les accents arrivent intacts quel que soit
# l'encodage utilisé par Invoke-MgGraphRequest (Windows PowerShell 5.1 ou PowerShell 7).
function ConvertTo-GraphJson {
  param([Parameter(Mandatory)]$InputObject, [int]$Depth = 5)
  $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth -Compress
  return [regex]::Replace($json, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
}

# URL Graph avec filtre sur displayName : la valeur est encodée (accents, espaces, apostrophes).
function Get-GroupFilterUri {
  param([Parameter(Mandatory)][string]$DisplayName, [string]$Select = "")
  $safe   = $DisplayName.Replace("'", "''")
  $filter = [uri]::EscapeDataString("displayName eq '$safe'")
  $uri    = "https://graph.microsoft.com/v1.0/groups?`$filter=$filter"
  if ($Select) { $uri += "&`$select=$Select" }
  return $uri
}

# mailNickname : accents convertis (é -> e, ç -> c) au lieu d'être supprimés.
function Get-MailNickname {
  param([string]$DisplayName)
  $decomposed = $DisplayName.Normalize([System.Text.NormalizationForm]::FormD)
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $decomposed.ToCharArray()) {
    if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
      [void]$sb.Append($ch)
    }
  }
  $nick = ($sb.ToString() -replace '[^a-zA-Z0-9]', '').ToLower()
  if ($nick.Length -gt 64) { $nick = $nick.Substring(0, 64) }
  if ($nick.Length -eq 0)  { $nick = "grp$(Get-Random -Minimum 10000 -Maximum 99999)" }
  return $nick
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

$content = Read-CsvLines -Path $Path

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

# Résumé de ce qui sera fait (affiché AVANT la connexion)
$csvNames = @($rows | ForEach-Object { $_.Nom })
Write-Host "`nGroupes détectés: $($rows.Count)" -ForegroundColor Green
foreach ($g in $rows) {
    $dn   = "$GlobalPrefix$($g.Nom)"
    $desc = "(aucune)"
    if (-not [string]::IsNullOrWhiteSpace($g.DescriptionGroupe)) { $desc = $g.DescriptionGroupe }
    elseif (-not [string]::IsNullOrWhiteSpace($GlobalDesc))     { $desc = "$GlobalDesc (par défaut)" }
    $par = "(aucun)"
    if ($g.Parents) {
        $par = "$GlobalPrefix$($g.Parents)"
        if ($g.Parents -notin $csvNames) { $par += "  ⚠ absent du CSV : l'imbrication échouera" }
    }
    Write-Host "  • $dn" -ForegroundColor White
    Write-Host "      Description : $desc" -ForegroundColor DarkGray
    Write-Host "      Parent      : $par" -ForegroundColor DarkGray
}


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

# Le groupe enfant est-il (directement ou transitivement) membre du groupe parent ?
# checkMemberGroups s'appelle sur l'ENFANT avec l'ID du PARENT : la réponse contient
# l'ID du parent si l'enfant en est membre.
function Test-TransitiveMembership {
  param(
    [Parameter(Mandatory)][string]$ParentId,
    [Parameter(Mandatory)][string]$ChildId
  )
  try {
    $body = @{ groupIds = @($ParentId) } | ConvertTo-Json
    $resp = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/groups/$ChildId/checkMemberGroups" -Body $body -ErrorAction Stop
    return [bool]($resp -and $resp.value -and ($resp.value -contains $ParentId))
  } catch {
    return $false
  }
}

function Get-GraphErrorMessage {
  param($Err)
  $msg = $Err.Exception.Message
  if ($Err.ErrorDetails -and $Err.ErrorDetails.Message) {
    $raw = $Err.ErrorDetails.Message
    try {
      $j = $raw | ConvertFrom-Json -ErrorAction Stop
      if ($j.error.message) { $msg = $j.error.message }
    } catch {
      if ($raw -match '"message"\s*:\s*"([^"]+)"') { $msg = $Matches[1] } else { $msg = "$msg $raw" }
    }
  }
  return $msg
}

function Add-ChildToParent-Idempotent {
  param([string]$ParentId, [string]$ChildId)

  if ([string]::IsNullOrWhiteSpace($ParentId) -or [string]::IsNullOrWhiteSpace($ChildId)) { return }
  if ($ParentId -eq $ChildId) { Write-Warn "Ignoré (parent == enfant)."; return }

  # 1) Déjà membre (direct ou transitif) ? → information seulement
  if (Test-TransitiveMembership -ParentId $ParentId -ChildId $ChildId) {
    Write-Info "Déjà membre du groupe parent (aucune modification)."
    return
  }

  # 2) Boucle ? (le parent est-il déjà membre, directement ou non, de l'enfant ?)
  if (Test-TransitiveMembership -ParentId $ChildId -ChildId $ParentId) {
    Write-ErrorX "Imbrication refusée : le groupe parent est déjà membre de ce groupe (boucle)."
    return
  }

  # 3) Ajout; nouvelles tentatives seulement pour les erreurs temporaires
  $refJson = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$ChildId" } | ConvertTo-Json
  for ($try = 1; $try -le 3; $try++) {
    try {
      Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/groups/$ParentId/members/`$ref" -Body $refJson -ErrorAction Stop | Out-Null
      Write-Ok "Ajouté"
      return
    } catch {
      $msg = Get-GraphErrorMessage $_

      # Déjà membre : information, pas une erreur
      if ($msg -match 'already exist' -or (Test-TransitiveMembership -ParentId $ParentId -ChildId $ChildId)) {
        Write-Info "Déjà membre du groupe parent (aucune modification)."
        return
      }

      # Réessayer seulement les erreurs temporaires (latence de création, throttling, 5xx)
      $transient = $_.Exception.Message -match 'NotFound|TooManyRequests|429|5\d\d|ServiceUnavailable|InternalServerError|GatewayTimeout'
      if ($transient -and $try -lt 3) { Start-Sleep -Milliseconds (800 * $try); continue }

      Write-ErrorX "Ajout membre a échoué : $msg"
      return
    }
  }
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
  $existing = (Invoke-MgGraphRequest -Method GET `
      -Uri (Get-GroupFilterUri -DisplayName $displayName) `
      -ErrorAction SilentlyContinue).value

  if ($existing) {
      $id = $existing[0].id
      $GroupCache[$g.Nom]           = $id
      $DisplayCache[$displayName]   = $id
      Write-Info "✓ Groupe existant: $displayName"
      continue
  }

  # mailNickname OBLIGATOIRE et valide
  $mailNickname = Get-MailNickname $displayName

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
          -Body (ConvertTo-GraphJson $body)

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
