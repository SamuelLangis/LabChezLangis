<#
Fonction à inclure dans les scripts pour gérer une connexion MgGraph.
Validation des scopes, affichage de la connexion actuelle et option pour se connecter dans un autre tenant.

Prérequis :
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser

Samuel Langis - 15 décembre 2025
Révisé          - mars 2026
#>

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

        # Optionnel : forcer un tenant spécifique
        [string]$TenantId,

        # Nombre maximum de tentatives de connexion
        [int]$MaxAttempts = 3
    )

    # Paramètres de base pour Connect-MgGraph
    $connectParams = @{
        Scopes       = $RequiredScopes
        ContextScope = 'CurrentUser'
        NoWelcome    = $true
    }
    if ($TenantId) {
        $connectParams['TenantId'] = $TenantId
    }

    # --- Connexion initiale si aucune session active ---
    try { $ctx = Get-MgContext } catch { $ctx = $null }

    if (-not $ctx -or -not $ctx.Account) {
        Write-Host "`n🔐 Aucune session Microsoft Graph active." -ForegroundColor Yellow
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Write-Host "🔄 Connexion Microsoft Graph..." -ForegroundColor Yellow
        Connect-MgGraph @connectParams
    }

    # --- Boucle principale ---
    $attempt = 0

    do {
        if ($attempt -ge $MaxAttempts) {
            throw "❌ Nombre maximum de tentatives atteint ($MaxAttempts). Arrêt du script."
        }

        $ctx = Get-MgContext

        # Validation des scopes
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

        # Affichage du contexte courant
        try {
            $org = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/organization" -ErrorAction Stop
            $tenantName = $org.value[0].displayName
        } catch {
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

        # Changement de tenant
        Write-Host "`n🔄 Changement de tenant..." -ForegroundColor Yellow
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Connect-MgGraph @connectParams
        $attempt++

    } while ($true)

    # --- Résumé des scopes actifs ---
    # (filet de sécurité : ne devrait pas lever d'erreur si la boucle s'est terminée normalement)
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


# --- Exemple d'utilisation ---
Connect-OrSwitchTenant -RequiredScopes @(
    'DeviceManagementApps.ReadWrite.All',
    'Group.ReadWrite.All'
)