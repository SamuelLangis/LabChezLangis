<#
Fonction à inclure dans les scripts pour gérer une connexion MgGraph
Validation des scopes, affichage de la connexion actuelle et option pour se connecter dans un autre tenant.

Demande comme prérequis le module
Microsoft.Graph.Authentication
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser

Samuel Langis 15 décembre 2025
#>

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


# Connexion Microsoft Graph
Connect-OrSwitchTenant -RequiredScopes @(
	'DeviceManagementApps.ReadWrite.All',
	'Group.ReadWrite.All'
)
