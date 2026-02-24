<#

Script pour Installer un Microsoft Connected Cache
février 2026

## Étape #1
# Installation Windows Subsystem for Linux (WSL)

# Commande pour installer 
wsl.exe --install --no-distribution

# Commande pour vérifier que c'est bien installé
wsl --list --verbose


## Étape #2
# Install Hyper-V Management Tools (pourrait être supprimé après)

# on Windows Server
Install-WindowsFeature -Name Hyper-V -IncludeManagementTools

# on Windows 11
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell -All


## Étape #3
# Application Connected Cache Windows

#Download and install the Connected Cache Windows application
Add-AppxPackage "https://aka.ms/do-mcc-ent-windows-x64"

# Vérification de l'installation
Get-AppxPackage Microsoft.DeliveryOptimization

# Vérification que les scripts on bien été placées dans Program files\WindowsApps...
deliveryoptimization-cli mcc-get-scripts-path

# redémarrer nécessaire après WSL et Tools Hyper-V

#>

set-executionpolicy bypass -force

## Étape #4 Détails du compte de service utilisé

# Si un compte local
# $User doit être avec un format "LocalMachineName\Username" et le mot de passe ne doit pas contenir de "$".

$User = 'MCC-01\MCC'
$pw = ConvertTo-SecureString 'Patate' -AsPlainText -Force
$myLocalAccountCredential = [pscredential]::new($User,$pw)

# Si un compte GMSA

# $User doit être avec un format "Domain\Username$"
# $User = "ChezLangis\MCC$"


<#
## Étape #5
## Désinstallation de l'installation précédente Public Preview, surtout pour libérer de l'espace disque

# Si un compte local
cd C:\mccwsl01
.\uninstallmcconwsl.ps1 -mccLocalAccountCredential $myLocalAccountCredential

# Si un compte GMSA
cd C:\mccwsl01
.\uninstallmcconwsl.ps1 -RunTimeAccountName $User

#>

## Étape #6
# Utiliser "Cache Node Deployment Command" de la ressource Azure
# Exemple

Push-Location (deliveryoptimization-cli mcc-get-scripts-path); 
./deploymcconwsl.ps1 -installationFolder c:\mccwsl01 -customerid 4067ef48-c99d-4a93-99b0-cd227fced3c2 -cachenodeid 6c4097d3-d1d4-4ac0-a755-f509f10cc866 -customerkey 5c331c34-987e-4918-9e0f-bacbd1ab1811 -registrationkey 561b8cb9-c47e-4884-a69e-9c368d17cf7c -cacheDrives "/var/mcc,100" -mccRunTimeAccount $User -mccLocalAccountCredential $myLocalAccountCredential



<#
## Autres commandes

## To verify that the Connected Cache container on the host machine is running and reachable. Doit donner "StatusCode 200"
wget http://localhost/filestreamingservice/files/7bc846e0-af9c-49be-a03d-bb04428c9bb5/Microsoft.png?cacheHostOrigin=dl.delivery.mp.microsoft.com

## To verify that Windows client devices in your network can reach the Connected Cache node
http://[HostMachine-IP-address]/filestreamingservice/files/7bc846e0-af9c-49be-a03d-bb04428c9bb5/Microsoft.png?cacheHostOrigin=dl.delivery.mp.microsoft.com


## Désinstallation s'il faut faire une réinstallation

# Si un compte local
cd $(deliveryoptimization-cli mcc-get-scripts-path)
.\uninstallmcconwsl.ps1 -mccLocalAccountCredential $myLocalAccountCredential

# Si un compte GMSA
cd $(deliveryoptimization-cli mcc-get-scripts-path)
.\uninstallmcconwsl.ps1 -RunTimeAccountName $User

#>