<#
Création automatique de groupes DYNAMIQUES d'appareils Entra ID à partir d'un .CSV
en format UTF-8 Comma delimited (variante de "Creation Groupes EntraID.ps1")
=======================================================================
Version 25 novembre 2026 (rév. 5 : commentaires alignés sur le gabarit "Groupes Template -Dynamique.csv")

Exemple de fichier CSV (Groupes Template -Dynamique.csv)
------------------------------------------
# ============================,,
"# Création de groupes Entra ID ""Dynamique Device"" avec une règle basée sur le nom du poste",,
# Format : les lignes commençant par # et les lignes vides sont ignorees,,
# Sauvegarder en format - CSV UTF-8 Comma delimited,,
# ============================,,
,,
# === Configuration par defaut  ===,,
# Prefix utilisé pour la création du  nom du groupe dynamique,,
PREFIX DYNAMIQUE = DYN-WIN-,,
# Prefix utilisé pour le nom du groupe parent,,
PREFIX PARENT = Device-WIN-,,
,,
# Description du groupe dynamique par defaut,,
DESCRIPTION = Groupe de devices dynamique utilisé uniquement pour peupler les groupes de base,,
,,
# Syntaxe de la règle dynamique utilisée,,
"REGLE = (device.displayName -startsWith ""COLONNE A"") and (device.deviceTrustType -eq ""ServerAd"")",,
"#REGLE = (device.displayName -startsWith ""COLONNE A"") and ( (device.deviceTrustType -eq ""ServerAd"") or (device.deviceTrustType -eq ""AzureAD""))",,
,,
# === Définition des groupes ===,,
# Début du nom des postes (obligatoire),Groupe parent (facultatif),Description spécifique(facultatif)
,,
LAB100,Lab 100,
LAB200,Lab 200,
------------------------------------------

Configuration (en début de fichier) :
- PREFIX DYNAMIQUE : préfixe ajouté devant la colonne A pour nommer le groupe dynamique créé.
- PREFIX PARENT    : préfixe ajouté devant la colonne B pour trouver le groupe parent.
- DESCRIPTION      : description par défaut du groupe dynamique.
- REGLE            : règle d'appartenance dynamique; le texte "COLONNE A" y est remplacé par
                     la valeur de la colonne A. Une seule ligne REGLE active : pour garder une
                     règle de rechange, la mettre en commentaire ("#REGLE = ...").

Interprétation des colonnes :
- Colonne A : début du nom des postes (obligatoire). Valeur utilisée
    1) pour le nom du groupe dynamique créé : <PREFIX DYNAMIQUE><Colonne A>  (ex.: DYN-WIN-LAB100)
    2) dans la règle, à la place de "COLONNE A"   (ex.: device.displayName -startsWith "LAB100")
- Colonne B : groupe parent <PREFIX PARENT><Colonne B> (ex.: Device-WIN-Lab 100) (facultatif).
  Il n'est PAS créé : il doit déjà exister et être un groupe à appartenance attribuée (pas dynamique).
- Colonne C : description spécifique (facultatif); si vide, DESCRIPTION est utilisée.

