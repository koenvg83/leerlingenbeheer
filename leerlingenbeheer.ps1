﻿ param (
    [switch]$ResetPassword = $false
 )
$urlInfVKSO       = "http://webservice.informatsoftware.be/wsInfSoftVkso.asmx"
$urlInformat      = "http://webservice.informatsoftware.be/wsInformat.asmx?WSDL"
$login            = "XXX@YYY"
$paswoord         = "*****"
$instelnr         = "000000"
$schooljaar       = "2019-20"
$datum            = "01/09/2019"

$leerlingenpath   = "OU=Leerlingen,DC=XXX"
$homedirpath      = "\\XXX\leerlingen\"
$klashomedirpath  = "\\XXX\leerlingen\"
$gewistOU  		  = "OU=ArchiefLeerlingen,DC=XXX"

$logfile="E:\log\"+( get-date -format yyMMddhhmmss)+"_InformatToAD.log"

$Rights = [System.Security.AccessControl.FileSystemRights]::FullControl 
$Inherit=[System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit 
$Propogation=[System.Security.AccessControl.PropagationFlags]::None  
$Access=[System.Security.AccessControl.AccessControlType]::Allow

$groepen_ou="OU=AzureAD,DC=XXX,DC=local"
$groep_leerlingen="Leerlingen"

$totaalleerlingen=0
$leerlingen_verlaten=0
$leerlingen_nieuw=0
$leerlingen_update=0
$leerlingen_terug=0
$leerlingen_idem=0

Function getLeerlingAD($username) {
    Get-ADUser -LDAPFilter “(name=$username)” -Properties *
}

Function createUserKlasDirectory($user,$klas) {
    $userfullname=$user.surname+" "+$user.givenName
    $userfullname=$userfullname.replace(' ','')
    $userfullname=$userfullname.replace("'",'')
    $userfullname=$userfullname.replace("-",'')
    
    if($user.department) {
        $directorynaamoud=$klashomedirpath+$user.department+"\"+$userfullname
        if(Test-Path -Path $directorynaamoud ){
            LogWrite "     wissen link $directorynaamoud"
            cmd /c rmdir $directorynaamoud
        }
    }
    
    $directorynaamnieuw=$klashomedirpath+$klas+"\"+$userfullname
    $targetdirectory=$klashomedirpath+$user.samaccountname
    LogWrite "     aanmaken link $directorynaamnieuw"
    cmd /c mklink /d $directorynaamnieuw $targetdirectory
}

Function deleteUserKlasDirectory($user) {
	$userfullname=$user.surname+" "+$user.givenName
    $userfullname=$userfullname.replace(' ','')
    $userfullname=$userfullname.replace("'",'')
    $userfullname=$userfullname.replace("-",'')
    $directorynaamoud=$klashomedirpath+$user.department+"\"+$userfullname
    if(Test-Path -Path $directorynaamoud ){
            LogWrite "     wissen link $directorynaamoud"
            cmd /c rmdir $directorynaamoud
    }
}

Function updateLeerlingGroup($user,$klas) {
    Add-ADGroupMember -Identity $klas -Members $user
    Remove-ADGroupMember -Identity $user.department -Members $user -Confirm:$false 
}

Function updateLeerlingAD($user,$klas,$wachtwoord) {
    $klas_oud=$user.department
    createUserKlasDirectory $user $klas
    updateLeerlingGroup $user $klas
    LogWrite "     klas wijzigen $klas_oud -> $klas"
    $user.department=$klas
    $user.title=$null
    set-aduser -Instance $user
    #Vanaf 19-20 geen aparte OU meer per klas
    #$targetpath="OU="+$klas+","+$leerlingenpath
    #move-ADObject $user -TargetPath $targetpath
}


Function createLeerlingAD($id,$username,$firstname,$lastname,$klas,$wachtwoord) {
    #Vanaf 19-20: geen OU meer per klas
    #$targetpath="OU="+$klas+","+$leerlingenpath
    $targetpath=$leerlingenpath
    $newpwd = ConvertTo-SecureString -String $wachtwoord -AsPlainText –Force
    $homedir=$homedirpath+$username
    $name=$firstname+" "+$lastname
    $userprincipal=$username+"@XXX"
    
    New-ADUser -Path $targetpath -EmployeeID $id -UserPrincipalName $userprincipal -DisplayName $name -SamAccountName $username -GivenName $firstname -Department $klas -SurName $lastname -Name $username -AccountPassword $newpwd -ScriptPath "logonll.vbs" -HomeDirectory $homedir -HomeDrive "Z:" -PasswordNeverExpires $false -Enabled $true -ChangePasswordAtLogon $true
   
    #homedirectory aanmaken
    $AccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($username,$Rights,$Inherit,$Propogation,$Access)
    $ExistingUser =  getLeerlingAD($username)
    $checkhomefolder = Get-Acl $homedir -ErrorAction SilentlyContinue
    New-Item -Path $homedirpath -Name $username -ItemType Directory -ErrorAction SilentlyContinue
	$ACL = Get-Acl $homedir -ErrorAction SilentlyContinue
	$ACL.AddAccessRule($AccessRule)  | Out-Null
	Set-Acl $homedir $ACL
    
    createUserKlasDirectory $ExistingUser $klas
    createLeerlingGroup $ExistingUser $klas
    
}


Function createLeerlingGroup($user,$klas) {
    Add-ADGroupMember -Identity $klas -Members $user
    Add-ADGroupMember -Identity $groep_leerlingen -Members $user
}

Function alleLeerlingenSchoolverlater() {
    Get-ADUser -Filter * -SearchBase $leerlingenpath|Set-Aduser -Replace @{title="schoolverlater"}
}

Function archiveerAlleSchoolverlaters() {
    $users=Get-ADUser -Filter {Title -eq "schoolverlater"} -SearchBase $leerlingenpath -Properties *
    $teller=0
    foreach($user in $users) {
        if($user)
        {
            $username=$user.name
            $department=$user.department
            LogWrite "GEBRUIKER ARCHIVEREN: $username - $department"
            deleteUserKlasDirectory $user
            deleteLeerlingGroup $user
            move-ADObject $user -TargetPath $gewistOU
            $teller++
        }
    }
    return $teller
}


Function deleteLeerlingGroup($user) {
    Remove-ADGroupMember -Identity $user.department -Members $user -Confirm:$false
    Remove-ADGroupMember -Identity $groep_leerlingen -Members $user -Confirm:$false
}

Function leerlingenUitArchiefTerugplaatsen() {
    $users=Get-ADUser -Filter {Title -notlike '*'} -SearchBase $gewistOU -Properties *
    $teller=0
    foreach($user in $users) {
        if($user)
        {
            $username=$user.name
            $department=$user.department
            LogWrite "GEBRUIKER TERUGPLAATSEN: $username - $department"
            createUserKlasDirectory $user $department
            createLeerlingGroup $user $department
            move-ADObject $user -TargetPath $leerlingenpath
            $teller++
        }
    }
    return $teller
}

Function LogWrite
{
   Param ([string]$logstring)
   $stamp = (Get-Date).toString("yyyy/MM/dd HH:mm:ss")
   Add-content $logfile -value "$stamp - $logstring"
}



$proxy = New-WebServiceProxy -Uri $urlInfVKSO
$ds=$proxy.LeerlingenNaDatum($login,$paswoord,$instelnr,$datum,$schooljaar)

Import-Module Activedirectory

#$logfile=( get-date -format yyMMddhhmmss)+"_beheerleerlingen.log"
#"Naam;Voornaam;Klas;GebruikersnaamSmartschool;Log">$logfile

LogWrite "=== START IMPORT INFORMAT TO AD ==="
LogWrite "Logfile: $logfile"
LogWrite "Schooljaar: $schooljaar"

LogWrite "Alle leerlingen worden schoolverlater"
alleLeerlingenSchoolverlater

LogWrite "LEERLINGEN VERWERKEN UIT INFORMAT"
LogWrite "================================="

#Alle leerlingen overlopen in de ontvangen gegevens van Informat
foreach($row in $ds.Tables["Table1"]) {
    $username = $row.gebruikersnaamSmartschool
    $klas=$row.klascode
    #Wanneer er geen username/wachtwoord is ingevuld in Informat -> error voor leerlingen geven in error_informat.log  
    if(([DBNull]::Value).Equals($username)) { LogWrite "$row heeft geen gebruikersnaam in Informat"}
    else {
        $totaalleerlingen++
        $user=getLeerlingAD($username)
        #Leerling bestaat nog niet in AD -> aanmaken en de gegevens in newusers.csv schrijven
        if ( -not $user)
        { 
          LogWrite "GEBRUIKER NIEUW: $username - $klas"
          createLeerlingAD $row.p_persoon $username $row.voornaam $row.naam $row.klascode $row.wachtwoordSmartschool
          $leerlingen_nieuw++
        }
        #Leerling bestaat al in AD -> oude homedirlink wissen,klasgegevens aanpassen, naar juiste OU verplaatsen, nieuwe homedirlink aanmaken
        else
        { 
          if ($user.department -eq $row.klascode)
          {
            #LogWrite "GEBRUIKER IDEM: $username - $klas"
            $user.title=$null
            set-aduser -Instance $user
            $leerlingen_idem++
          }
          else
          {
            LogWrite "GEBRUIKER UPDATE: $username - $klas"
            updateLeerlingAD $user $row.klascode $row.wachtwoordSmartschool
            $leerlingen_update++
          }
          if ($ResetPassword)
          { LogWrite "     wachtwoord wijzigen"
            $newpwd = ConvertTo-SecureString -String $row.wachtwoordSmartschool -AsPlainText –Force
            Set-ADAccountPassword -Identity $user.SamAccountName -NewPassword $newpwd –Reset
            Set-ADUser $user -ChangePasswordAtLogon $true -PasswordNeverExpires $false
          }
        }
    }
}

#Alle leerlingen in de klassen overlopen, indien niet bestaande in informat -> verplaatsen naar leerlingenPrullenbak
LogWrite "ARCHIVEER ALLE SCHOOLVERLATERS"
LogWrite "=============================="
$leerlingen_verlaten=archiveerAlleSchoolverlaters

LogWrite "LEERLINGEN UIT ARCHIEF TERUGPLAATSEN"
LogWrite "===================================="
$leerlingen_terug=leerlingenUitArchiefTerugplaatsen

LogWrite "TOTALEN"
LogWrite "======="
Logwrite "VERWERKTE LEERLINGEN: $totaalleerlingen"
Logwrite "SCHOOLVERLATERS     : $leerlingen_verlaten"
Logwrite "NIEUWE LEERLINGEN   : $leerlingen_nieuw"
Logwrite "KLASWIJZIGING       : $leerlingen_update"
Logwrite "LEERLINGEN TERUG    : $leerlingen_terug"
Logwrite "LEERLINGEN IDEM     : $leerlingen_idem"

LogWrite "Mail sturen"

$body=[IO.File]::ReadAllText($logfile)
Send-MailMessage -To “xxx@XXX" -From “xxx@XXX" -SMTPServer smtp.XXX.be -Subject “[DC1] Import Informat - $totaalleerlingen leerlingen” -Body $body

LogWrite "=== STOP IMPORT INFORMAT TO AD ==="
