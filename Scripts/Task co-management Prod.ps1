# Création d'une tâche planifiée sur un poste Windows pour forcer l'étape de joindre un poste à Intune (cogestion) sans attendre le cycle normal de 24 heures
# La tâche est exécutée trois fois à 60 minutes d'intervalle pour s'assurer de la réussite du processus
# Samuel Langis, modifié le 10 juin 2025

# Nom de la tâche
$taskName = 'Evaluer-CoMgmtSettings'

# Heure d'exécution de base : dans 60 minutes
$baseTime = (Get-Date).AddMinutes(60)

# Code PowerShell exécuté par la tâche
$psCode = @'
$instance = Get-WmiObject -Namespace root\ccm\dcm -Query "Select * from SMS_DesiredConfiguration WHERE DisplayName = 'CoMgmtSettingsProd'"
if ($instance) {
    Invoke-CimMethod -Namespace root\ccm\dcm -ClassName SMS_DesiredConfiguration -MethodName TriggerEvaluation -Arguments @{
        Name = $instance.Name
        Version = $instance.Version
        PolicyType = $instance.PolicyType
    }
}
'@

# Encodage Base64 du script
$bytes = [System.Text.Encoding]::Unicode.GetBytes($psCode)
$encodedScript = [Convert]::ToBase64String($bytes)

# Action : exécuter PowerShell avec script encodé
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedScript"

# Déclencheurs à 60, 120 et 180 minutes
$triggers = @()
for ($i = 0; $i -lt 3; $i++) {
    $runAt = $baseTime.AddMinutes(60 * $i)
    $triggers += New-ScheduledTaskTrigger -Once -At $runAt
}

# Exécution en tant que SYSTEM
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

# Enregistrement de la tâche
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Principal $principal -Description "Lance manuellement l'évaluation du CoManagement pour accélérer l'activation après une TS et éviter le délai de 24 heures"