Règles :
- Les lignes vides, celles ne contenant que des ',' et celles commençant par '#' sont ignorées
  (y compris les commentaires qu'Excel met entre guillemets, ex.: "# ... ""Dynamique Device"" ...").
- Les champs entre guillemets (ex.: la ligne REGLE enregistrée par Excel) sont gérés.
- Un résumé (nom, règle, description, parent) est affiché avant la connexion à Microsoft Graph.
- Un groupe dynamique existant n'est pas modifié; un avertissement est affiché si sa règle diffère.
- Si le groupe est déjà membre du parent, une information est affichée (pas d'erreur).
- Nécessite une licence Entra ID P1 (groupes dynamiques).

Exécution :
& ".\Creation Groupes EntraID Dynamiques.ps1" -Path ".\Groupes Template -Dynamique.csv"

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

# Découpage d'une ligne CSV (gère les champs entre guillemets et les "" doublés par Excel)
function Split-CsvLine {
  param([string]$Line)
  $fields = New-Object System.Collections.Generic.List[string]
  $sb = New-Object System.Text.StringBuilder
  $inQuotes = $false
  for ($i = 0; $i -lt $Line.Length; $i++) {
    $c = $Line[$i]
    if ($inQuotes) {
      if ($c -eq '"') {
        if ($i + 1 -lt $Line.Length -and $Line[$i + 1] -eq '"') { [void]$sb.Append('"'); $i++ }
        else { $inQuotes = $false }
      } else { [void]$sb.Append($c) }
    } else {
      if     ($c -eq '"') { $inQuotes = $true }
      elseif ($c -eq ',') { $fields.Add($sb.ToString()); [void]$sb.Clear() }
      else                { [void]$sb.Append($c) }
    }
  }
  $fields.Add($sb.ToString())
  return ,$fields.ToArray()
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

    function Get-MissingScopes {
        param([string[]]$Required, [string[]]$Granted)
        $Required | Where-Object { $_ -notin $Granted }
    }

    try { $ctx = Get-MgContext } catch { $ctx = $null }

    if (-not $ctx -or -not $ctx.Account) {
        Write-Host "`n🔐 Aucune session Microsoft Graph active." -ForegroundColor Yellow
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Write-Host "`n🔄 Connexion Microsoft Graph..." -ForegroundColor Yellow
        Connect-MgGraph -Scopes $RequiredScopes -ContextScope CurrentUser -NoWelcome
    }

    do {
        $ctx = Get-MgContext

        $missingScopes = Get-MissingScopes -Required $RequiredScopes -Granted $ctx.Scopes
        if ($missingScopes) {
            Write-Host "`n⚠️ Scopes requis manquants :" -ForegroundColor Yellow
            $missingScopes | ForEach-Object { Write-Host "   ❌ $_" -ForegroundColor Red }
            Write-Host "`n🔄 Reconnexion avec les bons scopes..." -ForegroundColor Yellow
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            Connect-MgGraph -Scopes $RequiredScopes -ContextScope CurrentUser -NoWelcome
            continue
        }

        $tenant = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/organization"

        Write-Host "`n✅ Connecté en tant que :" -ForegroundColor Green
        Write-Host "`t$($ctx.Account)" -ForegroundColor Yellow
        Write-Host "✅ Sur le tenant :" -ForegroundColor Green
        Write-Host "`t'$($tenant.value[0].displayName)' ($($ctx.TenantId))" -ForegroundColor Yellow

        $keep = Read-Host "`nVoulez-vous conserver cette connexion ? (O/N)"
        if ($keep -match '^(o|oui|y|yes)$') {
            Write-Host "`n🔒 Connexion conservée." -ForegroundColor Green
            break
        }

        Write-Host "`n🔄 Changement de tenant..." -ForegroundColor Yellow
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Connect-MgGraph -Scopes $RequiredScopes -ContextScope CurrentUser -NoWelcome
    }
    while ($true)

    $ctx = Get-MgContext
    $activeRequiredScopes = $RequiredScopes | Where-Object { $_ -in $ctx.Scopes }

    Write-Host "`n🔑 Scopes requis actifs :" -ForegroundColor Green
    $activeRequiredScopes | Sort-Object | ForEach-Object { Write-Host "   ✔ $_" -ForegroundColor DarkGreen }
    Write-Host "`n`n"

    if ($activeRequiredScopes.Count -ne $RequiredScopes.Count) {
        throw "❌ Tous les scopes requis ne sont pas actifs. Arrêt du script.`n"
    }
}

# ------------------------
# Vérification et lecture du fichier CSV (UTF-8-BOM Excel)
# ------------------------
if (-not (Test-Path $Path)) { throw "Fichier introuvable: $Path" }

$content = Read-CsvLines -Path $Path
if (-not $content -or $content.Count -eq 0) { throw "Le fichier est vide ou illisible." }

# ------------------------
# Extraire PREFIX PARENT / PREFIX DYNAMIQUE / DESCRIPTION / REGLE + lignes de groupes
# ------------------------
$GlobalParentPrefix = ""
$GlobalDynPrefix = ""
$GlobalDesc      = ""
$GlobalRule      = ""
$Placeholder     = "COLONNE A"
$rows            = @()

foreach ($line in $content) {

    $l = $line.Trim()
    if ($l -eq "" -or $l.StartsWith("#") -or $l -match '^\s*,+\s*$') { continue }

    $p  = Split-CsvLine $l
    $c0 = $p[0].Trim()
    if ($c0 -eq "" -or $c0.StartsWith("#")) { continue }

    if ($c0 -match '^(?i)PREFIX\s+PARENT\s*=\s*(.*)$')   { $GlobalParentPrefix = $Matches[1].Trim(); continue }
    if ($c0 -match '^(?i)PREFIX\s+DYNAMIQUE\s*=\s*(.*)$') { $GlobalDynPrefix    = $Matches[1].Trim(); continue }
    # Ancien format "PREFIX = ..." ou autre clé PREFIX inconnue : arrêt (sinon elle serait lue comme un groupe)
    if ($c0 -match '^(?i)PREFIX\b[^=]*=') {
        throw "Ligne de configuration non reconnue : '$c0'. Utiliser 'PREFIX PARENT = ...' et 'PREFIX DYNAMIQUE = ...'."
    }
    if ($c0 -match '^(?i)DESCRIPTION\s*=\s*(.*)$')        { $GlobalDesc      = $Matches[1].Trim(); continue }
    if ($c0 -match '^(?i)R[EÈÉ]GLE\s*=\s*(.*)$')          { $GlobalRule      = $Matches[1].Trim(); continue }

    # Ligne de groupe
    $name = ($c0 -replace '[^a-zA-Z0-9À-ÿ _-]', '').Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { continue }

    $rows += [PSCustomObject]@{
        Nom               = $name
        Parent            = if ($p.Count -gt 1) { $p[1].Trim() } else { "" }
        DescriptionGroupe = if ($p.Count -gt 2) { $p[2].Trim() } else { "" }
    }
}

Write-Host "PREFIX PARENT='$GlobalParentPrefix' | PREFIX DYNAMIQUE='$GlobalDynPrefix' | DESC par défaut='$GlobalDesc'" -ForegroundColor Cyan
Write-Host "REGLE='$GlobalRule'" -ForegroundColor Cyan

# Validations bloquantes AVANT toute connexion
if ([string]::IsNullOrWhiteSpace($GlobalRule)) {
    throw "Aucune ligne 'REGLE = ...' trouvée dans le fichier."
}
if (-not $GlobalRule.Contains($Placeholder)) {
    throw "La REGLE ne contient pas le texte '$Placeholder' à remplacer par la colonne A."
}
if ([string]::IsNullOrWhiteSpace($GlobalDynPrefix)) {
    Write-Warn "PREFIX DYNAMIQUE vide : les groupes dynamiques seront nommés avec la colonne A seulement."
}
if ([string]::IsNullOrWhiteSpace($GlobalParentPrefix) -and ($rows | Where-Object { $_.Parent })) {
    Write-Warn "PREFIX PARENT vide : les groupes parents seront recherchés avec la colonne B seulement."
}
if ($rows.Count -eq 0) { throw "Aucun groupe détecté dans le fichier." }

# Calcul du plan (nom, règle, description, parent) pour chaque ligne
foreach ($g in $rows) {
    $g | Add-Member -NotePropertyName DisplayName -NotePropertyValue "$GlobalDynPrefix$($g.Nom)"
    $g | Add-Member -NotePropertyName Regle       -NotePropertyValue ($GlobalRule.Replace($Placeholder, $g.Nom))
    $g | Add-Member -NotePropertyName Description -NotePropertyValue $(
        if (-not [string]::IsNullOrWhiteSpace($g.DescriptionGroupe)) { $g.DescriptionGroupe } else { $GlobalDesc })
    $g | Add-Member -NotePropertyName ParentName  -NotePropertyValue $(
        if ($g.Parent) { "$GlobalParentPrefix$($g.Parent)" } else { "" })
}

Write-Host "`nGroupes dynamiques détectés: $($rows.Count)" -ForegroundColor Green
foreach ($g in $rows) {
    Write-Host "  • $($g.DisplayName)" -ForegroundColor White
    Write-Host "      Règle       : $($g.Regle)" -ForegroundColor DarkGray
    Write-Host "      Description : $($g.Description)" -ForegroundColor DarkGray
    Write-Host "      Parent      : $(if ($g.ParentName) { $g.ParentName } else { '(aucun)' })" -ForegroundColor DarkGray
}

# Connexion Microsoft Graph
Connect-OrSwitchTenant -RequiredScopes @(
  "Group.ReadWrite.All",
  "GroupMember.ReadWrite.All",
  "Directory.Read.All"
)

# ------------------------
# Utilitaires Graph
# ------------------------
function Get-GraphErrorMessage {
  param($Err)
  $msg = $Err.Exception.Message
  if ($Err.ErrorDetails -and $Err.ErrorDetails.Message) {
    $raw = $Err.ErrorDetails.Message
    try {
      $j = $raw | ConvertFrom-Json -ErrorAction Stop
      if ($j.error.message) { $msg = $j.error.message }
    } catch {
      # Le corps n'est pas du JSON pur : extraire "message" s'il est présent
      if ($raw -match '"message"\s*:\s*"([^"]+)"') { $msg = $Matches[1] } else { $msg = "$msg $raw" }
    }
  }
  return $msg
}

function Get-GroupByName {
  param([string]$DisplayName)
  $uri  = Get-GroupFilterUri -DisplayName $DisplayName -Select "id,displayName,groupTypes,membershipRule"
  $res  = (Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop).value
  if (-not $res) { return $null }
  if (@($res).Count -gt 1) { Write-Warn "Plusieurs groupes nommés '$DisplayName' : le premier est utilisé." }
  return @($res)[0]
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

function Add-ChildToParent-Idempotent {
  param([string]$ParentId, [string]$ChildId)

  if ([string]::IsNullOrWhiteSpace($ParentId) -or [string]::IsNullOrWhiteSpace($ChildId)) { return }
  if ($ParentId -eq $ChildId) { Write-Warn "Ignoré (parent == enfant)."; return }

  if (Test-TransitiveMembership -ParentId $ParentId -ChildId $ChildId) {
    Write-Info "Déjà membre du groupe parent (aucune modification)."
    return
  }

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
# 1) Vérification des groupes parents (doivent exister, ne sont jamais créés)
# ------------------------
$ParentCache = @{}   # clé = DisplayName parent, valeur = id (ou $null si invalide)

foreach ($parentName in ($rows | Where-Object { $_.ParentName } | Select-Object -ExpandProperty ParentName -Unique)) {
  try {
    $pg = Get-GroupByName $parentName
  } catch {
    Write-ErrorX "Recherche du parent '$parentName' impossible : $(Get-GraphErrorMessage $_)"
    $ParentCache[$parentName] = $null
    continue
  }
  if (-not $pg) {
    Write-ErrorX "Parent introuvable (il doit déjà exister) : $parentName"
    $ParentCache[$parentName] = $null
  } elseif ($pg.groupTypes -contains 'DynamicMembership') {
    Write-ErrorX "Parent '$parentName' est un groupe dynamique : impossible d'y ajouter des membres."
    $ParentCache[$parentName] = $null
  } else {
    Write-Info "✓ Parent trouvé : $parentName"
    $ParentCache[$parentName] = $pg.id
  }
}

# ------------------------
# 2) Création des groupes dynamiques
# ------------------------
$DynCache = @{}   # clé = DisplayName dynamique, valeur = id

foreach ($g in $rows) {

  $displayName = $g.DisplayName

  if ($DynCache.ContainsKey($displayName)) {
    Write-Info "✓ Groupe existant (cache): $displayName"
    continue
  }

  try {
    $existing = Get-GroupByName $displayName
  } catch {
    Write-ErrorX "Recherche du groupe '$displayName' impossible : $(Get-GraphErrorMessage $_)"
    continue
  }

  if ($existing) {
    $DynCache[$displayName] = $existing.id
    if ($existing.groupTypes -notcontains 'DynamicMembership') {
      Write-Warn "Groupe existant NON dynamique (non modifié) : $displayName"
    } elseif ($existing.membershipRule -ne $g.Regle) {
      Write-Warn "Groupe dynamique existant avec une règle différente (non modifié) : $displayName"
      Write-Warn "   Actuelle : $($existing.membershipRule)"
      Write-Warn "   Attendue : $($g.Regle)"
    } else {
      Write-Info "✓ Groupe dynamique existant : $displayName"
    }
    continue
  }

  # mailNickname obligatoire et valide
  $mailNickname = Get-MailNickname $displayName

  $body = @{
      displayName                   = $displayName
      mailEnabled                   = $false
      mailNickname                  = $mailNickname
      securityEnabled               = $true
      groupTypes                    = @("DynamicMembership")
      membershipRule                = $g.Regle
      membershipRuleProcessingState = "On"
  }
  if (-not [string]::IsNullOrWhiteSpace($g.Description)) { $body.description = $g.Description }

  try {
      $newGroup = Invoke-MgGraphRequest -Method POST `
          -Uri "https://graph.microsoft.com/v1.0/groups" `
          -Body (ConvertTo-GraphJson $body) -ErrorAction Stop

      $DynCache[$displayName] = $newGroup.id
      Write-Ok "Créé (dynamique): $displayName"
  }
  catch {
      Write-ErrorX "Erreur création groupe $displayName : $(Get-GraphErrorMessage $_)"
  }
}

# ------------------------
# 3) Imbrication dans les groupes parents (idempotent)
# ------------------------
foreach ($g in $rows) {
  if (-not $g.ParentName) { continue }

  $parentId = $ParentCache[$g.ParentName]
  $childId  = $DynCache[$g.DisplayName]

  if (-not $parentId) { Write-ErrorX "Imbrication ignorée : parent '$($g.ParentName)' invalide ou introuvable."; continue }
  if (-not $childId)  { Write-ErrorX "Imbrication ignorée : groupe '$($g.DisplayName)' non créé/trouvé."; continue }

  Write-Info "Ajout membre: $($g.DisplayName) → $($g.ParentName)"
  Add-ChildToParent-Idempotent -ParentId $parentId -ChildId $childId
}

Write-Ok "Terminé."
