set-executionpolicy bypass -force

# Si un compte local
$User = 'MCC-01\MCC'
$pw = ConvertTo-SecureString 'Patate12' -AsPlainText -Force
$myLocalAccountCredential = [pscredential]::new($User,$pw)

cd $(deliveryoptimization-cli mcc-get-scripts-path)

# Générer le certificat à signer à partir du MCC
# Generate a Certificate Signing Request (CSR)

.\generateCsr.ps1 `
    -mccRunTimeAccount $User `
    -mccLocalAccountCredential $myLocalAccountCredential `
    -algo RSA `
    -keySizeOrCurve 2048 `
    -csrName "MCC-01-LabChezLangis" `
    -subjectCommonName "MCC-01.chezlangis.ca" `
    -subjectCountry "CA" `
    -subjectState "Quebec" `
    -subjectOrg "Lab Chez Langis" `
    -sanDns "MCC-01.chezlangis.ca"

# Récupérer le certificat dans le dossier
# C:\mccwsl01\Certificates\certs

# Copier le certificate signé .crt dans le même dossier

# Importation du certificat signé
# Import signed TLS certificate

 .\importCert.ps1 `
   -mccRunTimeAccount $User `
   -mccLocalAccountCredential $myLocalAccountCredential `
   -certName "certificate.crt"

# HTTPS Test, mais je ne suis pas certain de quoi regarder
# curl.exe -v -o NUL "https://[mcc-connection]/[test-url]" --include -H "host:swda01-mscdn.manage.microsoft.com"
curl.exe -v -o NUL "https://MCC-01.chezlangis.ca/ee344de8-d177-4720-86c1-a076581766f9/070a8fd4-79a7-42c8-b7c8-9883253bb01a/c7b1b825-88b2-4e66-9b15-ff5fe0374bc6.appxbundle.bin" --include -H "host:swda01-mscdn.manage.microsoft.com"

# HTTP Test
curl.exe -v -o NUL "http://MCC-01.chezlangis.ca/ee344de8-d177-4720-86c1-a076581766f9/070a8fd4-79a7-42c8-b7c8-9883253bb01a/c7b1b825-88b2-4e66-9b15-ff5fe0374bc6.appxbundle.bin" --include -H "host:swda01-mscdn.manage.microsoft.com"