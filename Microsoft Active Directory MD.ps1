#
# Active Directory MD.ps1 - IDM System PowerShell Script for Active Directory Multi-Domain Services.
#
# Any IDM System PowerShell Script is dot-sourced in a separate PowerShell context, after
# dot-sourcing the IDM Generic PowerShell Script '../Generic.ps1'.
#


####################
# BEGIN OF ADSI.ps1
####################

#
# ADSI.ps1 - Active Directory Services Interface PowerShell Script.
#
# ADSI implementation of PowerShell Active Directory Module functionality.
#


#
# Helper functions
#

$TerminalServicesAttributes = @(
    # int32
    'AllowLogon', 'BrokenConnectionAction', 'ConnectClientDrivesAtLogon', 'ConnectClientPrintersAtLogon', 'DefaultToMainPrinter',
    'EnableRemoteControl', 'MaxConnectionTime', 'MaxDisconnectionTime', 'MaxIdleTime', 'ReconnectionAction',

    # string
    'TerminalServicesHomeDirectory', 'TerminalServicesHomeDrive', 'TerminalServicesInitialProgram', 'TerminalServicesProfilePath',
    'TerminalServicesWorkDirectory'
)

$PropertyNamesMap = @{
    CannotChangePassword = 'nTSecurityDescriptor'
    ChangePasswordAtLogon = 'pwdLastSet'
    Enabled = 'userAccountControl'
    GroupCategory = 'groupType'
    GroupScope = 'groupType'
    PasswordExpirationDate = 'adsPath'
    PasswordNeverExpires = 'userAccountControl'
    PasswordNotRequired = 'userAccountControl'
    Path = 'distinguishedName'
    ProtectObjectFromDeletion = 'nTSecurityDescriptor'
}

foreach ($e in $Global:TerminalServicesAttributes) { $Global:PropertyNamesMap.Add($e, 'adsPath') }

function HashObjectToId {
    param(
        [Parameter(Mandatory)] [object] $object
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $hashbytes = $sha256.ComputeHash( [System.Text.Encoding]::UTF8.GetBytes( ($object | ConvertTo-Json) ) )
    return [BitConverter]::ToString($hashBytes) -replace "-", ""
}

function ConvertFrom-ADLargeInteger {
    param (
        [Parameter(Mandatory)] [object] $li
    )

    $high_part = $li.GetType().InvokeMember('HighPart', [System.Reflection.BindingFlags]::GetProperty, $null, $li, $null)
    $low_part  = $li.GetType().InvokeMember('LowPart',  [System.Reflection.BindingFlags]::GetProperty, $null, $li, $null)

    $bytes = [System.BitConverter]::GetBytes($high_part)
    $tmp   = [System.Byte[]]@(0,0,0,0,0,0,0,0)
    [System.Array]::Copy($bytes, 0, $tmp, 4, 4)
    $high_part = [System.BitConverter]::ToInt64($tmp, 0)

    $bytes = [System.BitConverter]::GetBytes($low_part)
    $low_part = [System.BitConverter]::ToUInt32($bytes, 0)
 
    return $low_part + $high_part
}


function ConvertTo-ADLargeInteger {
    param (
        [Parameter(Mandatory)] [Int64] $Number
    )

    $byte_array = [System.BitConverter]::GetBytes($Number)
    $high_part  = [System.BitConverter]::ToInt32($byte_array, 4)
    $low_part   = [System.BitConverter]::ToInt32($byte_array, 0)

    $li = New-Object -ComObject LargeInteger

    [void]$li.GetType().InvokeMember('HighPart', [System.Reflection.BindingFlags]::SetProperty, $null, $li, $high_part)
    [void]$li.GetType().InvokeMember('LowPart',  [System.Reflection.BindingFlags]::SetProperty, $null, $li, $low_part)

    return $li
}


function Escape-CN {
    param (
        [Parameter(Mandatory)] [string] $CN
    )

    # https://social.technet.microsoft.com/wiki/contents/articles/5312.active-directory-characters-to-escape.aspx
    return $CN -replace '([,\\#+<>;"=])|^( )|( )$', '\$1$2$3'
}


function Get-GuidFromExtendedDN {
    param (
        [string] $ExtendedDN
    )

    $ExtendedDN.Substring(6, 36)    # Extract guid_value from <GUID=guid_value>;<SID=sid_value>;dn
}


function Get-DnFromExtendedDN {
    param (
        [string] $ExtendedDN
    )

    $ExtendedDN -replace '^<.*>;'    # Extract dn from <GUID=guid_value>;<SID=sid_value>;dn
}


function Get-DomainFromDN {
    param (
        [string] $DN
    )

    ($DN.Split(',') | Where-Object { $_ -match '^DC=' } | ForEach-Object { $_.Substring(3) }) -join '.'
}


function Get-IdentityType {
    param (
        [string] $Identity
    )

    if ($Identity.Length -eq 36 -and $Identity.Substring(8, 1) -eq '-' -and $Identity.Substring(13, 1) -eq '-' -and $Identity.Substring(18, 1) -eq '-' -and $Identity.Substring(23, 1) -eq '-') {
        'objectGUID'
    }
    elseif ($Identity.Length -gt 4 -and $Identity.Substring(0, 4) -eq 'S-1-') {
        'objectSid'
    }
    elseif ($Identity.Length -gt 3 -and $Identity.Substring(0, 3) -eq 'CN=') {
        'distinguishedName'
    }
    elseif ($Identity.Length -gt 3 -and $Identity.Substring(0, 3) -eq 'OU=') {
        'path'
    }
    else {
        'other'
    }
}


function Make-UniversalIdentity {
    param (
        [string] $Identity
    )

    $identity_type = Get-IdentityType $Identity

    if ($identity_type -eq 'objectGUID') {
        "<GUID=$($Identity)>"
    }
    elseif ($identity_type -eq 'objectSid') {
        "<SID=$($Identity)>"
    }
    else {
        # distinguishedName / path / other
        $Identity
    }
}


function Make-LDAPPath {
    param (
        [switch] $GC,
        [string] $Server,
        [string] $Identity
    )

    $path = if ($GC) { 'GC:/' } else { 'LDAP:/' }

    if ($Server) {
        $path += '/' + $Server
    }

    $path + '/' + (Make-UniversalIdentity $Identity).Replace('/','\/')
}


if ($true) {
    # AD groupType bit definitions
    # -> https://docs.microsoft.com/en-us/windows/win32/adschema/a-grouptype

    New-Variable ADS_GROUP_SYSTEM_CREATED -ErrorAction Ignore -Option Constant -Value 0x00000001
    New-Variable ADS_GROUP_GLOBAL         -ErrorAction Ignore -Option Constant -Value 0x00000002
    New-Variable ADS_GROUP_DOMAINLOCAL    -ErrorAction Ignore -Option Constant -Value 0x00000004
    New-Variable ADS_GROUP_UNIVERSAL      -ErrorAction Ignore -Option Constant -Value 0x00000008
    New-Variable ADS_GROUP_APP_BASIC      -ErrorAction Ignore -Option Constant -Value 0x00000010
    New-Variable ADS_GROUP_APP_QUERY      -ErrorAction Ignore -Option Constant -Value 0x00000020
    New-Variable ADS_GROUP_SECURITY       -ErrorAction Ignore -Option Constant -Value 0x80000000


    # AD userAccountControl bit definitions
    # -> https://docs.microsoft.com/en-us/windows/win32/adschema/a-useraccountcontrol

    New-Variable ADS_UF_SCRIPT                                 -ErrorAction Ignore -Option Constant -Value 0x00000001
    New-Variable ADS_UF_ACCOUNTDISABLE                         -ErrorAction Ignore -Option Constant -Value 0x00000002
    New-Variable ADS_UF_HOMEDIR_REQUIRED                       -ErrorAction Ignore -Option Constant -Value 0x00000008
    New-Variable ADS_UF_LOCKOUT                                -ErrorAction Ignore -Option Constant -Value 0x00000010
    New-Variable ADS_UF_PASSWD_NOTREQD                         -ErrorAction Ignore -Option Constant -Value 0x00000020
    New-Variable ADS_UF_PASSWD_CANT_CHANGE                     -ErrorAction Ignore -Option Constant -Value 0x00000040
    New-Variable ADS_UF_ENCRYPTED_TEXT_PASSWORD_ALLOWED        -ErrorAction Ignore -Option Constant -Value 0x00000080
    New-Variable ADS_UF_TEMP_DUPLICATE_ACCOUNT                 -ErrorAction Ignore -Option Constant -Value 0x00000100
    New-Variable ADS_UF_NORMAL_ACCOUNT                         -ErrorAction Ignore -Option Constant -Value 0x00000200
    New-Variable ADS_UF_INTERDOMAIN_TRUST_ACCOUNT              -ErrorAction Ignore -Option Constant -Value 0x00000800
    New-Variable ADS_UF_WORKSTATION_TRUST_ACCOUNT              -ErrorAction Ignore -Option Constant -Value 0x00001000
    New-Variable ADS_UF_SERVER_TRUST_ACCOUNT                   -ErrorAction Ignore -Option Constant -Value 0x00002000
    New-Variable ADS_UF_NOT_USED_1                             -ErrorAction Ignore -Option Constant -Value 0x00004000
    New-Variable ADS_UF_NOT_USED_2                             -ErrorAction Ignore -Option Constant -Value 0x00008000
    New-Variable ADS_UF_DONT_EXPIRE_PASSWD                     -ErrorAction Ignore -Option Constant -Value 0x00010000
    New-Variable ADS_UF_MNS_LOGON_ACCOUNT                      -ErrorAction Ignore -Option Constant -Value 0x00020000   
    New-Variable ADS_UF_SMARTCARD_REQUIRED                     -ErrorAction Ignore -Option Constant -Value 0x00040000   
    New-Variable ADS_UF_TRUSTED_FOR_DELEGATION                 -ErrorAction Ignore -Option Constant -Value 0x00080000   
    New-Variable ADS_UF_NOT_DELEGATED                          -ErrorAction Ignore -Option Constant -Value 0x00100000   
    New-Variable ADS_UF_USE_DES_KEY_ONLY                       -ErrorAction Ignore -Option Constant -Value 0x00200000   
    New-Variable ADS_UF_DONT_REQUIRE_PREAUTH                   -ErrorAction Ignore -Option Constant -Value 0x00400000   
    New-Variable ADS_UF_PASSWORD_EXPIRED                       -ErrorAction Ignore -Option Constant -Value 0x00800000   
    New-Variable ADS_UF_TRUSTED_TO_AUTHENTICATE_FOR_DELEGATION -ErrorAction Ignore -Option Constant -Value 0x01000000   
}


function ConvertTo-GroupType {
    param(
        [int32] $OldValue = 0,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $GroupCategory,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $GroupScope
    )

    $c = switch ($GroupCategory) {
             ''             { if ($OldValue -eq 0) { $ADS_GROUP_SECURITY } else { $OldValue -band $ADS_GROUP_SECURITY }; break }
             'Security'     { $ADS_GROUP_SECURITY;    break }
             'Distribution' { 0;                      break }
             default        { throw 'GroupCategory out of range' }
         }

    $s = switch ($GroupScope) {
             ''             { if ($OldValue -eq 0) { $ADS_GROUP_GLOBAL } else { $OldValue -band ($ADS_GROUP_GLOBAL -bor $ADS_GROUP_DOMAINLOCAL -bor $ADS_GROUP_UNIVERSAL -bor $ADS_GROUP_APP_BASIC -bor $ADS_GROUP_APP_QUERY) }; break }
             'Global'       { $ADS_GROUP_GLOBAL;      break }
             'DomainLocal'  { $ADS_GROUP_DOMAINLOCAL; break }
             'Universal'    { $ADS_GROUP_UNIVERSAL;   break }
             'APP_BASIC'    { $ADS_GROUP_APP_BASIC;   break }
             'APP_QUERY'    { $ADS_GROUP_APP_QUERY;   break }
             default        { throw 'GroupScope out of range' }
         }

    return $c -bor $s
}


function Get-DirectoryServicesDirectoryEntry {
    param (
        [PSCredential] $Credential,
        [String] $Path
    )

    if ($Credential) {
        New-Object System.DirectoryServices.DirectoryEntry $Path, ($Credential.GetNetworkCredential().UserName), ($Credential.GetNetworkCredential().Password)
    }
    else {
        New-Object System.DirectoryServices.DirectoryEntry $Path
    }
}


function Get-ActiveDirectoryDirectoryContext {
    param (
        [PSCredential] $Credential,
        [System.DirectoryServices.ActiveDirectory.DirectoryContextType] $ContextType,
        [String] $Name
    )

    if ($Credential) {
        New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext $ContextType, $Name, ($Credential.GetNetworkCredential().UserName), ($Credential.GetNetworkCredential().Password)
    }
    else {
        New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext $ContextType, $Name
    }
}


function Get-ADRootDSE-ADSI {
    param (
        [PSCredential] $Credential,
        [String] $Server
    )

    Get-DirectoryServicesDirectoryEntry $Credential (Make-LDAPPath $Server 'RootDSE')
}


function Get-ADForest-ADSI {
    param (
        [PSCredential] $Credential,
        [String] $Identity
    )

    if ($Identity) {
        $directory_context = Get-ActiveDirectoryDirectoryContext $Credential ([System.DirectoryServices.ActiveDirectory.DirectoryContextType]::Forest) $Identity
        [System.DirectoryServices.ActiveDirectory.Forest]::GetForest($directory_context)
    }
    else {
        [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest()
    }
}


function Get-ADRidMaster {
    param (
        [PSCredential] $Credential,
        [String] $Server
    )

    $domain_info = $null

    try {
        $directory_context = Get-ActiveDirectoryDirectoryContext $Credential ([System.DirectoryServices.ActiveDirectory.DirectoryContextType]::Domain) $Server
        $domain_info = [System.DirectoryServices.ActiveDirectory.Domain]::GetDomain($directory_context)
    }
    catch [System.Management.Automation.MethodInvocationException] {
        #Write-Host $Error[0].Exception.GetType().FullName
    }

    if ($domain_info -eq $null) {
        $directory_context = Get-ActiveDirectoryDirectoryContext $Credential ([System.DirectoryServices.ActiveDirectory.DirectoryContextType]::DirectoryServer) $Server
        $domain_info = [System.DirectoryServices.ActiveDirectory.Domain]::GetDomain($directory_context)
    }

    $domain_info.RidRoleOwner.Name
}

function Get-ADRidMasterFromGuid {
    param (
    [string]$GUID,
	[PSCredential] $Credential
)
    $guidParsed = [guid]::Parse($GUID)
    $guidBytes = $guidParsed.ToByteArray()
    $adsiGuid = ""
    foreach ($byte in $guidBytes) { $adsiGuid += "\$('{0:X2}' -f $byte)" }

    $forest = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest()
    $domains = $forest.Domains

    # Iterate through each domain in the forest and search for the user
    foreach ($domain in $domains) {
        $ldapPath = "LDAP://$($domain.Name)"
        $entry = Get-DirectoryServicesDirectoryEntry -Credential $Credential -Path $ldapPath
        $searcher = New-Object DirectoryServices.DirectorySearcher($entry)
        $searcher.Filter = "(objectGUID=$adsiGUID)"
        $searcher.SearchScope = "Subtree"

        $result = $searcher.FindOne()

        if ($result) {
            Get-ADRidMaster -Credential $credential -Server $domain.Name
            break
        }
    }

    if (-not $result) {
        Log error "Could not find RIDMaster for user [$($userGUID)]"
    }
}


function Get-CannotChangePassword {
    # https://docs.microsoft.com/en-us/windows/win32/adsi/reading-user-cannot-change-password-ldap-provider
    param(
        [byte[]] $nTSecurityDescriptor
    )

    $change_password_guid = [guid]'{AB721A53-1E2F-11D0-9819-00AA0040529B}'

    $sid_everyone = [System.Security.Principal.SecurityIdentifier]'S-1-1-0'
    $sid_nt_authority_self = [System.Security.Principal.SecurityIdentifier]'S-1-5-10'

    $has_deny_everyone = $false
    $has_deny_self = $false

    $acl = (New-Object System.Security.AccessControl.RawSecurityDescriptor($nTSecurityDescriptor, 0)).DiscretionaryAcl

    foreach ($ace in $acl) {
        if ($ace.ObjectAceType -eq $change_password_guid) {
            if (!$has_deny_everyone -and $ace.SecurityIdentifier.Value -eq $sid_everyone) {
                if ($ace.AceType -eq 'AccessAllowedObject') { return $false }
                if ($ace.AceType -eq 'AccessDeniedObject') {
                    if ($has_deny_self) { return $true }
                    $has_deny_everyone = $true
                }
            }
            elseif (!$has_deny_self -and $ace.SecurityIdentifier.Value -eq $sid_nt_authority_self) {
                if ($ace.AceType -eq 'AccessAllowedObject') { return $false }
                if ($ace.AceType -eq 'AccessDeniedObject') {
                    if ($has_deny_everyone) { return $true }
                    $has_deny_self = $true
                }
            }
        }
    }

    return $false
}


function Set-CannotChangePassword {
    # https://docs.microsoft.com/en-us/dotnet/api/system.directoryservices.activedirectorysecurity?view=net-5.0
    param(
        [System.DirectoryServices.ActiveDirectorySecurity] $ADSecurity,
        [bool] $State
    )

    $change_password_guid = [guid]'{AB721A53-1E2F-11D0-9819-00AA0040529B}'

    $sid_everyone = [System.Security.Principal.SecurityIdentifier]'S-1-1-0'
    $sid_nt_authority_self = [System.Security.Principal.SecurityIdentifier]'S-1-5-10'
    $accessMask = [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight

    $del_access_control_type = if ($State) { 'Allow' } else { 'Deny'  }
    $add_access_control_type = if ($State) { 'Deny'  } else { 'Allow' }

    $ADSecurity.RemoveAccessRule( (New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid_everyone,          $accessMask, $del_access_control_type, $change_password_guid))) >$null
    $ADSecurity.RemoveAccessRule( (New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid_nt_authority_self, $accessMask, $del_access_control_type, $change_password_guid))) >$null

    $ADSecurity.AddAccessRule(    (New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid_everyone,          $accessMask, $add_access_control_type, $change_password_guid))) >$null

    if ($add_access_control_type -ne 'Allow') {
        # This is how Active Directory Users and Computer works...
        $ADSecurity.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid_nt_authority_self, $accessMask, $add_access_control_type, $change_password_guid))) >$null
    }
}

function Get-ProtectObjectFromDeletion {
    # https://docs.microsoft.com/en-us/windows/win32/adsi/reading-user-cannot-change-password-ldap-provider
    param(
        [byte[]] $nTSecurityDescriptor
    )

    $acl = (New-Object System.Security.AccessControl.RawSecurityDescriptor($nTSecurityDescriptor, 0)).DiscretionaryAcl

    foreach ($ace in $acl) {
        if ($ace.SecurityIdentifier -eq [System.Security.Principal.SecurityIdentifier]'S-1-1-0' -and $ace.AceType -eq [System.Security.AccessControl.AccessControlType]::Deny) {
            return $true
            break
        }
    }

    return $false
}

function Set-ProtectObjectFromDeletion {
    # https://docs.microsoft.com/en-us/dotnet/api/system.directoryservices.activedirectorysecurity?view=net-5.0
    param(
        [System.DirectoryServices.ActiveDirectorySecurity] $ADSecurity,
        [bool] $State
    )

    $sidEveryone = New-Object System.Security.Principal.SecurityIdentifier("S-1-1-0")  # SID for Everyone
    $ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $sidEveryone,
        65600,
        [System.Security.AccessControl.AccessControlType]::Deny,
        [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None
    )
    if ($State) {
        # Add the access rule
        $ADSecurity.AddAccessRule($ace)
    } else {
        # Remove the access rule
        $ADSecurity.RemoveAccessRule($ace)
    }
}

function Convert-ADPropertyCollection {
    param(
        [PSCredential] $Credential,
        [System.DirectoryServices.DirectoryEntry] $DirectoryEntry,
        [Parameter(Mandatory)] [ValidateNotNullorEmpty()] [string[]] $Properties,
        [string[]] $SkipProperties,
        [Parameter(ValueFromPipeline)] [AllowEmptyCollection()] $PropertyCollection
    )

    begin {
        $time_properties = @('accountexpires','badpasswordtime','lastlogoff','lastlogon','pwdlastset','usnchanged','usncreated')
        $group_scope_mask = ($ADS_GROUP_GLOBAL -bor $ADS_GROUP_DOMAINLOCAL -bor $ADS_GROUP_UNIVERSAL -bor $ADS_GROUP_APP_BASIC -bor $ADS_GROUP_APP_QUERY)
    }

    process {
        #
        # $PropertyCollection can be:
        #
        # - [System.DirectoryServices.ResultPropertyCollection] when called by Get-ADObject-ADSI(), or
        # - [System.DirectoryServices.PropertyCollection]       when called by PassThru of New-ADObject-ADSI() and Set-ADObject-ADSI()/Set-ADGroupMember-ADSI()
        #

        if (-not $PropertyCollection) { return }

        if ($Properties -eq '*') { $Properties = $PropertyCollection.PropertyNames }

        $object = [ordered]@{}

        foreach ($p in $Properties) {
            if ($p -eq 'AccountPassword' -or ($SkipProperties -and $SkipProperties.Contains($p))) { continue }

            $p_mapped = if ($Global:PropertyNamesMap[$p]) { $Global:PropertyNamesMap[$p] } else { $p }
            $value_collection = $PropertyCollection[$p_mapped]

            if ($time_properties.Contains($p.ToLower())) {
                $li = if ($value_collection[0] -is [System.__ComObject]) {
                          ConvertFrom-ADLargeInteger $value_collection[0]
                      }
                      else {
                          $value_collection[0]
                      }

                # https://social.technet.microsoft.com/wiki/contents/articles/31135.active-directory-large-integer-attributes.aspx
                $value = if ($li -le 0 -or $li -gt [DateTime]::MaxValue.Ticks) {
                            ''    # '(never)' in Active Directory Users and Computers
                         }
                         else {
                            [DateTime]::FromFileTimeUtc($li)
                         }
            }
			elseif ($p -eq 'assistant') {
                # $value_collection[0] is an ExtendedDN
                $value = Get-DnFromExtendedDN $value_collection[0]
            }
            elseif ($p -eq 'CannotChangePassword') {
                # $value_collection[0] is 'nTSecurityDescriptor'
                #
                # From https://flylib.com/books/en/1.434.1/com_interop_data_types.html :
                # - DirectoryEntry marshals security descriptors as a System.__ComObject data type
                # - DirectorySearcher marshals security descriptors in binary format as a byte array

                $byte_array = if ($value_collection[0] -is [System.__ComObject]) {
                    # $DirectoryEntry.ObjectSecurity accesses 'nTSecurityDescriptor' property
                    $DirectoryEntry.ObjectSecurity.GetSecurityDescriptorBinaryForm()
                }
                else {
                    $value_collection[0]
                }

                $value = Get-CannotChangePassword $byte_array
            }
			elseif ($p -eq 'canonicalName') {
                if($value_collection.length -lt 1 -or $null -eq $value_collection) {
                    # $PropertyCollection is a [System.DirectoryServices.PropertyCollection]: Get associated [System.DirectoryServices.ResultPropertyCollection]
                    $dirent = Get-DirectoryServicesDirectoryEntry $Credential $DirectoryEntry.path
                    $searcher = New-Object System.DirectoryServices.DirectorySearcher $dirent, '(objectClass=*)', $p, 'Base'

                    # https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-adts/57056773-932c-4e55-9491-e13f49ba580c?redirectedfrom=MSDN
                    $searcher.ExtendedDN = [System.DirectoryServices.ExtendedDN]::Standard

                    $pc = $searcher.FindOne().Properties
                    $value = $pc[$p]
                } else  { $value = $value_collection[0] }

            }
            elseif ($p -eq 'ChangePasswordAtLogon') {
                # $value_collection[0] is 'pwdLastSet'
                $li = if ($value_collection[0] -is [System.__ComObject]) {
                          ConvertFrom-ADLargeInteger $value_collection[0]
                      }
                      else {
                          $value_collection[0]
                      }

                $value = ($li -eq 0 -or $li -gt [DateTime]::MaxValue.Ticks)
            }
            elseif ($p -eq 'distinguishedName') {
                # $value_collection[0] is an ExtendedDN
                $value = Get-DnFromExtendedDN $value_collection[0]
            }
            elseif ($p -eq 'Enabled') {
                # $value_collection[0] is 'userAccountControl'
                $value = (($value_collection[0] -band $ADS_UF_ACCOUNTDISABLE) -ne $ADS_UF_ACCOUNTDISABLE)
            }
            elseif ($p -eq 'GroupCategory') {
                # $value_collection[0] is 'groupType'
                $value = if (($value_collection[0] -band $ADS_GROUP_SECURITY) -eq $ADS_GROUP_SECURITY) { 'Security' } else { 'Distribution' }
            }
            elseif ($p -eq 'GroupScope') {
                # $value_collection[0] is 'groupType'
                $value = switch ($value_collection[0] -band $group_scope_mask) {
                            $ADS_GROUP_GLOBAL      { 'Global';      break }
                            $ADS_GROUP_DOMAINLOCAL { 'DomainLocal'; break }
                            $ADS_GROUP_UNIVERSAL   { 'Universal';   break }
                            $ADS_GROUP_APP_BASIC   { 'APP_BASIC';   break }
                            $ADS_GROUP_APP_QUERY   { 'APP_QUERY';   break }
                            default                { 'Other';       break }
                         }
            }
            elseif ($p -eq 'managedBy') {
                # $value_collection[0] is an ExtendedDN
                $value = if ($value_collection[0]) { Get-GuidFromExtendedDN $value_collection[0] } else { $null }
            }
            elseif ($p -eq 'manager') {
                # $value_collection[0] is an ExtendedDN
                $value = Get-DnFromExtendedDN $value_collection[0]
            }
            elseif ($p -eq 'ProtectObjectFromDeletion') {
                # $value_collection[0] is 'nTSecurityDescriptor'
                #
                # From https://flylib.com/books/en/1.434.1/com_interop_data_types.html :
                # - DirectoryEntry marshals security descriptors as a System.__ComObject data type
                # - DirectorySearcher marshals security descriptors in binary format as a byte array

                $byte_array = if ($value_collection[0] -is [System.__ComObject]) {
                    # $DirectoryEntry.ObjectSecurity accesses 'nTSecurityDescriptor' property
                    $DirectoryEntry.ObjectSecurity.GetSecurityDescriptorBinaryForm()
                }
                else {
                    $value_collection[0]
                }

                $value = Get-ProtectObjectFromDeletion $byte_array
            }
            elseif ($p -eq 'member') {
                if ($PropertyCollection -isnot [System.DirectoryServices.PropertyCollection]) {
                    # $PropertyCollection is a [System.DirectoryServices.ResultPropertyCollection]: Use as-is
                    $dirent = $null
                    $searcher = $null
                    $pc = $PropertyCollection
                }
                else {
                    # $PropertyCollection is a [System.DirectoryServices.PropertyCollection]: Get associated [System.DirectoryServices.ResultPropertyCollection]
                    $dirent = Get-DirectoryServicesDirectoryEntry $Credential $DirectoryEntry.path
                    $searcher = New-Object System.DirectoryServices.DirectorySearcher $dirent, '(objectClass=*)', $p, 'Base'

                    # https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-adts/57056773-932c-4e55-9491-e13f49ba580c?redirectedfrom=MSDN
                    $searcher.ExtendedDN = [System.DirectoryServices.ExtendedDN]::Standard

                    $pc = $searcher.FindOne().Properties
                    $value_collection = $pc[$p]
                }

                # https://docs.microsoft.com/en-us/previous-versions/windows/desktop/ldap/searching-using-range-retrieval
                # Range-retrieval: exhaustively read attribute 'member;range=<start>-<end>'

                $value = New-Object System.Collections.ArrayList
                $member_range_property = $null
                $start = 0

                while ($true) {
                    foreach ($m in $value_collection) {
                        # Remove empty entries
                        if ($m) { [void]$value.Add((Get-GuidFromExtendedDN $m)) }
                    }

                    if ($member_range_property) {
                        if ($member_range_property -match '^member;range=[0-9]*-\*$') {
                            # End-of-range: Exhausted
                            break
                        }

                        if (!$dirent) {
                            $dirent = Get-DirectoryServicesDirectoryEntry $Credential $PropertyCollection['adsPath'][0]
                        }

                        $inc   =  $value_collection.count
                        $start += $inc
                        $end   =  $start + $inc - 1

                        $member_range_property = "member;range=$($start)-$($end)"

                        if ($searcher) {
                            $searcher.Dispose()
                        }

                        $searcher = New-Object System.DirectoryServices.DirectorySearcher $dirent, '(objectClass=*)', $member_range_property, 'Base'

                        # https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-adts/57056773-932c-4e55-9491-e13f49ba580c?redirectedfrom=MSDN
                        $searcher.ExtendedDN = [System.DirectoryServices.ExtendedDN]::Standard

                        $pc = $searcher.FindOne().Properties
                    }

                    $member_range_property = $pc.PropertyNames.Where({$_ -match '^member;range='})

                    if (!$member_range_property) {
                        # Member not present
                        break
                    }

                    $value_collection = $pc[$member_range_property][0]
                }

                if ($searcher) {
                    $searcher.Dispose()
                }
            }
            elseif ($p -eq 'nTSecurityDescriptor') {
                # Convert to SDDL
                $byte_array = if ($value_collection[0] -is [System.__ComObject]) {
                    # $DirectoryEntry.ObjectSecurity accesses 'nTSecurityDescriptor' property
                    $DirectoryEntry.ObjectSecurity.GetSecurityDescriptorBinaryForm()
                }
                else {
                    $value_collection[0]
                }

                $value = (New-Object System.Security.AccessControl.RawSecurityDescriptor($byte_array, 0)).GetSddlForm([System.Security.AccessControl.AccessControlSections]::All)
            }
            elseif ($p -eq 'objectClass') {
                # Get most specific value
                $value = $value_collection[$value_collection.Count - 1]
            }
            elseif ($p -eq 'objectGUID') {
                # Convert to string
                $value = (New-Object System.Guid(, $value_collection[0])).ToString()
            }
            elseif ($p -eq 'objectSID') {
                # Convert to string
                $value = try { (New-Object System.Security.Principal.SecurityIdentifier($value_collection[0], 0)).Value } catch { "" }
            }
            elseif ($p -eq 'PasswordExpirationDate') {
                # $value_collection[0] is 'adsPath'
                $dirent = Get-DirectoryServicesDirectoryEntry $Credential $value_collection[0]

                try {
                    $value = $dirent.InvokeGet($p)
                }
                catch {
                    $value = $null
                }
            }
            elseif ($p -eq 'PasswordNeverExpires') {
                # $value_collection[0] is 'userAccountControl'
                $value = (($value_collection[0] -band $ADS_UF_DONT_EXPIRE_PASSWD) -ne 0)
            }
            elseif ($p -eq 'PasswordNotRequired') {
                # $value_collection[0] is 'userAccountControl'
                $value = (($value_collection[0] -band $ADS_UF_PASSWD_NOTREQD) -ne 0)
            }
            elseif ($p -eq 'Path') {
                # $value_collection[0] is 'distinguishedName'
                $value = $value_collection[0].Substring($value_collection[0].Replace('\\','  ').Replace('\,','  ').IndexOf(',') + 1)
            }
            elseif ($p -eq 'sidHistory') {
                # Convert to string[]
                $value = @()

                foreach ($bin_sid in $value_collection) {
                    $value += (New-Object System.Security.Principal.SecurityIdentifier($bin_sid, 0)).Value
                }
            }
            elseif ($p -eq 'thumbnailPhoto') {
                try {
                    $value = [System.Convert]::ToBase64String($value_collection[0])
                }
                catch {
                    $value = $null
                }
            }
            elseif ($Global:TerminalServicesAttributes.Contains($p)) {
                # $value_collection[0] is 'adsPath'
                $dirent = Get-DirectoryServicesDirectoryEntry $Credential $value_collection[0]

                try {
                    $value = $dirent.InvokeGet($p)
                }
                catch {
                    # No attribute 'userParameters'
                    $value = $null
                }
            }
            elseif ($value_collection.Count -eq 0) {
                $value = $null
            }
            elseif ($value_collection.Count -eq 1) {
                $value = $value_collection[0]
            }
            else {
                $value = $value_collection
            }

            if ($value -is [DateTime]) {
                $value = $value.ToString('s')
            }

            $object[$p] = $value
        }

        New-Object -TypeName PSObject -Property $object
    }
}


#
# Generic CRUD functions
#

function New-ADObject-ADSI {
    param (
        [Parameter(Mandatory)] [String] $Class,
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [String] $Name,
        [switch] $PassThru,
        [Parameter(Mandatory)] [AllowEmptyString()] [String] $Path,
        [Hashtable] $Properties,
        [String] $Server
    )

    $parent_dirent = Get-DirectoryServicesDirectoryEntry $Credential (Make-LDAPPath $Server $Path)

    # Children.Add does not generate an exception if creds are incorrect, for example
    #$dirent = $parent_dirent.Children.Add("CN=$CN", $Class)
    $dirent = $parent_dirent.Create($Class, "$(if ($Class -eq 'organizationalUnit') { 'OU' } else { 'CN' })=$(Escape-CN $Name)")

    foreach ($p in $Properties.Keys) {
        switch ($p) {
            'AccountExpires' {
                $li = ([DateTime]$Properties[$p]).ToFileTimeUtc()

                if ($dirent.Properties[$p]) { $dirent.Properties[$p].Clear() }
                $dirent.Properties[$p].Add((ConvertTo-ADLargeInteger $li)) >$null
                break
            }

            'AccountPassword' {
                # Do this after object is created
                break
            }

            'CannotChangePassword' {
                # Do this after object is created
                break
            }

            'ChangePasswordAtLogon' {
                # Do this after object is created
                break
            }

            'Enabled' {
                # Do this after object is created
                break
            }

            'GroupCategory' {
                # Combine with 'GroupScope' to 'groupType'
                break
            }

            'GroupScope' {
                # Combine with 'GroupCategory' to 'groupType'
                break
            }

            'managedBy' {
                if ($Properties['managedBy']) {
                    $dirent.Properties[$p].Value = Make-UniversalIdentity $Properties['managedBy']
                }
                break
            }

            'PasswordNeverExpires' {
                # Do this after object is created
                break
            }

            'PasswordNotRequired' {
                # Do this after object is created
                break
            }

			'ProtectObjectFromDeletion' {
                # Do this after object is created
                break
            }

            { $p -in $Global:TerminalServicesAttributes } {
                $dirent.InvokeSet($_, $Properties[$p])
                break
            }

            'countryCode' {
                if ($dirent.Properties[$p]) { $dirent.Properties[$p].Clear() }
                if ($Properties[$p] -ne $null -and $Properties[$p] -ne '') {
                    $dirent.Properties[$p].Value = $Properties[$p]
                }
                break
            }

            default {
                if ($dirent.Properties[$p]) { $dirent.Properties[$p].Clear() }
                if ($Properties[$p] -ne $null -and $Properties[$p] -ne '') {
                    if ($Properties[$p] -is [array]) {
                        foreach ($e in $Properties[$p]) {
                            $dirent.Properties[$p].Add($e) >$null
                        }
                    }
                    else {
                        $dirent.Properties[$p].Add($Properties[$p]) >$null
                    }
                }
            }
        }
    }

    if ($class -eq 'user' -and -not $dirent.Properties.Contains('userAccountControl')) {
        $dirent.Properties['userAccountControl'].Add($ADS_UF_NORMAL_ACCOUNT -bor $ADS_UF_ACCOUNTDISABLE) >$null
    }

    if ($class -ne 'container' -and $class -ne 'organizationalUnit' -and -not $dirent.Properties['sAMAccountName']) {
        # Assure this property is set
        $dirent.Properties['sAMAccountName'].Add($Name) >$null
    }

    if ($Properties -and ($Properties.ContainsKey('GroupCategory') -or $Properties.ContainsKey('GroupScope'))) {
        # Overrule 'groupType' property
        if ($dirent.Properties['groupType']) { $dirent.Properties['groupType'].Clear() }

        $dirent.Properties['groupType'].Add((ConvertTo-GroupType -OldValue 0 -GroupCategory $Properties['GroupCategory'] -GroupScope $Properties['GroupScope'])) >$null
    }

    $dirent.CommitChanges()

    $additional_commit = $false

    if ($Properties) {
        # userAccountControl
        $new_uac_value = $dirent.Properties['userAccountControl'].Value

        if ($Properties.ContainsKey('Enabled')) {
            $new_uac_value = if ($Properties['Enabled']) {
                                 $new_uac_value -band (-bnot $ADS_UF_ACCOUNTDISABLE)
                             }
                             else {
                                 $new_uac_value -bor $ADS_UF_ACCOUNTDISABLE
                             }
        }

        if ($Properties.ContainsKey('PasswordNeverExpires')) {
            $new_uac_value = if ($Properties['PasswordNeverExpires']) {
                                 $new_uac_value -bor $ADS_UF_DONT_EXPIRE_PASSWD
                             }
                             else {
                                 $new_uac_value -band (-bnot $ADS_UF_DONT_EXPIRE_PASSWD)
                             }
        }

        if ($Properties.ContainsKey('PasswordNotRequired')) {
            $new_uac_value = if ($Properties['PasswordNotRequired']) {
                                 $new_uac_value -bor $ADS_UF_PASSWD_NOTREQD
                             }
                             else {
                                 $new_uac_value -band (-bnot $ADS_UF_PASSWD_NOTREQD)
                             }
        }

        if ($new_uac_value -ne $dirent.Properties['userAccountControl'].Value) {
            $dirent.Properties['userAccountControl'].Value = $new_uac_value
            $additional_commit = $true
        }

        # AccountPassword
        if ($Properties.ContainsKey('AccountPassword')) {
            $dirent.Invoke('SetPassword', $Properties['AccountPassword']) >$null
            $additional_commit = $true
        }

        # CannotChangePassword
        if ($Properties.ContainsKey('CannotChangePassword')) {
            # $dirent.ObjectSecurity accesses 'nTSecurityDescriptor' property
            Set-CannotChangePassword $dirent.ObjectSecurity $Properties['CannotChangePassword']
            $additional_commit = $true
        }

        # ChangePasswordAtLogon
        if ($Properties.ContainsKey('ChangePasswordAtLogon')) {
            $val = if ($Properties['ChangePasswordAtLogon']) { 0 } else { -1 }

            if ($dirent.Properties['pwdLastSet']) { $dirent.Properties['pwdLastSet'].Clear() }
            $dirent.Properties['pwdLastSet'].Add((ConvertTo-ADLargeInteger $val)) >$null

            $additional_commit = $true
        }

        # ProtectObjectFromDeletion
        if ($Properties.ContainsKey('ProtectObjectFromDeletion')) {
            # $dirent.ObjectSecurity accesses 'nTSecurityDescriptor' property
            Set-ProtectObjectFromDeletion $dirent.ObjectSecurity $Properties['ProtectObjectFromDeletion']
            $additional_commit = $true
        }
    }

    if ($additional_commit) {
        $dirent.CommitChanges()
    }

    if ($PassThru) {
        if ($Properties -and $Properties.ContainsKey('managedBy') -and $Properties['managedBy']) {
            # Restore requested value, as UniversalIdentity is apparently replaced by DN on CommitChanges()
            $dirent.Properties['managedBy'].Value = Make-UniversalIdentity $Properties['managedBy']
        }

        $additional_properties = @('objectGUID', 'distinguishedName','canonicalName','whenCreated','whenChanged')

        if ($dirent.Properties.Contains('objectSid')) {
            $additional_properties += 'objectSid'
        }

        $dirent.Properties | Convert-ADPropertyCollection -Credential $Credential -DirectoryEntry $dirent -Properties @($Properties.Keys + $additional_properties) | Add-Member -MemberType NoteProperty -Name 'adsPath' -Value $dirent.Path -PassThru
    }
}


function Get-ADObjectSingleSearchBase-ADSI {
    param (
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [String] $LDAPFilter,
        [ValidateNotNullOrEmpty()] [String[]] $Properties,
        [ValidateNotNullOrEmpty()] [Int32] $ResultPageSize = 256,
        [ValidateRange(1, [Int32]::MaxValue)] [Int32] $ResultSetSize,
        [ValidateNotNull()] $SearchBase,
        [System.DirectoryServices.SearchScope] $SearchScope = 'Subtree',
        [String] $Server
    )

    $searcher = New-Object System.DirectoryServices.DirectorySearcher

        #------------------------------------------------------
        # Configure System.DirectoryServices.DirectorySearcher
        #------------------------------------------------------

        # CacheResults: True
            #$searcher.CacheResults = $false

        # ClientTimeout: -00:00:01

        # PropertyNamesOnly: False

        # Filter:
            if ($LDAPFilter -ne '*') {
                $searcher.Filter = $LDAPFilter
            }

        # PageSize: 0
            if ($ResultPageSize -eq 0) { $ResultPageSize = 1 }
            $searcher.PageSize = $ResultPageSize

        # PropertiesToLoad: {}
            if (!$Properties) {
                # Use default property shortlist
                # https://social.technet.microsoft.com/wiki/contents/articles/12103.active-directory-get-adobject-default-and-extended-properties.aspx
                $Properties = @(
                    'distinguishedName'    # DistinguishedName
                    'Name'                 # Name
                    'objectClass'          # ObjectClass
                    'objectGUID'           # ObjectGUID
                )
            }

            if ($Properties -ne '*') {
                $searcher.PropertiesToLoad.Clear()

                foreach ($p in $Properties) {
                    $p_mapped = if ($Global:PropertyNamesMap[$p]) { $Global:PropertyNamesMap[$p] } else { $p }

                    if (-not $searcher.PropertiesToLoad.Contains($p_mapped)) {
                        [void]$searcher.PropertiesToLoad.Add($p_mapped)
                    }
                }
            }

        # ReferralChasing: External
            #$searcher.ReferralChasing = [DirectoryServices.ReferralChasingOption]::None

        # SearchScope: Subtree
            $searcher.SearchScope = $SearchScope

        # ServerPageTimeLimit: -00:00:01

        # ServerTimeLimit: -00:00:01

        # SizeLimit: 0

        # SearchRoot: System.DirectoryServices.DirectoryEntry
            ### {
            #$root = [ADSI]''
            #$searcher = New-Object System.DirectoryServices.DirectorySearcher($root)
            ### }

            ### { Connect to Global Catalog and setup searcher for the entire forest
            #$searcher = New-Object System.DirectoryServices.DirectorySearcher
            #[ADSI] $root_dse = 'LDAP://RootDSE'
            #$dirent = New-Object System.DirectoryServices.DirectoryEntry "GC://$($root_dse.rootDomainNamingContext)"
            #$searcher.SearchRoot = $dirent
            ### }

            ### {
            #$searcher = new-object System.DirectoryServices.DirectorySearcher 
            #$dirent = new-object System.DirectoryServices.DirectoryEntry 'LDAP://YOURDOMAIN/DC=yourdomain,DC=com', 'YOURDOMAIN\Administrator', '!Password!'
            #$dirent.RefreshCache()
            #$searcher.SearchRoot = $dirent

            ### }

            if ($Credential -or $Server -or $SearchBase -ne $null) {
                if ($Server -or $SearchBase -ne $null) {
                    $ldap_path = 'LDAP:/'

                    if ($Server) {
                        $ldap_path += '/' + $Server
                    }

                    if ($SearchBase -ne $null) {
                        if ($SearchBase -eq '') {
                            throw "$($MyInvocation.MyCommand) : An empty SearchBase is only supported while connected to a GlobalCatalog. (not implememnted)"
                        }

                        $ldap_path += '/' + $SearchBase.Replace('/','\/')
                    }
                }
                else {
                    $ldap_path = $searcher.SearchRoot.Path
                }

                $dirent = Get-DirectoryServicesDirectoryEntry $Credential $ldap_path

                #$dirent.RefreshCache()
                $searcher.SearchRoot = $dirent
            }

        # Sort: System.DirectoryServices.SortOption

        # Asynchronous: False

        # Tombstone: False

        # AttributeScopeQuery: 

        # DerefAlias: Never

        # SecurityMasks: None
        $searcher.SecurityMasks = [System.DirectoryServices.SecurityMasks]::Dacl -bor [System.DirectoryServices.SecurityMasks]::Group -bor [System.DirectoryServices.SecurityMasks]::Owner

        # Control the contents of the member attribute (distinguishedName or objectGUID)
        # https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-adts/57056773-932c-4e55-9491-e13f49ba580c?redirectedfrom=MSDN
        $searcher.ExtendedDN = [System.DirectoryServices.ExtendedDN]::Standard

        # DirectorySynchronization: 

        # VirtualListView: 

        # Site: 

        # Container: 


        #--------------------------------------------------------------------------------
        # Invoke System.DirectoryServices.DirectorySearcher.FindAll() and process result
        #--------------------------------------------------------------------------------

        $result_count = $ResultSetSize

        # https://stackoverflow.com/questions/47539373/dispose-of-searchresultcollection-after-foreach-object
        # "Because the object you're dealing with is an enumerator and not a pre-generated collection, it won't really matter"
        $rows = $null
        $rows = $searcher.FindAll()

            # Adding logging here causes additional memory consumption and worse performance

            if (!$ResultSetSize) {

                $rows.Properties | Convert-ADPropertyCollection -Credential $Credential -Properties $Properties

            }
            else {

                do {
                    $rows | ForEach-Object {
                        $_.Properties
                        if (--$result_count -eq 0) { break }
                    } | Convert-ADPropertyCollection -Credential $Credential -Properties $Properties
                } while ($false)

            }

        $rows.Dispose()

    $searcher.Dispose()
}

function Get-ADObjectACL-ADSI {
    param (
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [String] $LDAPFilter,
        [ValidateNotNullOrEmpty()] [String[]] $Properties,
        [ValidateNotNullOrEmpty()] [Int32] $ResultPageSize = 256,
        [ValidateRange(1, [Int32]::MaxValue)] [Int32] $ResultSetSize,
        [ValidateNotNull()] [String[]] $SearchBases,
        [System.DirectoryServices.SearchScope] $SearchScope = 'Subtree',
        [String] $Server
    )
    
    $args = @{
        # These parameters always have a value
        LDAPFilter = $LDAPFilter
        ResultPageSize = $ResultPageSize
        SearchScope = $SearchScope
    }

    if ($Credential) {
        $args.Credential = $Credential
    }

    if ($Properties) {
        $args.Properties = @("objectGUID","objectClass")
    }

    if ($ResultSetSize) {
        $args.ResultSetSize = $ResultSetSize
    }

    if ($Server) {
        $args.Server = $Server
    }

    $objects = [System.Collections.ArrayList]@()
    if ($SearchBases -eq $null) {
        foreach($obj in (Get-ADObjectSingleSearchBase-ADSI @args))
        {
            [void]$objects.Add($obj)
        }
    }
    else {
        foreach ($searchbase in $SearchBases) {
            foreach($obj in (Get-ADObjectSingleSearchBase-ADSI @args -SearchBase $searchbase))
            {
                [void]$objects.Add($obj)
            }
        }
    }

    foreach ($result in $objects) {
        $directoryEntry = Get-DirectoryServicesDirectoryEntry $Credential (Make-LDAPPath $Server $result.objectGUID)

        $objectSID = $null

        try {
            if ($directoryEntry.Properties["objectSID"].Count -gt 0) {
                $objectSID = (New-Object System.Security.Principal.SecurityIdentifier($directoryEntry.Properties["objectSID"][0], 0)).Value
            }
        }
        catch {}

        try {   
            # Get the security descriptor for the object
            $securityDescriptor = $directoryEntry.psbase.ObjectSecurity
    
            # Get the access rules (ACLs)
            $accessRules = $securityDescriptor.GetAccessRules($true, $true, [System.Security.Principal.NTAccount])
        }
        catch {
            LogIO warn "Failed to retrieve ACL for $adsiPath. Error: $_"
            continue
        }

        foreach ($accessRule in $accessRules) {
            $object = @{
                ObjectClass = $result.ObjectClass
                ObjectGUID = $result.ObjectGUID
                ObjectSid = $objectSID
                Identity = $accessRule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
                IdentityName = $accessRule.IdentityReference.Value
                AccessControlType = $accessRule.AccessControlType.ToString()
                ActiveDirectoryRights = $accessRule.ActiveDirectoryRights.ToString()
                InheritanceFlags = $accessRule.InheritanceFlags.ToString()
                PropagationFlags = $accessRule.PropagationFlags.ToString()
            }
            
            # Generate unique has for NIM Table delete operation
            $object['id'] = HashObjectToId $object

            [PSCustomObject]$object
        }
        
    }
}

function New-ADAcl-ADSI {
    param (
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [String] $ObjectGUID,
        [Parameter(Mandatory)] [String] $AccessControlType,
        [Parameter(Mandatory)] [String] $Identity,
        [Parameter(Mandatory)] [String[]] $ActiveDirectoryRights,
        [String] $Server
    )

    $args = @{}

    if ($Credential) {
        $args.Credential = $Credential
    }

    if ($Server) {
        $args.Server = $Server
    }

    # Get the directory entry for the AD object
    $directoryEntry = Get-DirectoryServicesDirectoryEntry $Credential (Make-LDAPPath $Server $ObjectGUID)

    # Get the current security descriptor for the object
    $securityDescriptor = $directoryEntry.psbase.ObjectSecurity

    # Convert the access control type to the appropriate enumeration
    $accessControlTypeEnum = [System.Security.AccessControl.AccessControlType] $AccessControlType

    # Convert the Active Directory rights to the appropriate enumeration
    $rights = [System.DirectoryServices.ActiveDirectoryRights]::GenericRead
   
    foreach ($right in $ActiveDirectoryRights) {
        $rights = $rights -bor [System.DirectoryServices.ActiveDirectoryRights] $right
    }

    # Create a new Active Directory access rule
    $identitySID = [System.Security.Principal.SecurityIdentifier] $Identity

    $accessRule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $identitySID,
        $rights,
        $accessControlTypeEnum
    )

    # Add the access rule to the security descriptor
    $securityDescriptor.AddAccessRule($accessRule)

    # Save the updated security descriptor back to the directory entry
    $directoryEntry.psbase.ObjectSecurity = $securityDescriptor
    $directoryEntry.CommitChanges()

    
    # Retreive rule for NIM
    $directoryEntry = Get-DirectoryServicesDirectoryEntry $Credential (Make-LDAPPath $Server $ObjectGUID)
    $rules = $directoryEntry.psbase.ObjectSecurity.GetAccessRules($true, $true, [System.Security.Principal.NTAccount])
    foreach($accessRule in $rules) {
        if($accessRule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -eq $Identity -and $accessRule.ActiveDirectoryRights -eq $rights) {
            $object = @{
                ObjectClass = $directoryEntry.ObjectClass[-1]
                ObjectGUID = $ObjectGUID
                ObjectSid = (New-Object System.Security.Principal.SecurityIdentifier($directoryEntry.Properties["objectSID"][0], 0)).Value
                Identity = $accessRule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
                IdentityName = $accessRule.IdentityReference.Value
                AccessControlType = $accessRule.AccessControlType.ToString()
                ActiveDirectoryRights = $accessRule.ActiveDirectoryRights.ToString()
                InheritanceFlags = $accessRule.InheritanceFlags.ToString()
                PropagationFlags = $accessRule.PropagationFlags.ToString()
            }
            
            # Generate unique has for NIM Table delete operation
            $object['id'] = HashObjectToId $object

            [PSCustomObject]$object
            break
        }   
    }

}

function Remove-ADAcl-ADSI {
    param (
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [String] $ObjectGUID,
        [Parameter(Mandatory)] [String] $Identity,
        [Parameter(Mandatory)] [String[]] $ActiveDirectoryRights,
        [String] $Server
    )

    $args = @{}

    if ($Credential) {
        $args.Credential = $Credential
    }

    if ($Server) {
        $args.Server = $Server
    }

    # Get the directory entry for the AD object
    $directoryEntry = Get-DirectoryServicesDirectoryEntry $Credential (Make-LDAPPath $Server $ObjectGUID)

    # Get the current security descriptor for the object
    $securityDescriptor = $directoryEntry.psbase.ObjectSecurity

    # Convert the Active Directory rights to the appropriate enumeration
    $rights = [System.DirectoryServices.ActiveDirectoryRights]::GenericRead
   
    foreach ($right in $ActiveDirectoryRights) {
        $rights = $rights -bor [System.DirectoryServices.ActiveDirectoryRights] $right
    }

    # Retrieve rules for NIM
    $rules = $securityDescriptor.GetAccessRules($true, $true, [System.Security.Principal.NTAccount])

    # Find the rule to remove
    $ruleToRemove = $rules | Where-Object { 
        $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -eq $Identity -and
        $_.ActiveDirectoryRights -eq $rights
    }

    if ($ruleToRemove) {
        # Remove the rule
        $securityDescriptor.RemoveAccessRule($ruleToRemove)
        $directoryEntry.CommitChanges()

        $true
    } else {
        $false
    }
}


function Get-ADObject-ADSI {
    param (
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [String] $LDAPFilter,
        [ValidateNotNullOrEmpty()] [String[]] $Properties,
        [ValidateNotNullOrEmpty()] [Int32] $ResultPageSize = 256,
        [ValidateRange(1, [Int32]::MaxValue)] [Int32] $ResultSetSize,
        [ValidateNotNull()] [String[]] $SearchBases,
        [System.DirectoryServices.SearchScope] $SearchScope = 'Subtree',
        [String[]] $Servers
    )

    $args = @{
        # These parameters always have a value
        LDAPFilter = $LDAPFilter
        ResultPageSize = $ResultPageSize
        SearchScope = $SearchScope
    }

    if ($Credential) {
        $args.Credential = $Credential
    }

    if ($Properties) {
        $args.Properties = $Properties
    }

    if ($ResultSetSize) {
        $args.ResultSetSize = $ResultSetSize
    }

    $servers_not_null = if ($Servers) { $Servers } else { @('') }

    foreach ($server in $servers_not_null) {
        if ($server) {
            $args.Server = $server
        }

        if ($SearchBases -eq $null) {
            Get-ADObjectSingleSearchBase-ADSI @args
        }
        else {
            foreach ($searchbase in $SearchBases) {
                Get-ADObjectSingleSearchBase-ADSI @args -SearchBase $searchbase
            }
        }
    }
}


function Move-ADObject-ADSI {
    param (
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [String] $DistinguishedName,      # Binding using objectGUID not allowed
        [Parameter(Mandatory)] [String] $TargetPath,
        [String] $Server
    )

    $target_server = Get-DomainFromDN $TargetPath

    if ($target_server -ne $Server) {
        # Move accross domains: Specify RID Masters for both domains, see:
        # https://learn.microsoft.com/en-us/powershell/module/activedirectory/move-adobject?view=windowsserver2022-ps

        $Server = Get-ADRidMaster $Credential $Server
        $target_server = Get-ADRidMaster $Credential $target_server
    }

    $dirent_src = Get-DirectoryServicesDirectoryEntry $Credential (Make-LDAPPath $Server $DistinguishedName)
    $dirent_trg = Get-DirectoryServicesDirectoryEntry $Credential (Make-LDAPPath $target_server $TargetPath)

    if ($dirent_src.Properties.Count -eq 0) { $dirent_src.RefreshCache() }

    $dirent_src.MoveTo($dirent_trg)
}


function Rename-ADObject-ADSI {
    param (
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [String] $DistinguishedName,
        [Parameter(Mandatory)] [String] $NewName,
        [String] $Server
    )

    $dirent = Get-DirectoryServicesDirectoryEntry $Credential (Make-LDAPPath $Server $DistinguishedName)

    if ($dirent.Properties.Count -eq 0) { $dirent.RefreshCache() }

    $dirent.Rename($NewName)
    $dirent.CommitChanges()
}


function Set-ADObject-ADSI {
    param (
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [String] $Identity,
        [switch] $PassThru,
        [Hashtable] $Properties,
        [String] $Server
    )

    if ($Properties -and ($Properties.ContainsKey('cn') -or $Properties.ContainsKey('Path'))) {
        $dirent = Get-DirectoryServicesDirectoryEntry $Credential (Make-LDAPPath $Server $Identity)

        if ($dirent.Properties.Count -eq 0) { $dirent.RefreshCache() }

        $distinguished_name = $dirent.Properties['distinguishedName']

        if ($Properties.ContainsKey('Path')) {
            $path_trg = $Properties['Path']

            # Skip CN= part
            $path_src_ix = $distinguished_name.Replace('\\','  ').Replace('\,','  ').IndexOf(',')
            $path_src = $distinguished_name.Substring($path_src_ix + 1)

            if ($path_trg -ne $path_src) {
                $args = @{}

                if ($Credential) {
                    $args.Credential = $Credential
                }

                if ($Server) {
                    $args.Server = $Server
                }

                Move-ADObject-ADSI @args -DistinguishedName $distinguished_name -TargetPath $path_trg

                # Modify for subsequent use...
                $Server = Get-DomainFromDN $path_trg
                $distinguished_name = $distinguished_name.Substring(0, $path_src_ix) + ',' + $path_trg
            }
        }

        if ($Properties.ContainsKey('cn')) {
            $new_name = 'CN=' + (Escape-CN $Properties['cn'])

            $pos_path = $distinguished_name.Replace('\\','  ').Replace('\,','  ').IndexOf(',')
            $new_dn   = $new_name + $distinguished_name.Substring($pos_path)

            if ($new_dn -ne $distinguished_name) {
                $args = @{}

                if ($Credential) {
                    $args.Credential = $Credential
                }

                if ($Server) {
                    $args.Server = $Server
                }

                Rename-ADObject-ADSI @args -DistinguishedName $distinguished_name -NewName $new_name
            }
        }
    }

    $dirent = Get-DirectoryServicesDirectoryEntry $Credential (Make-LDAPPath $Server $Identity)

    if ($dirent.Properties.Count -eq 0) { $dirent.RefreshCache() }

    foreach ($p in $Properties.Keys) {
        switch ($p) {
            'AccountExpires' {
                $li = ([DateTime]$Properties[$p]).ToFileTimeUtc()

                if ($dirent.Properties[$p]) { $dirent.Properties[$p].Clear() }
                $dirent.Properties[$p].Add((ConvertTo-ADLargeInteger $li)) >$null
                break
            }

            'AccountPassword' {
                $dirent.Invoke('SetPassword', $Properties[$p]) >$null
                break
            }

            'CannotChangePassword' {
                # https://flylib.com/books/en/1.434.1/com_interop_data_types.html
                # $dirent.ObjectSecurity accesses 'nTSecurityDescriptor' property
                Set-CannotChangePassword $dirent.ObjectSecurity $Properties[$p]
                break
            }

            'ChangePasswordAtLogon' {
                $val = if ($Properties[$p]) { 0 } else { -1 }

                if ($dirent.Properties['pwdLastSet']) { $dirent.Properties['pwdLastSet'].Clear() }
                $dirent.Properties['pwdLastSet'].Add((ConvertTo-ADLargeInteger $val)) >$null
                break
            }

            'cn' {
                # Already handled above
                break
            }

            'Enabled' {
                # Do this after possible 'userAccountControl' is processed
                break
            }

            'GroupCategory' {
                # Combine with 'GroupScope' to 'groupType'
                break
            }

            'GroupScope' {
                # Combine with 'GroupCategory' to 'groupType'
                break
            }

            'managedBy' {
                if ($Properties['managedBy']) {
                    $dirent.Properties[$p].Value = Make-UniversalIdentity $Properties['managedBy']
                }
                else {
                    $dirent.Properties[$p].Clear()
                }
                break
            }

            'PasswordNeverExpires' {
                # Do this after possible 'userAccountControl' is processed
                break
            }

            'PasswordNotRequired' {
                # Do this after possible 'userAccountControl' is processed
                break
            }

            'Path' {
                # Already handled above
                break
            }

            { $p -in $Global:TerminalServicesAttributes } {
                $dirent.InvokeSet($_, $Properties[$p])
                break
            }

			'ProtectObjectFromDeletion' {
                # https://flylib.com/books/en/1.434.1/com_interop_data_types.html
                # $dirent.ObjectSecurity accesses 'nTSecurityDescriptor' property
                Set-ProtectObjectFromDeletion $dirent.ObjectSecurity $Properties[$p]
                break
            }

            'countryCode' {
                if ($dirent.Properties[$p]) { $dirent.Properties[$p].Clear() }
                if ($Properties[$p] -ne $null -and $Properties[$p] -ne '') {
                    $dirent.Properties[$p].Value = $Properties[$p]
                }
                break
            }

            'thumbnailPhoto' {
                $dirent.Properties[$p].Value = [System.Convert]::FromBase64String($Properties[$p])
                break
            }

            default {
                if ($dirent.Properties[$p]) { $dirent.Properties[$p].Clear() }
                if ($Properties[$p] -ne $null -and $Properties[$p] -ne '') {
                    if ($Properties[$p] -is [array]) {
                        foreach ($e in $Properties[$p]) {
                            $dirent.Properties[$p].Add($e) >$null
                        }
                    }
                    else {
                        $dirent.Properties[$p].Add($Properties[$p]) >$null
                    }
                }
            }
        }
    }

    if ($Properties) {
        # userAccountControl
        $new_uac_value = $dirent.Properties['userAccountControl'].Value

        if ($Properties.ContainsKey('Enabled')) {
            $new_uac_value = if ($Properties['Enabled']) {
                                 $new_uac_value -band (-bnot $ADS_UF_ACCOUNTDISABLE)
                             }
                             else {
                                 $new_uac_value -bor $ADS_UF_ACCOUNTDISABLE
                             }
        }

        if ($Properties.ContainsKey('PasswordNeverExpires')) {
            $new_uac_value = if ($Properties['PasswordNeverExpires']) {
                                 $new_uac_value -bor $ADS_UF_DONT_EXPIRE_PASSWD
                             }
                             else {
                                 $new_uac_value -band (-bnot $ADS_UF_DONT_EXPIRE_PASSWD)
                             }
        }

        if ($Properties.ContainsKey('PasswordNotRequired')) {
            $new_uac_value = if ($Properties['PasswordNotRequired']) {
                                 $new_uac_value -bor $ADS_UF_PASSWD_NOTREQD
                             }
                             else {
                                 $new_uac_value -band (-bnot $ADS_UF_PASSWD_NOTREQD)
                             }
        }

        $dirent.Properties['userAccountControl'].Value = $new_uac_value

        # groupType
        if ($Properties.ContainsKey('GroupCategory') -or $Properties.ContainsKey('GroupScope')) {
            $dirent.Properties['groupType'][0] = ConvertTo-GroupType -OldValue $dirent.Properties['groupType'][0] -GroupCategory $Properties['GroupCategory'] -GroupScope $Properties['GroupScope']
        }
    }

    $dirent.CommitChanges()

    if ($PassThru) {
        if ($Properties -and $Properties.ContainsKey('managedBy') -and $Properties['managedBy']) {
            # Restore requested value, as UniversalIdentity is apparently replaced by DN on CommitChanges()
            $dirent.Properties['managedBy'].Value = Make-UniversalIdentity $Properties['managedBy']
        }

        $additional_properties = @('objectGUID', 'distinguishedName','canonicalName')

        if ($dirent.Properties.Contains('objectSid')) {
            $additional_properties += 'objectSid'
        }

        $dirent.Properties | Convert-ADPropertyCollection -Credential $Credential -DirectoryEntry $dirent -Properties @($Properties.Keys + $additional_properties) | Add-Member -MemberType NoteProperty -Name 'adsPath' -Value $dirent.Path -PassThru
    }
}


function Set-ADGroupMember-ADSI {
    param (
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [String] $Identity,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [String[]] $MembersAdd,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [String[]] $MembersRemove,
        [switch] $PassThru,
        [String] $Server
    )

    $dirent = Get-DirectoryServicesDirectoryEntry $Credential (Make-LDAPPath $Server $Identity)

    if ($dirent.Properties.Count -eq 0) { $dirent.RefreshCache() }

    $n = 0
    foreach ($m in $MembersAdd) {
        $dirent.Properties['member'].Add((Make-UniversalIdentity $m)) >$null

        $n++
        if ($n -eq 65535) {
            $dirent.CommitChanges()
            $n = 0
        }
    }

    foreach ($m in $MembersRemove) {
        $dirent.Properties['member'].Remove((Make-UniversalIdentity $m)) >$null

        $n++
        if ($n -eq 65535) {
            $dirent.CommitChanges()
            $n = 0
        }
    }

    if ($n -gt 0) {
        $dirent.CommitChanges()
    }

    if ($PassThru) {
        $dirent.Properties | Convert-ADPropertyCollection -Credential $Credential -DirectoryEntry $dirent -Properties '*' -SkipProperties 'member' | Add-Member -MemberType NoteProperty -Name 'adsPath' -Value $dirent.Path -PassThru
    }
}


function Remove-ADObject-ADSI {
    param (
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [String] $Identity,
        [switch] $PassThru,
        [String] $Server
    )

    $dirent = Get-DirectoryServicesDirectoryEntry $Credential (Make-LDAPPath $Server $Identity)
    $dirent.DeleteTree()

    if ($PassThru) {
        @{
            objectGUID = $Identity
        }
    }
}


#
# Object-specific CRUD functions
#

function New-ADUser-ADSI {
    param (
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [String] $CN,
        [switch] $PassThru,
        [Parameter(Mandatory)] [AllowEmptyString()] [String] $Path,
        [Hashtable] $Properties,
        [String] $Server
    )

    $args = @{}

    if ($Credential) {
        $args.Credential = $Credential
    }

    if ($PassThru) {
        $args.PassThru = $true
    }

    if ($Properties) {
        $args.Properties = $Properties
    }
    
    $domain = Get-DomainFromDN $Path
    $args.Server = Get-ADRidMaster -Credential $Credential -Server $domain

    New-ADObject-ADSI -Class 'user' -Name $CN -Path $Path @args
}


function Get-ADUser-ADSI {
    param (
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [String] $LDAPFilter,
        [ValidateNotNullOrEmpty()] [String[]] $Properties,
        [ValidateNotNullOrEmpty()] [Int32] $ResultPageSize = 256,
        [ValidateRange(1, [Int32]::MaxValue)] [Int32] $ResultSetSize,
        [ValidateNotNull()] $SearchBases,
        [System.DirectoryServices.SearchScope] $SearchScope = 'Subtree',
        [String[]] $Servers
    )

    $args = @{
        # These parameters always have a value
        ResultPageSize = $ResultPageSize
        SearchScope = $SearchScope
    }

    if ($Credential) {
        $args.Credential = $Credential
    }

    $args.LDAPFilter = '(&(objectCategory=person)(objectClass=user))'

    if ($LDAPFilter -ne '*') {
        $args.LDAPFilter = "(&$($args.LDAPFilter)($LDAPFilter))"
    }

    if (!$Properties) {
        # Use default property shortlist
        # https://social.technet.microsoft.com/wiki/contents/articles/12037.active-directory-get-aduser-default-and-extended-properties.aspx
        $Properties = @(
            'distinguishedName'    # DistinguishedName
            'Enabled'              # Enabled
            'givenName'            # GivenName
            'cn'                   # Name
            'objectClass'          # ObjectClass
            'objectGUID'           # ObjectGUID
            'sAMAccountName'       # SamAccountName
            'objectSid'            # SID
            'Path'
            'sn'                   # Surname
            'userPrincipalName'    # UserPrincipalName
        )
    }

    if ($Properties) {
        $args.Properties = $Properties
    }

    if ($ResultSetSize) {
        $args.ResultSetSize = $ResultSetSize
    }

    if ($SearchBases -ne $null) {
        $args.SearchBases = $SearchBases
    }

    if ($Servers) {
        $args.Servers = $Servers
    }

    Get-ADObject-ADSI @args
}


function Set-ADUser-ADSI {
    param (
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [String] $Identity,
        [switch] $PassThru,
        [Hashtable] $Properties,
        [String] $Server
    )

    $args = @{}

    if ($Credential) {
        $args.Credential = $Credential
    }

    if ($PassThru) {
        $args.PassThru = $true
    }

    if ($Properties) {
        $args.Properties = $Properties
    }

    $args.Server = Get-ADRidMasterFromGuid -GUID $Identity -Credential $Credential

    Set-ADObject-ADSI -Identity $Identity @args
}


function Remove-ADUser-ADSI {
    param (
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [String] $Identity,
        [switch] $PassThru,
        [String] $Server
    )

    $args = @{}

    if ($Credential) {
        $args.Credential = $Credential
    }

    if ($PassThru) {
        $args.PassThru = $true
    }

    $args.Server = Get-ADRidMasterFromGuid -GUID $Identity -Credential $Credential

    Remove-ADObject-ADSI -Identity $Identity @args
}


function New-ADComputer-ADSI {
    param (
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [String] $CN,
        [switch] $PassThru,
        [Parameter(Mandatory)] [AllowEmptyString()] [String] $Path,
        [Hashtable] $Properties,
        [String] $Server
    )

    $args = @{}

    if ($Credential) {
        $args.Credential = $Credential
    }

    if ($PassThru) {
        $args.PassThru = $true
    }

    if ($Properties) {
        $args.Properties = $Properties
    }

    $domain = Get-DomainFromDN $Path
    $args.Server = Get-ADRidMaster -Credential $Credential -Server $domain

    New-ADObject-ADSI -Class 'computer' -Name $CN -Path $Path @args
}


function Get-ADComputer-ADSI {
    param (
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [String] $LDAPFilter,
        [ValidateNotNullOrEmpty()] [String[]] $Properties,
        [ValidateNotNullOrEmpty()] [Int32] $ResultPageSize = 256,
        [ValidateRange(1, [Int32]::MaxValue)] [Int32] $ResultSetSize,
        [ValidateNotNull()] $SearchBases,
        [System.DirectoryServices.SearchScope] $SearchScope = 'Subtree',
        [String[]] $Servers
    )

    $args = @{
        # These parameters always have a value
        ResultPageSize = $ResultPageSize
        SearchScope = $SearchScope
    }

    if ($Credential) {
        $args.Credential = $Credential
    }

    $args.LDAPFilter = '(objectClass=computer)'

    if ($LDAPFilter -ne '*') {
        $args.LDAPFilter = "(&$($args.LDAPFilter)($LDAPFilter))"
    }

    if (!$Properties) {
        # Use default property shortlist
        # https://social.technet.microsoft.com/wiki/contents/articles/12056.active-directory-get-adcomputer-default-and-extended-properties.aspx
        $Properties = @(
            'distinguishedName'    # DistinguishedName
            'dNSHostName'          # DNSHostName
            'Enabled'              # Enabled
            'cn'                   # Name
            'objectClass'          # ObjectClass
            'objectGUID'           # ObjectGUID
            'sAMAccountName'       # SamAccountName
            'objectSid'            # SID
            'Path'
            'userPrincipalName'    # UserPrincipalName
        )
    }

    if ($Properties) {
        $args.Properties = $Properties
    }

    if ($ResultSetSize) {
        $args.ResultSetSize = $ResultSetSize
    }

    if ($SearchBases -ne $null) {
        $args.SearchBases = $SearchBases
    }

    $args.Server = Get-ADRidMasterFromGuid -GUID $Identity -Credential $Credential

    Get-ADObject-ADSI @args
}


function Set-ADComputer-ADSI {
    param (
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [String] $Identity,
        [switch] $PassThru,
        [Hashtable] $Properties,
        [String] $Server
    )

    $args = @{}

    if ($Credential) {
        $args.Credential = $Credential
    }

    if ($PassThru) {
        $args.PassThru = $true
    }

    if ($Properties) {
        $args.Properties = $Properties
    }

    $args.Server = Get-ADRidMasterFromGuid -GUID $Identity -Credential $Credential

    Set-ADObject-ADSI -Identity $Identity @args
}


function Remove-ADComputer-ADSI {
    param (
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [String] $Identity,
        [switch] $PassThru,
        [String] $Server
    )

    $args = @{}

    if ($Credential) {
        $args.Credential = $Credential
    }

    if ($PassThru) {
        $args.PassThru = $true
    }

    $args.Server = Get-ADRidMasterFromGuid -GUID $Identity -Credential $Credential

    Remove-ADObject-ADSI -Identity $Identity @args
}


function New-ADGroup-ADSI {
    param (
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [String] $CN,
        [switch] $PassThru,
        [Parameter(Mandatory)] [AllowEmptyString()] [String] $Path,
        [Hashtable] $Properties,
        [String] $Server
    )

    $args = @{}

    if ($Credential) {
        $args.Credential = $Credential
    }

    if ($PassThru) {
        $args.PassThru = $true
    }

    if ($Properties) {
        $args.Properties = $Properties
    }

    $domain = Get-DomainFromDN $Path
    $args.Server = Get-ADRidMaster -Credential $Credential -Server $domain

    New-ADObject-ADSI -Class 'group' -Name $CN -Path $Path @args
}


function Get-ADGroup-ADSI {
    param (
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [String] $LDAPFilter,
        [ValidateNotNullOrEmpty()] [String[]] $Properties,
        [ValidateNotNullOrEmpty()] [Int32] $ResultPageSize = 256,
        [ValidateRange(1, [Int32]::MaxValue)] [Int32] $ResultSetSize,
        [ValidateNotNull()] $SearchBases,
        [System.DirectoryServices.SearchScope] $SearchScope = 'Subtree',
        [String[]] $Servers
    )

    $args = @{
        # These parameters always have a value
        ResultPageSize = $ResultPageSize
        SearchScope = $SearchScope
    }

    if ($Credential) {
        $args.Credential = $Credential
    }

    $args.LDAPFilter = '(objectClass=group)'

    if ($LDAPFilter -ne '*') {
        $args.LDAPFilter = "(&$($args.LDAPFilter)($LDAPFilter))"
    }

    if (!$Properties) {
        # Use default property shortlist
        # https://social.technet.microsoft.com/wiki/contents/articles/12079.active-directory-get-adgroup-default-and-extended-properties.aspx
        $Properties = @(
            'distinguishedName'    # DistinguishedName
            'GroupCategory'        # GroupCategory
            'GroupScope'           # GroupScope
            'cn'                   # Name
            'objectClass'          # ObjectClass
            'objectGUID'           # ObjectGUID
            'Path'
            'sAMAccountName'       # SamAccountName
            'objectSid'            # SID
         )
    }

    if ($Properties) {
        $args.Properties = $Properties
    }

    if ($ResultSetSize) {
        $args.ResultSetSize = $ResultSetSize
    }

    if ($SearchBases -ne $null) {
        $args.SearchBases = $SearchBases
    }

    if ($Servers) {
        $args.Servers = $Servers
    }

    Get-ADObject-ADSI @args
}


function Set-ADGroup-ADSI {
    param (
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [String] $Identity,
        [switch] $PassThru,
        [Hashtable] $Properties,
        [String] $Server
    )

    $args = @{}

    if ($Credential) {
        $args.Credential = $Credential
    }

    if ($PassThru) {
        $args.PassThru = $true
    }

    if ($Properties) {
        $args.Properties = $Properties
    }

    $args.Server = Get-ADRidMasterFromGuid -GUID $Identity -Credential $Credential

    Set-ADObject-ADSI -Identity $Identity @args
}


function Remove-ADGroup-ADSI {
    param (
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [String] $Identity,
        [switch] $PassThru,
        [String] $Server
    )

    $args = @{}

    if ($Credential) {
        $args.Credential = $Credential
    }

    if ($PassThru) {
        $args.PassThru = $true
    }

    $args.Server = Get-ADRidMasterFromGuid -GUID $Identity -Credential $Credential

    Remove-ADObject-ADSI -Identity $Identity @args
}


function New-ADOrganizationalUnit-ADSI {
    param (
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [String] $OU,
        [switch] $PassThru,
        [Parameter(Mandatory)] [AllowEmptyString()] [String] $Path,
        [Hashtable] $Properties,
        [String] $Server
    )

    $args = @{}

    if ($Credential) {
        $args.Credential = $Credential
    }

    if ($PassThru) {
        $args.PassThru = $true
    }

    if ($Properties) {
        $args.Properties = $Properties
    }

    $domain = Get-DomainFromDN $Path
    $args.Server = Get-ADRidMaster -Credential $Credential -Server $domain

    New-ADObject-ADSI -Class 'organizationalUnit' -Name $OU -Path $Path @args
}


function Get-ADOrganizationalUnit-ADSI {
    param (
        [PSCredential] $Credential,
        [switch] $IncludeContainers,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [String] $LDAPFilter,
        [ValidateNotNullOrEmpty()] [String[]] $Properties,
        [ValidateNotNullOrEmpty()] [Int32] $ResultPageSize = 256,
        [ValidateRange(1, [Int32]::MaxValue)] [Int32] $ResultSetSize,
        [ValidateNotNull()] $SearchBases,
        [System.DirectoryServices.SearchScope] $SearchScope = 'Subtree',
        [String[]] $Servers
    )

    $args = @{
        # These parameters always have a value
        ResultPageSize = $ResultPageSize
        SearchScope = $SearchScope
    }

    if ($Credential) {
        $args.Credential = $Credential
    }

    $args.LDAPFilter = '(objectClass=organizationalUnit)'

    if ($IncludeContainers) {
        $args.LDAPFilter = "(|$($args.LDAPFilter)(objectClass=container))"
    }

    if ($LDAPFilter -ne '*') {
        $args.LDAPFilter = "(&$($args.LDAPFilter)($LDAPFilter))"
    }

    if (!$Properties) {
        # Use default property shortlist
        # https://social.technet.microsoft.com/wiki/contents/articles/12089.active-directory-get-adorganizationalunit-default-and-extended-properties.aspx
        $Properties = @(
            'c'                    # Country
            'distinguishedName'    # DistinguishedName
            'gPLink'               # LinkedGroupPolicyObjects
            'l'                    # City
            'managedBy'            # ManagedBy
            'ou'                   # Name
            'objectClass'          # ObjectClass
            'objectGUID'           # ObjectGUID
            'Path'
            'postalCode'           # PostalCode
            'st'                   # State
            'streetAddress'        # StreetAddress
         )
    }

    if ($Properties) {
        $args.Properties = $Properties
    }

    if ($ResultSetSize) {
        $args.ResultSetSize = $ResultSetSize
    }

    if ($SearchBases -ne $null) {
        $args.SearchBases = $SearchBases
    }

    if ($Servers) {
        $args.Servers = $Servers
    }

    Get-ADObject-ADSI @args
}


function Set-ADOrganizationalUnit-ADSI {
    param (
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [String] $Identity,
        [switch] $PassThru,
        [Hashtable] $Properties,
        [String] $Server
    )

    $args = @{}

    if ($Credential) {
        $args.Credential = $Credential
    }

    if ($PassThru) {
        $args.PassThru = $true
    }

    if ($Properties) {
        $args.Properties = $Properties
    }

    $args.Server = Get-ADRidMasterFromGuid -GUID $Identity -Credential $Credential

    Set-ADObject-ADSI -Identity $Identity @args
}


function Remove-ADOrganizationalUnit-ADSI {
    param (
        [PSCredential] $Credential,
        [Parameter(Mandatory)] [String] $Identity,
        [switch] $PassThru,
        [String] $Server
    )

    $args = @{}

    if ($Credential) {
        $args.Credential = $Credential
    }

    if ($PassThru) {
        $args.PassThru = $true
    }

    if ($Server) {
        $args.Server = $Server
    }

    Remove-ADObject-ADSI -Identity $Identity @args
}

##################
# END OF ADSI.ps1
##################


$Log_MaskableKeys = @(
    'Password',
    'accountPassword'
)


#
# System functions
#

function Idm-SystemInfo {
    param (
        # Operations
        [switch] $Connection,
        [switch] $TestConnection,
        [switch] $Configuration,
        # Parameters
        [string] $ConnectionParams
    )

    Log info "-Connection=$Connection -TestConnection=$TestConnection -Configuration=$Configuration -ConnectionParams='$ConnectionParams'"
    
    if ($Connection) {
        @(
            @{
                name = 'root_domain'
                type = 'textbox'
                label = 'Root domain'
                tooltip = 'Root domain or AD forest to get; empty for root of current domain'
                value = ''
            }
            @{
                name = 'use_svc_account_creds'
                type = 'checkbox'
                label = 'Use credentials of service account'
                value = $true
            }
            @{
                name = 'username'
                type = 'textbox'
                label = 'Username'
                label_indent = $true
                tooltip = 'User account name to access domain services'
                value = ''
                hidden = 'use_svc_account_creds'
            }
            @{
                name = 'password'
                type = 'textbox'
                password = $true
                label = 'Password'
                label_indent = $true
                tooltip = 'User account password to access domain services'
                value = ''
                hidden = 'use_svc_account_creds'
            }
            @{
                name = 'nr_of_sessions'
                type = 'textbox'
                label = 'Max. number of simultaneous sessions'
                value = 5
            }
            @{
                name = 'sessions_idle_timeout'
                type = 'textbox'
                label = 'Session cleanup idle time (minutes)'
                tooltip = '0 disables session cleanup'
                value = 30
            }
        )
    }

    if ($TestConnection) {
        $connection_params = ConvertSystemParams -ConnectTest $ConnectionParams

        Get-ADObject-ADSI @connection_params -LDAPFilter '*' -ResultSetSize 1 1>$null
    }

    if ($Configuration) {
        $connection_params = ConvertSystemParams -ForestEnum $ConnectionParams

        $domains = (Get-ADForest-ADSI @connection_params).Domains

        # Sort on reverse name components
        $domains = $domains | Foreach-Object { $rn = $_.Name.Split('.'); [array]::Reverse($rn); $rn = $rn -join '.'; Add-Member -InputObject $_ -MemberType NoteProperty -Name ReverseName -Value $rn -Force -PassThru } | Sort-Object -Property ReverseName

        $dcs = @( $domains | ForEach-Object { @{ display = $_.Name; value = $_.RidRoleOwner.Name } } )

        @(
            @{
                name = 'domains'
                type = 'grid'
                label = 'Included domains'
                tooltip = 'Domains to include'
                table = @{
                    rows = $dcs
                    settings_grid = @{
                        selection = 'multiple'
                        key_column = 'value'
                        checkbox = $true
                        filter = $true
                        columns = @(
                            @{ name = 'display'; display_name = 'Domain' }
                        )
                    }
                }
                value = @($dcs | ForEach-Object { $_.value })
            }
            @{
                name = 'resultpagesize'
                type = 'textbox'
                label = 'Result page size'
                tooltip = 'Number of rows to retrieve per request; 0 for unlimited'
                value = '0'
            }
        )
    }

    Log info "Done"
}


#
# CRUD functions
#

$Properties = @{
    # PowerShell AD Module default properties
    default = @{
        acl = @(
            'Id'
            'PropagationFlags'
            'AccessControlType'
            'ObjectSid'
            'Identity'
            'IdentityName'
            'ObjectGUID'
            'ObjectClass'
            'InheritanceFlags'
            'ActiveDirectoryRights'
        )
        
        # https://social.technet.microsoft.com/wiki/contents/articles/12037.active-directory-get-aduser-default-and-extended-properties.aspx
        user = @(
            'distinguishedName'
            'Enabled'
            'givenName'
            'cn'
            'objectClass'
            'objectGUID'
            'path'
            'sAMAccountName'
            'objectSid'
            'sn'
            'userPrincipalName'
        )

        # https://social.technet.microsoft.com/wiki/contents/articles/12056.active-directory-get-adcomputer-default-and-extended-properties.aspx
        computer = @(
            'distinguishedName'
            'dNSHostName'
            'Enabled'
            'cn'
            'objectClass'
            'objectGUID'
            'path'
            'sAMAccountName'
            'objectSid'
            'userPrincipalName'
        )

        # https://social.technet.microsoft.com/wiki/contents/articles/12079.active-directory-get-adgroup-default-and-extended-properties.aspx
        group = @(
            'distinguishedName'
            'GroupCategory'
            'GroupScope'
            'cn'
            'objectClass'
            'objectGUID'
            'path'
            'sAMAccountName'
            'objectSid'
        )

        # https://social.technet.microsoft.com/wiki/contents/articles/12089.active-directory-get-adorganizationalunit-default-and-extended-properties.aspx
        organizationalUnit = @(
            'c'
            'distinguishedName'
            'gPLink'
            'l'
            'managedBy'
            'ou'
            'objectClass'
            'objectGUID'
            'path'
            'postalCode'
            'st'
            'streetAddress'
        )
    }

    # Non-native properties, introduced by a.o. PowerShell AD Module
    extra = @{
        acl = @(
        )
        user = @(
            'CannotChangePassword'
            'ChangePasswordAtLogon'
            'Enabled'
            'PasswordExpirationDate'
            'PasswordNeverExpires'
            'PasswordNotRequired'
            'path'
            'ProtectObjectFromDeletion'
        )

        computer = @(
            'CannotChangePassword'
            'ChangePasswordAtLogon'
            'Enabled'
            'PasswordExpirationDate'
            'PasswordNeverExpires'
            'PasswordNotRequired'
            'path'
            'ProtectObjectFromDeletion'
        )

        group = @(
            'GroupCategory'
            'GroupScope'
            'path'
            'ProtectObjectFromDeletion'
        )

        organizationalUnit = @(
            'path'
            'ProtectObjectFromDeletion'
        )
    }

    # Exclude, as current state of connector cannot process these
    exclude = @(
        'msds-memberOfTransitive'
        'msds-memberTransitive'
        'msds-tokenGroupNames'
        'msds-tokenGroupNamesGlobalAndUniversal'
        'msds-tokenGroupNamesNoGCAcceptable'
        'tokenGroups'
        'tokenGroupsGlobalAndUniversal'
        'tokenGroupsNoGCAcceptable'
        'tokenGroupsNoGCAcceptable'
    )

    # IDM-Selection based on practical experiences
    idm = @(
        'accountExpires'
        'c'
        'canonicalName'
        'co'
        'company'
        'department'
        'description'
        'employeeID'
        'employeeNumber'
        'extensionAttribute1'
        'extensionAttribute2'
        'extensionAttribute3'
        'extensionAttribute4'
        'extensionAttribute5'
        'extensionAttribute6'
        'extensionAttribute7'
        'extensionAttribute8'
        'extensionAttribute9'
        'extensionAttribute10'
        'extensionAttribute11'
        'extensionAttribute12'
        'extensionAttribute13'
        'extensionAttribute14'
        'extensionAttribute15'
        'givenName'
        'homeDirectory'
        'homeDrive'
        'homeMDB'
        'homePhone'
        'initials'
        'ipPhone'
        'l'
        'mail'
        'managedBy'
        'manager'
        'mailNickname'
        'mobile'
        'msExchHideFromAddressLists'
        'msExchRecipientTypeDetails'
        'msRTCSIP-UserEnabled'
        'msTSHomeDirectory'
        'msTSHomeDrive'
        'msTSProfilePath'
        'name'
        'objectSid'
        'ou'
        'pager'
        'physicalDeliveryOfficeName'
        'postalCode'
        'postOfficeBox'
        'profilePath'
        'proxyAddresses'
        'roomNumber'
        'scriptPath'
        'sn'
        'st'
        'streetAddress'
        'telephoneNumber'
        'title'
        'userPrincipalName'
        'wWWHomePage'
    )
}


function Idm-UserCreate {
    param (
        # Operations
        [switch] $GetMeta,
        # Parameters
        [string] $SystemParams,
        [string] $FunctionParams
    )

    Log info "-GetMeta=$GetMeta -SystemParams='$SystemParams' -FunctionParams='$FunctionParams'"

    if ($GetMeta) {
        #
        # Get meta data
        #

        @{
            semantics = 'create'
            parameters = @(
                @{ name = 'accountPassword';       allowance = 'optional'   }
                @{ name = 'adsPath';               allowance = 'prohibited' }
                @{ name = 'badPasswordTime';       allowance = 'prohibited' }
                @{ name = 'badPwdCount';           allowance = 'prohibited' }
                @{ name = 'canonicalName';         allowance = 'prohibited' }
                @{ name = 'cn';                    allowance = 'mandatory'  }
                @{ name = 'distinguishedName';     allowance = 'prohibited' }
                @{ name = 'dSCorePropagationData'; allowance = 'prohibited' }
                @{ name = 'instanceType';          allowance = 'prohibited' }
                @{ name = 'lastLogoff';            allowance = 'prohibited' }
                @{ name = 'lastLogon';             allowance = 'prohibited' }
                @{ name = 'logonCount';            allowance = 'prohibited' }
				@{ name = 'name';                  allowance = 'prohibited' }
				@{ name = 'objectClass';           allowance = 'prohibited' }
                @{ name = 'objectGUID';            allowance = 'prohibited' }
                @{ name = 'objectSid';             allowance = 'prohibited' }
                @{ name = 'path';                  allowance = 'mandatory'  }
                @{ name = 'pwdLastSet';            allowance = 'prohibited' }
                @{ name = 'uSNChanged';            allowance = 'prohibited' }
                @{ name = 'uSNCreated';            allowance = 'prohibited' }
                @{ name = 'whenChanged';           allowance = 'prohibited' }
                @{ name = 'whenCreated';           allowance = 'prohibited' }
               #@{ name = '*';                     allowance = 'optional'   }
            )
        }
    }
    else {
        #
        # Execute function
        #

        $connection_params = ConvertSystemParams -Create $SystemParams $FunctionParams
        $function_params   = ConvertFrom-Json2 $FunctionParams

        $properties = $function_params.Clone()

        # These are passed as mandatory parameters
        $properties.Remove('path')
        $properties.Remove('cn')

        LogIO info "New-ADUser-ADSI" -In @connection_params -Path $function_params.path -CN $function_params.cn -Properties $properties
            $rv = New-ADUser-ADSI @connection_params -PassThru -Path $function_params.path -CN $function_params.cn -Properties $properties
        LogIO info "New-ADUser-ADSI" -Out $rv

        $rv
    }

    Log info "Done"
}

function Idm-AclsRead {
    param (
        # Operations
        [switch] $GetMeta,
        # Parameters
        [string] $SystemParams,
        [string] $FunctionParams
    )

    Log info "-GetMeta=$GetMeta -SystemParams='$SystemParams' -FunctionParams='$FunctionParams'"

    if ($GetMeta) {
        #
        # Get meta data
        #

        Get-ClassMetaData -SystemParams $SystemParams -Class 'acl'
    }
    else {
        #
        # Execute function
        #

        $system_params   = ConvertSystemParams $SystemParams
        $function_params = ConvertFrom-Json2 $FunctionParams

        $filter = $function_params.filter

        if ($filter.length -eq 0) {
            # Avoid: Cannot validate argument on parameter 'Filter'. The argument is null or empty.
            # Provide an argument that is not null or empty, and then try the command again.
            $filter = '*'
        }

        $properties = $function_params.properties

        if ($properties.length -eq 0) {
            # Avoid: Cannot validate argument on parameter 'Properties'. The argument is null, empty,
            # or an element of the argument collection contains a null value. Supply a 
            $properties = $Global:Properties.default.acl
        }

        # Assure identity key is the first column
        $properties = @('objectGUID') + @($properties | Where-Object { $_ -ne 'objectGUID' })

        LogIO info "Get-ADObjectACL-ADSI" -In @system_params -LDAPFilter $filter -Properties $properties
        Get-ADObjectACL-ADSI @system_params -LDAPFilter $filter -Properties $properties
    }

    Log info "Done"
}

function Idm-AclCreate {
    param (
        # Operations
        [switch] $GetMeta,
        # Parameters
        [string] $SystemParams,
        [string] $FunctionParams
    )

    Log info "-GetMeta=$GetMeta -SystemParams='$SystemParams' -FunctionParams='$FunctionParams'"

    if ($GetMeta) {
        #
        # Get meta data
        #

        @{
            semantics = 'create'
            parameters = @(
                @{ name = 'id';               allowance = 'prohibited' }
                @{ name = 'PropagationFlags';       allowance = 'prohibited' }
                @{ name = 'AccessControlType';       allowance = 'mandatory' }
                @{ name = 'ObjectSID';       allowance = 'prohibited' }
                @{ name = 'Identity';       allowance = 'mandatory' }
                @{ name = 'IdentityName';       allowance = 'prohibited' }
                @{ name = 'ObjectGUID';       allowance = 'mandatory' }
                @{ name = 'ObjectClass';       allowance = 'prohibited' }
                @{ name = 'InheritanceFlags';       allowance = 'prohibited' }
                @{ name = 'ActiveDirectoryRights';           allowance = 'mandatory' }
               #@{ name = '*';                     allowance = 'optional'   }
            )
        }
    }
    else {
        #
        # Execute function
        #

        $connection_params = ConvertSystemParams -Create $SystemParams $FunctionParams
        $function_params   = ConvertFrom-Json2 $FunctionParams

        LogIO info "New-ADAcl-ADSI" -In @connection_params -ObjectGUID $function_params.ObjectGUID -Identity $function_params.Identity -AccessControlType $function_params.AccessControlType -ActiveDirectoryRights $function_params.ActiveDirectoryRights
            $rv = New-ADAcl-ADSI @connection_params -ObjectGUID $function_params.ObjectGUID -Identity $function_params.Identity -AccessControlType $function_params.AccessControlType -ActiveDirectoryRights $function_params.ActiveDirectoryRights
        LogIO info "New-ADAcl-ADSI" -Out $rv

        $rv
    }

    Log info "Done"
}

function Idm-AclDelete {
    param (
        # Operations
        [switch] $GetMeta,
        # Parameters
        [string] $SystemParams,
        [string] $FunctionParams
    )

    Log info "-GetMeta=$GetMeta -SystemParams='$SystemParams' -FunctionParams='$FunctionParams'"

    if ($GetMeta) {
        #
        # Get meta data
        #

        @{
            semantics = 'delete'
            parameters = @(
                @{ name = 'id';               allowance = 'mandatory' }
                @{ name = 'PropagationFlags';       allowance = 'prohibited' }
                @{ name = 'AccessControlType';       allowance = 'prohibited' }
                @{ name = 'ObjectSID';       allowance = 'prohibited' }
                @{ name = 'Identity';       allowance = 'mandatory' }
                @{ name = 'IdentityName';       allowance = 'prohibited' }
                @{ name = 'ObjectGUID';       allowance = 'mandatory' }
                @{ name = 'ObjectClass';       allowance = 'prohibited' }
                @{ name = 'InheritanceFlags';       allowance = 'prohibited' }
                @{ name = 'ActiveDirectoryRights';           allowance = 'mandatory' }
                @{ name = '*'; allowance = 'prohibited' }
            )
        }
    }
    else {
        #
        # Execute function
        #

        $connection_params = ConvertSystemParams -Create $SystemParams $FunctionParams
        $function_params   = ConvertFrom-Json2 $FunctionParams

        LogIO info "Remove-ADAcl-ADSI" -In @connection_params -id $function_params.id -Identity $function_params.Identity -ObjectGUID $function_params.ObjectGUID -ActiveDirectoryRights $function_params.ActiveDirectoryRights
            $rv = Remove-ADAcl-ADSI @connection_params -Identity $function_params.Identity -ObjectGUID $function_params.ObjectGUID -ActiveDirectoryRights $function_params.ActiveDirectoryRights
        LogIO info "Remove-ADAcl-ADSI" -Out $rv

        $rv
    }

    Log info "Done"
}

function Idm-UsersRead {
    param (
        # Operations
        [switch] $GetMeta,
        # Parameters
        [string] $SystemParams,
        [string] $FunctionParams
    )

    Log info "-GetMeta=$GetMeta -SystemParams='$SystemParams' -FunctionParams='$FunctionParams'"

    if ($GetMeta) {
        #
        # Get meta data
        #

        Get-ClassMetaData -SystemParams $SystemParams -Class 'user'
    }
    else {
        #
        # Execute function
        #

        $system_params   = ConvertSystemParams -Read $SystemParams $FunctionParams
        $function_params = ConvertFrom-Json2 $FunctionParams

        $filter = $function_params.filter

        if ($filter.length -eq 0) {
            # Avoid: Cannot validate argument on parameter 'Filter'. The argument is null or empty.
            # Provide an argument that is not null or empty, and then try the command again.
            $filter = '*'
        }

        $properties = $function_params.properties

        if ($properties.length -eq 0) {
            # Avoid: Cannot validate argument on parameter 'Properties'. The argument is null, empty,
            # or an element of the argument collection contains a null value. Supply a 
            $properties = $Global:Properties.default.user
        }

        # Assure identity key is the first column
        $properties = @('objectGUID') + @($properties | Where-Object { $_ -ne 'objectGUID' })

        LogIO info "Get-ADUser-ADSI" -In @system_params -LDAPFilter $filter -Properties $properties
        Get-ADUser-ADSI @system_params -LDAPFilter $filter -Properties $properties
    }

    Log info "Done"
}


function Idm-UserUpdate {
    param (
        # Operations
        [switch] $GetMeta,
        # Parameters
        [string] $SystemParams,
        [string] $FunctionParams
    )

    Log info "-GetMeta=$GetMeta -SystemParams='$SystemParams' -FunctionParams='$FunctionParams'"

    if ($GetMeta) {
        #
        # Get meta data
        #

        @{
            semantics = 'update'
            parameters = @(
                @{ name = 'accountPassword';       allowance = 'optional'   }
                @{ name = 'adsPath';               allowance = 'prohibited' }
                @{ name = 'badPasswordTime';       allowance = 'prohibited' }
                @{ name = 'badPwdCount';           allowance = 'prohibited' }
				@{ name = 'canonicalName';         allowance = 'prohibited' }
                @{ name = 'distinguishedName';     allowance = 'optional'   }
                @{ name = 'dSCorePropagationData'; allowance = 'prohibited' }
                @{ name = 'instanceType';          allowance = 'prohibited' }
                @{ name = 'lastLogoff';            allowance = 'prohibited' }
                @{ name = 'lastLogon';             allowance = 'prohibited' }
                @{ name = 'logonCount';            allowance = 'prohibited' }
				@{ name = 'name';                  allowance = 'prohibited' }
                @{ name = 'objectClass';           allowance = 'prohibited' }
                @{ name = 'objectGUID';            allowance = 'mandatory'  }
                @{ name = 'objectSid';             allowance = 'prohibited' }
                @{ name = 'pwdLastSet';            allowance = 'prohibited' }
                @{ name = 'uSNChanged';            allowance = 'prohibited' }
                @{ name = 'uSNCreated';            allowance = 'prohibited' }
                @{ name = 'whenChanged';           allowance = 'prohibited' }
                @{ name = 'whenCreated';           allowance = 'prohibited' }
               #@{ name = '*';                     allowance = 'optional'   }
            )
        }
    }
    else {
        #
        # Execute function
        #

        $connection_params = ConvertSystemParams -Update $SystemParams $FunctionParams
        $function_params   = ConvertFrom-Json2 $FunctionParams

        $properties = $function_params.Clone()

        # These are passed as mandatory parameters
        $properties.Remove('objectGUID')
        $properties.Remove('distinguishedName')

        LogIO info "Set-ADUser-ADSI" -In @connection_params -Identity $function_params.objectGUID -Properties $properties
            $rv = Set-ADUser-ADSI @connection_params -PassThru -Identity $function_params.objectGUID -Properties $properties
        LogIO info "Set-ADUser-ADSI" -Out $rv

        $rv
    }

    Log info "Done"
}


function Idm-UserDelete {
    param (
        # Operations
        [switch] $GetMeta,
        # Parameters
        [string] $SystemParams,
        [string] $FunctionParams
    )

    Log info "-GetMeta=$GetMeta -SystemParams='$SystemParams' -FunctionParams='$FunctionParams'"

    if ($GetMeta) {
        #
        # Get meta data
        #

        @{
            semantics = 'delete'
            parameters = @(
                @{ name = 'distinguishedName'; allowance = 'optional'   }
                @{ name = 'objectGUID';        allowance = 'mandatory'  }
                @{ name = '*';                 allowance = 'prohibited' }
            )
        }
    }
    else {
        #
        # Execute function
        #

        $connection_params = ConvertSystemParams -Delete $SystemParams $FunctionParams
        $function_params   = ConvertFrom-Json2 $FunctionParams

        LogIO info "Remove-ADUser-ADSI" -In @connection_params -Identity $function_params.objectGUID
            $rv = Remove-ADUser-ADSI @connection_params -PassThru -Identity $function_params.objectGUID
        LogIO info "Remove-ADUser-ADSI" -Out $rv

        $rv
    }

    Log info "Done"
}


function Idm-ComputerCreate {
    param (
        # Operations
        [switch] $GetMeta,
        # Parameters
        [string] $SystemParams,
        [string] $FunctionParams
    )

    Log info "-GetMeta=$GetMeta -SystemParams='$SystemParams' -FunctionParams='$FunctionParams'"

    if ($GetMeta) {
        #
        # Get meta data
        #

        @{
            semantics = 'create'
            parameters = @(
                @{ name = 'accountPassword';       allowance = 'optional'   }
                @{ name = 'adsPath';               allowance = 'prohibited' }
                @{ name = 'badPasswordTime';       allowance = 'prohibited' }
                @{ name = 'badPwdCount';           allowance = 'prohibited' }
				@{ name = 'canonicalName';         allowance = 'prohibited' }
                @{ name = 'cn';                    allowance = 'mandatory'  }
                @{ name = 'distinguishedName';     allowance = 'prohibited' }
                @{ name = 'dSCorePropagationData'; allowance = 'prohibited' }
                @{ name = 'instanceType';          allowance = 'prohibited' }
                @{ name = 'lastLogoff';            allowance = 'prohibited' }
                @{ name = 'lastLogon';             allowance = 'prohibited' }
                @{ name = 'logonCount';            allowance = 'prohibited' }
				@{ name = 'name';                  allowance = 'prohibited' }
                @{ name = 'objectClass';           allowance = 'prohibited' }
                @{ name = 'objectGUID';            allowance = 'prohibited' }
                @{ name = 'objectSid';             allowance = 'prohibited' }
                @{ name = 'path';                  allowance = 'mandatory'  }
                @{ name = 'pwdLastSet';            allowance = 'prohibited' }
                @{ name = 'uSNChanged';            allowance = 'prohibited' }
                @{ name = 'uSNCreated';            allowance = 'prohibited' }
                @{ name = 'whenChanged';           allowance = 'prohibited' }
                @{ name = 'whenCreated';           allowance = 'prohibited' }
               #@{ name = '*';                     allowance = 'optional'   }
            )
        }
    }
    else {
        #
        # Execute function
        #

        $connection_params = ConvertSystemParams -Create $SystemParams $FunctionParams
        $function_params   = ConvertFrom-Json2 $FunctionParams

        $properties = $function_params.Clone()

        # These are passed as mandatory parameters
        $properties.Remove('path')
        $properties.Remove('cn')

        LogIO info "New-ADComputer-ADSI" -In @connection_params -Path $function_params.path -CN $function_params.cn -Properties $properties
            $rv = New-ADComputer-ADSI @connection_params -PassThru -Path $function_params.path -CN $function_params.cn -Properties $properties
        LogIO info "New-ADComputer-ADSI" -Out $rv

        $rv
    }

    Log info "Done"
}


function Idm-ComputersRead {
    param (
        # Operations
        [switch] $GetMeta,
        # Parameters
        [string] $SystemParams,
        [string] $FunctionParams
    )

    Log info "-GetMeta=$GetMeta -SystemParams='$SystemParams' -FunctionParams='$FunctionParams'"

    if ($GetMeta) {
        #
        # Get meta data
        #

        Get-ClassMetaData -SystemParams $SystemParams -Class 'computer'
    }
    else {
        #
        # Execute function
        #

        $system_params   = ConvertSystemParams -Read $SystemParams $FunctionParams
        $function_params = ConvertFrom-Json2 $FunctionParams

        $filter = $function_params.filter

        if ($filter.length -eq 0) {
            # Avoid: Cannot validate argument on parameter 'Filter'. The argument is null or empty.
            # Provide an argument that is not null or empty, and then try the command again.
            $filter = '*'
        }

        $properties = $function_params.properties

        if ($properties.length -eq 0) {
            # Avoid: Cannot validate argument on parameter 'Properties'. The argument is null, empty,
            # or an element of the argument collection contains a null value. Supply a 
            $properties = $Global:Properties.default.computer
        }

        # Assure identity key is the first column
        $properties = @('objectGUID') + @($properties | Where-Object { $_ -ne 'objectGUID' })

        LogIO info "Get-ADComputer-ADSI" -In @system_params -LDAPFilter $filter -Properties $properties
        Get-ADComputer-ADSI @system_params -LDAPFilter $filter -Properties $properties
    }

    Log info "Done"
}


function Idm-ComputerUpdate {
    param (
        # Operations
        [switch] $GetMeta,
        # Parameters
        [string] $SystemParams,
        [string] $FunctionParams
    )

    Log info "-GetMeta=$GetMeta -SystemParams='$SystemParams' -FunctionParams='$FunctionParams'"

    if ($GetMeta) {
        #
        # Get meta data
        #

        @{
            semantics = 'update'
            parameters = @(
                @{ name = 'accountPassword';       allowance = 'optional'   }
                @{ name = 'adsPath';               allowance = 'prohibited' }
                @{ name = 'badPasswordTime';       allowance = 'prohibited' }
                @{ name = 'badPwdCount';           allowance = 'prohibited' }
				@{ name = 'canonicalName';         allowance = 'prohibited' }
                @{ name = 'distinguishedName';     allowance = 'optional'   }
                @{ name = 'dSCorePropagationData'; allowance = 'prohibited' }
                @{ name = 'instanceType';          allowance = 'prohibited' }
                @{ name = 'lastLogoff';            allowance = 'prohibited' }
                @{ name = 'lastLogon';             allowance = 'prohibited' }
                @{ name = 'logonCount';            allowance = 'prohibited' }
				@{ name = 'name';                  allowance = 'prohibited' }
                @{ name = 'objectClass';           allowance = 'prohibited' }
                @{ name = 'objectGUID';            allowance = 'mandatory'  }
                @{ name = 'objectSid';             allowance = 'prohibited' }
                @{ name = 'pwdLastSet';            allowance = 'prohibited' }
                @{ name = 'uSNChanged';            allowance = 'prohibited' }
                @{ name = 'uSNCreated';            allowance = 'prohibited' }
                @{ name = 'whenChanged';           allowance = 'prohibited' }
                @{ name = 'whenCreated';           allowance = 'prohibited' }
               #@{ name = '*';                     allowance = 'optional'   }
            )
        }
    }
    else {
        #
        # Execute function
        #

        $connection_params = ConvertSystemParams -Update $SystemParams $FunctionParams
        $function_params   = ConvertFrom-Json2 $FunctionParams

        $properties = $function_params.Clone()

        # These are passed as mandatory parameters
        $properties.Remove('objectGUID')
        $properties.Remove('distinguishedName')

        LogIO info "Set-ADComputer-ADSI" -In @connection_params -Identity $function_params.objectGUID -Properties $properties
            $rv = Set-ADComputer-ADSI @connection_params -PassThru -Identity $function_params.objectGUID -Properties $properties
        LogIO info "Set-ADComputer-ADSI" -Out $rv

        $rv
    }

    Log info "Done"
}


function Idm-ComputerDelete {
    param (
        # Operations
        [switch] $GetMeta,
        # Parameters
        [string] $SystemParams,
        [string] $FunctionParams
    )

    Log info "-GetMeta=$GetMeta -SystemParams='$SystemParams' -FunctionParams='$FunctionParams'"

    if ($GetMeta) {
        #
        # Get meta data
        #

        @{
            semantics = 'delete'
            parameters = @(
                @{ name = 'distinguishedName'; allowance = 'optional'   }
                @{ name = 'objectGUID';        allowance = 'mandatory'  }
                @{ name = '*';                 allowance = 'prohibited' }
            )
        }
    }
    else {
        #
        # Execute function
        #

        $connection_params = ConvertSystemParams -Delete $SystemParams $FunctionParams
        $function_params   = ConvertFrom-Json2 $FunctionParams

        LogIO info "Remove-ADComputer-ADSI" -In @connection_params -Identity $function_params.objectGUID
            $rv = Remove-ADComputer-ADSI @connection_params -PassThru -Identity $function_params.objectGUID
        LogIO info "Remove-ADComputer-ADSI" -Out $rv

        $rv
    }

    Log info "Done"
}


function Idm-GroupCreate {
    param (
        # Operations
        [switch] $GetMeta,
        # Parameters
        [string] $SystemParams,
        [string] $FunctionParams
    )

    Log info "-GetMeta=$GetMeta -SystemParams='$SystemParams' -FunctionParams='$FunctionParams'"

    if ($GetMeta) {
        #
        # Get meta data
        #

        @{
            semantics = 'create'
            parameters = @(
                @{ name = 'adsPath';               allowance = 'prohibited' }
                @{ name = 'cn';                    allowance = 'mandatory'  }
                @{ name = 'distinguishedName';     allowance = 'prohibited' }
                @{ name = 'dSCorePropagationData'; allowance = 'prohibited' }
                @{ name = 'instanceType';          allowance = 'prohibited' }
                @{ name = 'objectClass';           allowance = 'prohibited' }
                @{ name = 'objectGUID';            allowance = 'prohibited' }
                @{ name = 'objectSid';             allowance = 'prohibited' }
                @{ name = 'path';                  allowance = 'mandatory'  }
                @{ name = 'uSNChanged';            allowance = 'prohibited' }
                @{ name = 'uSNCreated';            allowance = 'prohibited' }
                @{ name = 'whenChanged';           allowance = 'prohibited' }
                @{ name = 'whenCreated';           allowance = 'prohibited' }
               #@{ name = '*';                     allowance = 'optional'   }
            )
        }
    }
    else {
        #
        # Execute function
        #

        $connection_params = ConvertSystemParams -Create $SystemParams $FunctionParams
        $function_params   = ConvertFrom-Json2 $FunctionParams

        $properties = $function_params.Clone()

        # These are passed as mandatory parameters
        $properties.Remove('path')
        $properties.Remove('cn')

        LogIO info "New-ADGroup-ADSI" -In @connection_params -Path $function_params.path -CN $function_params.cn -Properties $properties
            $rv = New-ADGroup-ADSI @connection_params -PassThru -Path $function_params.path -CN $function_params.cn -Properties $properties
        LogIO info "New-ADGroup-ADSI" -Out $rv

        $rv
    }

    Log info "Done"
}


function Idm-GroupsRead {
    param (
        # Operations
        [switch] $GetMeta,
        # Parameters
        [string] $SystemParams,
        [string] $FunctionParams
    )

    Log info "-GetMeta=$GetMeta -SystemParams='$SystemParams' -FunctionParams='$FunctionParams'"

    if ($GetMeta) {
        #
        # Get meta data
        #

        Get-ClassMetaData -SystemParams $SystemParams -Class 'group'
    }
    else {
        #
        # Execute function
        #

        $system_params   = ConvertSystemParams -Read $SystemParams $FunctionParams
        $function_params = ConvertFrom-Json2 $FunctionParams

        $filter = $function_params.filter

        # Store filter for usage by other Idm functions
        $Global:Idm_GroupsRead_Filter = $filter

        if ($filter.length -eq 0) {
            # Avoid: Cannot validate argument on parameter 'Filter'. The argument is null or empty.
            # Provide an argument that is not null or empty, and then try the command again.
            $filter = '*'
        }

        $properties = $function_params.properties

        if ($properties.length -eq 0) {
            # Avoid: Cannot validate argument on parameter 'Properties'. The argument is null, empty,
            # or an element of the argument collection contains a null value. Supply a 
            $properties = $Global:Properties.default.group
        }

        # Assure identity key is the first column
        $properties = @('objectGUID') + @($properties | Where-Object { $_ -ne 'objectGUID' })

        LogIO info "Get-ADGroup-ADSI" -In @system_params -LDAPFilter $filter -Properties $properties
        Get-ADGroup-ADSI @system_params -LDAPFilter $filter -Properties $properties
    }

    Log info "Done"
}


function Idm-GroupUpdate {
    param (
        # Operations
        [switch] $GetMeta,
        # Parameters
        [string] $SystemParams,
        [string] $FunctionParams
    )

    Log info "-GetMeta=$GetMeta -SystemParams='$SystemParams' -FunctionParams='$FunctionParams'"

    if ($GetMeta) {
        #
        # Get meta data
        #

        @{
            semantics = 'update'
            parameters = @(
                @{ name = 'adsPath';               allowance = 'prohibited' }
                @{ name = 'distinguishedName';     allowance = 'optional'   }
                @{ name = 'dSCorePropagationData'; allowance = 'prohibited' }
                @{ name = 'instanceType';          allowance = 'prohibited' }
                @{ name = 'objectClass';           allowance = 'prohibited' }
                @{ name = 'objectGUID';            allowance = 'mandatory'  }
                @{ name = 'objectSid';             allowance = 'prohibited' }
                @{ name = 'uSNChanged';            allowance = 'prohibited' }
                @{ name = 'uSNCreated';            allowance = 'prohibited' }
                @{ name = 'whenChanged';           allowance = 'prohibited' }
                @{ name = 'whenCreated';           allowance = 'prohibited' }
               #@{ name = '*';                     allowance = 'optional'   }
            )
        }
    }
    else {
        #
        # Execute function
        #

        $connection_params = ConvertSystemParams -Update $SystemParams $FunctionParams
        $function_params   = ConvertFrom-Json2 $FunctionParams

        $properties = $function_params.Clone()

        # These are passed as mandatory parameters
        $properties.Remove('objectGUID')
        $properties.Remove('distinguishedName')

        LogIO info "Set-ADGroup-ADSI" -In @connection_params -Identity $function_params.objectGUID -Properties $properties
            $rv = Set-ADGroup-ADSI @connection_params -PassThru -Identity $function_params.objectGUID -Properties $properties
        LogIO info "Set-ADGroup-ADSI" -Out $rv

        $rv
    }

    Log info "Done"
}


function Idm-GroupDelete {
    param (
        # Operations
        [switch] $GetMeta,
        # Parameters
        [string] $SystemParams,
        [string] $FunctionParams
    )

    Log info "-GetMeta=$GetMeta -SystemParams='$SystemParams' -FunctionParams='$FunctionParams'"

    if ($GetMeta) {
        #
        # Get meta data
        #

        @{
            semantics = 'delete'
            parameters = @(
                @{ name = 'distinguishedName'; allowance = 'optional'   }
                @{ name = 'objectGUID';        allowance = 'mandatory'  }
                @{ name = '*';                 allowance = 'prohibited' }
            )
        }
    }
    else {
        #
        # Execute function
        #

        $connection_params = ConvertSystemParams -Delete $SystemParams $FunctionParams
        $function_params   = ConvertFrom-Json2 $FunctionParams

        LogIO info "Remove-ADGroup-ADSI" -In @connection_params -Identity $function_params.objectGUID
            $rv = Remove-ADGroup-ADSI @connection_params -PassThru -Identity $function_params.objectGUID
        LogIO info "Remove-ADGroup-ADSI" -Out $rv

        $rv
    }

    Log info "Done"
}


function Idm-MembershipCreate {
    param (
        # Operations
        [switch] $GetMeta,
        # Parameters
        [string] $SystemParams,
        [string] $FunctionParams
    )

    Log info "-GetMeta=$GetMeta -SystemParams='$SystemParams' -FunctionParams='$FunctionParams'"

    if ($GetMeta) {
        #
        # Get meta data
        #

        @{
            semantics = 'create'
            parameters = @(
                @{ name = "group";  allowance = 'mandatory'  }
                @{ name = "member"; allowance = 'mandatory'  }
                @{ name = '*';      allowance = 'prohibited' }
            )
        }
    }
    else {
        #
        # Execute function
        #

        $connection_params = ConvertSystemParams -Update $SystemParams $FunctionParams
        $function_params   = ConvertFrom-Json2 $FunctionParams

        LogIO info "Set-ADGroupMember-ADSI" -In @connection_params -Identity $function_params.group -MembersAdd @($function_params.member) -MembersRemove @()
            $rv = Set-ADGroupMember-ADSI @connection_params -Identity $function_params.group -MembersAdd @($function_params.member) -MembersRemove @()
        LogIO info "Set-ADGroupMember-ADSI" -Out $rv

        $rv
    }

    Log info "Done"
}


function Idm-MembershipsRead {
    param (
        # Operations
        [switch] $GetMeta,
        # Parameters
        [string] $SystemParams,
        [string] $FunctionParams
    )

    Log info "-GetMeta=$GetMeta -SystemParams='$SystemParams' -FunctionParams='$FunctionParams'"

    if ($GetMeta) {
        #
        # Get meta data
        #

        @()
    }
    else {
        #
        # Execute function
        #

        $system_params = ConvertSystemParams -Read $SystemParams $FunctionParams
        $function_params = ConvertFrom-Json2 $FunctionParams

        $filter = if ($function_params.filter) {
            $function_params.filter
        }
        else {
            # Use same filter as Idm-GroupsRead
            $filter = $Global:Idm_GroupsRead_Filter
        }

        if ($filter.length -eq 0) {
            # Avoid: Cannot validate argument on parameter 'Filter'. The argument is null or empty.
            # Provide an argument that is not null or empty, and then try the command again.
            $filter = '*'
        }

        $properties = @('objectGUID', 'member')

        # For recursive implementation, see:
        # -> https://www.petri.com/managing-active-directory-groups-adsi-powershell

        LogIO info "Get-ADGroup-ADSI" -In @system_params -LDAPFilter $filter -Properties $properties

        Get-ADGroup-ADSI @system_params -LDAPFilter $filter -Properties $properties | ForEach-Object {
            $group = $_.objectGUID
            $_.member | ForEach-Object {
                [PSCustomObject]@{ "group" = $group; "member" = $_.ToString() }
            }
        }
    }

    Log info "Done"
}


function Idm-MembershipsUpdate {
    param (
        # Operations
        [switch] $GetMeta,
        # Parameters
        [string] $SystemParams,
        [string] $FunctionParams
    )

    Log info "-GetMeta=$GetMeta -SystemParams='$SystemParams' -FunctionParams='$FunctionParams'"

    if ($GetMeta) {
        #
        # Get meta data
        #

        @{
            semantics = 'memberships-update'
            parentTable = 'Groups'
        #    parameters = @(
        #        @{ name = 'group';  allowance = 'mandatory'  }
        #        @{ name = 'add';    allowance = 'mandatory'  }
        #        @{ name = 'remove'; allowance = 'mandatory'  }
        #        @{ name = '*';      allowance = 'prohibited' }
        #    )
        }
    }
    else {
        #
        # Execute function
        #

        $connection_params = ConvertSystemParams -Update $SystemParams $FunctionParams
        $function_params   = ConvertFrom-Json2 $FunctionParams

        LogIO info "Set-ADGroupMember-ADSI" -In @connection_params -Identity $function_params.group -MembersAdd @($function_params.add) -MembersRemove @($function_params.remove)
            $rv = Set-ADGroupMember-ADSI @connection_params -Identity $function_params.group -MembersAdd @($function_params.add) -MembersRemove @($function_params.remove)
        LogIO info "Set-ADGroupMember-ADSI" -Out $rv

        $rv
    }

    Log info "Done"
}


function Idm-MembershipDelete {
    param (
        # Operations
        [switch] $GetMeta,
        # Parameters
        [string] $SystemParams,
        [string] $FunctionParams
    )

    Log info "-GetMeta=$GetMeta -SystemParams='$SystemParams' -FunctionParams='$FunctionParams'"

    if ($GetMeta) {
        #
        # Get meta data
        #

        @{
            semantics = 'delete'
            parameters = @(
                @{ name = "group";  allowance = 'mandatory'  }
                @{ name = "member"; allowance = 'mandatory'  }
                @{ name = '*';      allowance = 'prohibited' }
            )
        }
    }
    else {
        #
        # Execute function
        #

        $connection_params = ConvertSystemParams -Update $SystemParams $FunctionParams
        $function_params   = ConvertFrom-Json2 $FunctionParams

        LogIO info "Set-ADGroupMember-ADSI" -In @connection_params -Identity $function_params.group -MembersAdd @() -MembersRemove @($function_params.member)
            $rv = Set-ADGroupMember-ADSI @connection_params -Identity $function_params.group -MembersAdd @() -MembersRemove @($function_params.member)
        LogIO info "Set-ADGroupMember-ADSI" -Out $rv

        $rv
    }

    Log info "Done"
}


function Idm-OrganizationalUnitCreate {
    param (
        # Operations
        [switch] $GetMeta,
        # Parameters
        [string] $SystemParams,
        [string] $FunctionParams
    )

    Log info "-GetMeta=$GetMeta -SystemParams='$SystemParams' -FunctionParams='$FunctionParams'"

    if ($GetMeta) {
        #
        # Get meta data
        #

        @{
            semantics = 'create'
            parameters = @(
                @{ name = 'adsPath';               allowance = 'prohibited' }
                @{ name = 'distinguishedName';     allowance = 'prohibited' }
                @{ name = 'dSCorePropagationData'; allowance = 'prohibited' }
                @{ name = 'instanceType';          allowance = 'prohibited' }
                @{ name = 'objectClass';           allowance = 'prohibited' }
                @{ name = 'objectGUID';            allowance = 'prohibited' }
                @{ name = 'ou';                    allowance = 'mandatory'  }
                @{ name = 'path';                  allowance = 'mandatory'  }
                @{ name = 'uSNChanged';            allowance = 'prohibited' }
                @{ name = 'uSNCreated';            allowance = 'prohibited' }
                @{ name = 'whenChanged';           allowance = 'prohibited' }
                @{ name = 'whenCreated';           allowance = 'prohibited' }
               #@{ name = '*';                     allowance = 'optional'   }
            )
        }
    }
    else {
        #
        # Execute function
        #

        $connection_params = ConvertSystemParams -Create $SystemParams $FunctionParams
        $function_params   = ConvertFrom-Json2 $FunctionParams

        $properties = $function_params.Clone()

        # These are passed as mandatory parameters
        $properties.Remove('path')
        $properties.Remove('ou')

        LogIO info "New-ADOrganizationalUnit-ADSI" -In @connection_params -Path $function_params.path -OU_ $function_params.ou -Properties $properties
            $rv = New-ADOrganizationalUnit-ADSI @connection_params -PassThru -Path $function_params.path -OU $function_params.ou -Properties $properties
        LogIO info "New-ADOrganizationalUnit-ADSI" -Out $rv

        $rv
    }

    Log info "Done"
}


function Idm-OrganizationalUnitsRead {
    param (
        # Operations
        [switch] $GetMeta,
        # Parameters
        [string] $SystemParams,
        [string] $FunctionParams
    )

    Log info "-GetMeta=$GetMeta -SystemParams='$SystemParams' -FunctionParams='$FunctionParams'"

    if ($GetMeta) {
        #
        # Get meta data
        #

        Get-ClassMetaData -SystemParams $SystemParams -Class 'organizationalUnit'
    }
    else {
        #
        # Execute function
        #

        $system_params   = ConvertSystemParams -Read $SystemParams $FunctionParams
        $function_params = ConvertFrom-Json2 $FunctionParams

        if ($function_params.include_container_objects) {
            $system_params.IncludeContainers = $true
        }

        $filter = $function_params.filter

        if ($filter.length -eq 0) {
            # Avoid: Cannot validate argument on parameter 'Filter'. The argument is null or empty.
            # Provide an argument that is not null or empty, and then try the command again.
            $filter = '*'
        }

        $properties = $function_params.properties

        if ($properties.length -eq 0) {
            # Avoid: Cannot validate argument on parameter 'Properties'. The argument is null, empty,
            # or an element of the argument collection contains a null value. Supply a 
            $properties = $Global:Properties.default.organizationalUnit
        }

        # Assure identity key is the first column
        $properties = @('objectGUID') + @($properties | Where-Object { $_ -ne 'objectGUID' })

        LogIO info "Get-ADOrganizationalUnit-ADSI" -In @system_params -LDAPFilter $filter -Properties $properties
        Get-ADOrganizationalUnit-ADSI @system_params -LDAPFilter $filter -Properties $properties
    }

    Log info "Done"
}


function Idm-OrganizationalUnitUpdate {
    param (
        # Operations
        [switch] $GetMeta,
        # Parameters
        [string] $SystemParams,
        [string] $FunctionParams
    )

    Log info "-GetMeta=$GetMeta -SystemParams='$SystemParams' -FunctionParams='$FunctionParams'"

    if ($GetMeta) {
        #
        # Get meta data
        #

        @{
            semantics = 'update'
            parameters = @(
                @{ name = 'adsPath';               allowance = 'prohibited' }
                @{ name = 'distinguishedName';     allowance = 'optional'   }
                @{ name = 'dSCorePropagationData'; allowance = 'prohibited' }
                @{ name = 'instanceType';          allowance = 'prohibited' }
                @{ name = 'objectClass';           allowance = 'prohibited' }
                @{ name = 'objectGUID';            allowance = 'mandatory'  }
                @{ name = 'ou';                    allowance = 'prohibited' }
                @{ name = 'uSNChanged';            allowance = 'prohibited' }
                @{ name = 'uSNCreated';            allowance = 'prohibited' }
                @{ name = 'whenChanged';           allowance = 'prohibited' }
                @{ name = 'whenCreated';           allowance = 'prohibited' }
               #@{ name = '*';                     allowance = 'optional'   }
            )
        }
    }
    else {
        #
        # Execute function
        #

        $connection_params = ConvertSystemParams -Update $SystemParams $FunctionParams
        $function_params   = ConvertFrom-Json2 $FunctionParams

        $properties = $function_params.Clone()

        # These are passed as mandatory parameters
        $properties.Remove('objectGUID')
        $properties.Remove('distinguishedName')

        LogIO info "Set-ADOrganizationalUnit-ADSI" -In @connection_params -Identity $function_params.objectGUID -Properties $properties
            $rv = Set-ADOrganizationalUnit-ADSI @connection_params -PassThru -Identity $function_params.objectGUID -Properties $properties
        LogIO info "Set-ADOrganizationalUnit-ADSI" -Out $rv

        $rv
    }

    Log info "Done"
}


function Idm-OrganizationalUnitDelete {
    param (
        # Operations
        [switch] $GetMeta,
        # Parameters
        [string] $SystemParams,
        [string] $FunctionParams
    )

    Log info "-GetMeta=$GetMeta -SystemParams='$SystemParams' -FunctionParams='$FunctionParams'"

    if ($GetMeta) {
        #
        # Get meta data
        #

        @{
            semantics = 'delete'
            parameters = @(
                @{ name = 'distinguishedName'; allowance = 'optional'   }
                @{ name = 'objectGUID';        allowance = 'mandatory'  }
                @{ name = '*';                 allowance = 'prohibited' }
            )
        }
    }
    else {
        #
        # Execute function
        #

        $connection_params = ConvertSystemParams -Delete $SystemParams $FunctionParams
        $function_params   = ConvertFrom-Json2 $FunctionParams

        LogIO info "Remove-ADOrganizationalUnit-ADSI" -In @connection_params -Identity $function_params.objectGUID
            $rv = Remove-ADOrganizationalUnit-ADSI @connection_params -PassThru -Identity $function_params.objectGUID
        LogIO info "Remove-ADOrganizationalUnit-ADSI" -Out $rv

        $rv
    }

    Log info "Done"
}


#
# Helper functions
#

function ConvertSystemParams {
    param (
        [switch] $Create,
        [switch] $Read,
        [switch] $Update,
        [switch] $Delete,
        [switch] $ClassMeta,
        [switch] $ConnectTest,
        [switch] $ForestEnum,
        [string] $SystemParams,
        [string] $FunctionParams
    )

    $system_params = ConvertFrom-Json2 $SystemParams

    $out_params = @{}

    if (! $system_params.use_svc_account_creds) {
        $out_params.Credential = New-Object System.Management.Automation.PSCredential($system_params.username, (ConvertTo-SecureString $system_params.password -AsPlainText -Force))
    }

    if ($Create) {
        $function_params = ConvertFrom-Json2 $FunctionParams

        $out_params.Server = Get-DomainFromDN $function_params.path
    }

    if ($Read) {
        $out_params.Servers = $system_params.domains

        if ($system_params.resultpagesize -and $system_params.resultpagesize -ne '0') {
            $out_params.ResultPageSize = $system_params.resultpagesize
        }
    }

    if ($Update -or $Delete) {
        $function_params = ConvertFrom-Json2 $FunctionParams

        if ($function_params.distinguishedName) {
            $out_params.Server = Get-DomainFromDN $function_params.distinguishedName
        }
        else {
            $object_guid = if ($function_params.objectGUID) { $function_params.objectGUID } else { $function_params.group }

            $dirent = Get-DirectoryServicesDirectoryEntry $out_params.Credential (Make-LDAPPath -GC $system_params.root_domain $object_guid)
            if ($dirent.Properties.Count -eq 0) { $dirent.RefreshCache() }
            $out_params.Server = Get-DomainFromDN $dirent.Properties['distinguishedName']
        }
    }

    if ($ClassMeta) {
        $out_params.Server = (Get-ADForest-ADSI $out_params.Credential $system_params.root_domain).SchemaRoleOwner.Name
    }

    if ($ConnectTest) {
        if ($system_params.root_domain) {
            $out_params.Servers = @($system_params.root_domain)
        }
    }

    if ($ForestEnum) {
        if ($system_params.root_domain) {
            $out_params.Identity = $system_params.root_domain
        }
    }

    return $out_params
}


function Get-ADAttributes {
    #
    # Derived from: https://www.easy365manager.com/how-to-get-all-active-directory-user-object-attributes
    #
    # Other suggestion: https://www.neroblanco.co.uk/2017/09/get-possible-ad-attributes-user-group
    #

    param (
        [Parameter(Mandatory)] [String] $Class,
        [PSCredential] $Credential,
        [String] $Server
    )

    $connection_params = @{}

    if ($Credential) { $connection_params.Credential = $Credential }
    if ($Server)     { $connection_params.Server     = $Server }

    # Retrieve the class and any parent classes
    $class_name = $Class
    $class_list = [System.Collections.ArrayList]@()

    while ($true) {
        $class_obj = Get-ADObject-ADSI @connection_params -SearchBase (Get-ADRootDSE-ADSI @connection_params).SchemaNamingContext.ToString() -LDAPFilter "(ldapDisplayName=$class_name)" -Properties AuxiliaryClass, SystemAuxiliaryClass, mayContain, mustContain, systemMayContain, systemMustContain, subClassOf, ldapDisplayName
        $null = $class_list.Add($class_obj)

        if ($class_obj.subClassOf -eq $class_obj.ldapDisplayName) { break }

        $class_name = $class_obj.subClassOf
    }

    # For all classes in list, get auxiliary class attributes and direct attributes
    $attributes_list = [System.Collections.ArrayList]@()

    $class_list | ForEach-Object {
        $aux = @()
        $sys_aux = @()

        # Get Auxiliary class attributes
        if ($_.AuxiliaryClass) {
            $aux = $_.AuxiliaryClass | ForEach-Object { Get-ADObject-ADSI @connection_params -SearchBase (Get-ADRootDSE-ADSI @connection_params).SchemaNamingContext.ToString() -LDAPFilter "(ldapDisplayName=$_)" -Properties mayContain, mustContain, systemMayContain, systemMustContain } |
                Select-Object @{n = "Attributes"; e = { $_.mayContain + $_.mustContain + $_.systemMaycontain + $_.systemMustContain } } |
                Select-Object -ExpandProperty Attributes
        }

        # Get SystemAuxiliary class attributes
        if ($_.SystemAuxiliaryClass) {
            $sys_aux = $_.SystemAuxiliaryClass | ForEach-Object { Get-ADObject-ADSI @connection_params -SearchBase (Get-ADRootDSE-ADSI @connection_params).SchemaNamingContext.ToString() -LDAPFilter "(ldapDisplayName=$_)" -Properties MayContain, SystemMayContain, systemMustContain } |
                Select-Object @{n = "Attributes"; e = { $_.mayContain + $_.mustContain + $_.systemMaycontain + $_.systemMustContain } } |
                Select-Object -ExpandProperty Attributes
        }

        # Get direct attributes
        $attributes_list += $aux + $sys_aux + $_.mayContain + $_.mustContain + $_.systemMayContain + $_.systemMustContain
    }

    $attributes_list | Sort-Object -Unique
}


function Get-ClassMetaData {
    param (
        [string] $SystemParams,
        [string] $Class
    )

    Log info "Getting attribute schema of class '$Class'"

    $connection_params = ConvertSystemParams -ClassMeta $SystemParams

    if($Class -eq 'acl') {
        $all_properties += $Global:Properties.default.$Class
    } else {
        $all_properties  = @( Get-ADAttributes @connection_params -Class $Class )
    }
	
    $all_properties += $Global:Properties.extra.$Class

    if ($Class -eq 'user') {
        $all_properties += $Global:TerminalServicesAttributes
    }

    $all_properties = $all_properties | Where-Object { $Global:Properties.exclude -notcontains $_ }

    $properties_rows = $all_properties | Sort-Object -Unique | ForEach-Object {
        $usage_hint = @()

        if ($Global:Properties.default.$Class -contains $_) {
            $usage_hint += 'Default'
        }

        if ($Global:Properties.idm -contains $_ -or $Global:Properties.extra.$Class -contains $_) {
            $usage_hint += 'IDM'
        }

        if ($Class -eq 'user') {
            if ($Global:TerminalServicesAttributes -contains $_) {
                $usage_hint += 'TS'
            }
        }

        @{ name = $_; usage_hint = ($usage_hint -join ' | ') }
    }

    $out = @()

    if ($Class -eq 'organizationalUnit') {
        $out += @{
            name = 'include_container_objects'
            type = 'checkbox'
            label = 'Include container objects'
            value = $false
        }
    }

    $out += @(
        @{
            name = 'filter'
            type = 'textbox'
            label = 'LDAP filter'
            tooltip = 'Search filter; empty or * matches anything'
            value = '*'
        }
        @{
            name = 'properties'
            type = 'grid'
            label = 'Properties'
            table = @{
                rows = @( $properties_rows )
                settings_grid = @{
                    selection = 'multiple'
                    key_column = 'name'
                    checkbox = $true
                    filter = $true
                    columns = @(
                        @{
                            name = 'name'
                            display_name = 'Name'
                        }
                        @{
                            name = 'usage_hint'
                            display_name = 'Usage hint'
                        }
                    )
                }
            }
            value = $Global:Properties.default.$Class
        }
    )

    $out
}

$configScenarios = @'
[{"name":"Default","description":"","version":"1.0","createTime":1739222743185,"modifyTime":17392227
43185,"name_values":[{"name":"collections","value":["Groups","Memberships","OrganizationalUnits","Us
ers"]},{"name":"domain","value":null},{"name":"multi_searchbases","value":false},{"name":"nr_of_sess
ions","value":null},{"name":"password","value":null},{"name":"resultpagesize","value":"0"},{"name":"
root_domain","value":null},{"name":"searchbase","value":"*"},{"name":"searchbases","value":[]},{"nam
e":"server","value":null},{"name":"sessions_idle_timeout","value":null},{"name":"use_specific_server
","value":null},{"name":"use_svc_account_creds","value":null},{"name":"username","value":null}],"col
lections":[{"col_name":"Groups","fields":[{"field_name":"objectGUID","field_type":"string","include"
:true,"field_format":"","field_source":"data","javascript":"","ref_col":[],"reference":false,"ref_co
l_fields":[]},{"field_name":"distinguishedName","field_type":"string","include":true,"field_format":
"","field_source":"data","javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field
_name":"GroupCategory","field_type":"string","include":true,"field_format":"","field_source":"data",
"javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"GroupScope","fiel
d_type":"string","include":true,"field_format":"","field_source":"data","javascript":"","ref_col":[]
,"reference":false,"ref_col_fields":[]},{"field_name":"cn","field_type":"string","include":true,"fie
ld_format":"","field_source":"data","javascript":"","ref_col":[],"reference":false,"ref_col_fields":
[]},{"field_name":"objectClass","field_type":"string","include":true,"field_format":"","field_source
":"data","javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"path","f
ield_type":"string","include":true,"field_format":"","field_source":"data","javascript":"","ref_col"
:[],"reference":false,"ref_col_fields":[]},{"field_name":"sAMAccountName","field_type":"string","inc
lude":true,"field_format":"","field_source":"data","javascript":"","ref_col":[],"reference":false,"r
ef_col_fields":[]},{"field_name":"objectSid","field_type":"string","include":true,"field_format":"",
"field_source":"data","javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]}],"key":"ob
jectGUID","display":"sAMAccountName","name_values":[],"sys_nn":[],"source":"data"},{"col_name":"Memb
erships","fields":[{"field_name":"group","field_type":"string","include":true,"field_format":"","fie
ld_source":"data","javascript":"","ref_col":["Groups"],"reference":false,"ref_col_fields":[]},{"fiel
d_name":"member","field_type":"string","include":true,"field_format":"","field_source":"data","javas
cript":"","ref_col":["Users","Groups"],"reference":false,"ref_col_fields":[]}],"key":"","display":"m
ember","name_values":[],"sys_nn":[{"field_a":"group","col_a":"Groups","field_b":"member","col_b":"Gr
oups"},{"field_a":"group","col_a":"Groups","field_b":"member","col_b":"Users"}],"source":"data"},{"c
ol_name":"OrganizationalUnits","fields":[{"field_name":"objectGUID","field_type":"string","include":
true,"field_format":"","field_source":"data","javascript":"","ref_col":[],"reference":false,"ref_col
_fields":[]},{"field_name":"c","field_type":"string","include":true,"field_format":"","field_source"
:"data","javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"distingui
shedName","field_type":"string","include":true,"field_format":"","field_source":"data","javascript":
"","ref_col":[],"reference":true,"ref_col_fields":[]},{"field_name":"gPLink","field_type":"string","
include":true,"field_format":"","field_source":"data","javascript":"","ref_col":[],"reference":false
,"ref_col_fields":[]},{"field_name":"l","field_type":"string","include":true,"field_format":"","fiel
d_source":"data","javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"
managedBy","field_type":"string","include":true,"field_format":"","field_source":"data","javascript"
:"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"ou","field_type":"string","in
clude":true,"field_format":"","field_source":"data","javascript":"","ref_col":[],"reference":false,"
ref_col_fields":[]},{"field_name":"objectClass","field_type":"string","include":true,"field_format":
"","field_source":"data","javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field
_name":"path","field_type":"string","include":true,"field_format":"","field_source":"data","javascri
pt":"","ref_col":[],"reference":false,"ref_col_fields":[{"col":"OrganizationalUnits","field":"distin
guishedName"}]},{"field_name":"postalCode","field_type":"string","include":true,"field_format":"","f
ield_source":"data","javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name
":"st","field_type":"string","include":true,"field_format":"","field_source":"data","javascript":"",
"ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"streetAddress","field_type":"stri
ng","include":true,"field_format":"","field_source":"data","javascript":"","ref_col":[],"reference":
false,"ref_col_fields":[]}],"key":"objectGUID","display":"distinguishedName","name_values":[],"sys_n
n":[],"source":"data"},{"col_name":"Users","fields":[{"field_name":"objectGUID","field_type":"string
","include":true,"field_format":"","field_source":"data","javascript":"","ref_col":[],"reference":fa
lse,"ref_col_fields":[]},{"field_name":"accountExpires","field_type":"string","include":true,"field_
format":"","field_source":"data","javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]}
,{"field_name":"adminDescription","field_type":"string","include":true,"field_format":"","field_sour
ce":"data","javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"adminD
isplayName","field_type":"string","include":true,"field_format":"","field_source":"data","javascript
":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"c","field_type":"string","in
clude":true,"field_format":"","field_source":"data","javascript":"","ref_col":[],"reference":false,"
ref_col_fields":[]},{"field_name":"CannotChangePassword","field_type":"boolean","include":true,"fiel
d_format":"","field_source":"data","javascript":"","ref_col":[],"reference":false,"ref_col_fields":[
]},{"field_name":"canonicalName","field_type":"string","include":true,"field_format":"","field_sourc
e":"data","javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"ChangeP
asswordAtLogon","field_type":"boolean","include":true,"field_format":"","field_source":"data","javas
cript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"cn","field_type":"strin
g","include":true,"field_format":"","field_source":"data","javascript":"","ref_col":[],"reference":f
alse,"ref_col_fields":[]},{"field_name":"co","field_type":"string","include":true,"field_format":"",
"field_source":"data","javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_na
me":"company","field_type":"string","include":true,"field_format":"","field_source":"data","javascri
pt":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"countryCode","field_type":
"number","include":true,"field_format":"","field_source":"data","javascript":"","ref_col":[],"refere
nce":false,"ref_col_fields":[]},{"field_name":"createTimeStamp","field_type":"date","include":true,"
field_format":"","field_source":"data","javascript":"","ref_col":[],"reference":false,"ref_col_field
s":[]},{"field_name":"department","field_type":"string","include":true,"field_format":"","field_sour
ce":"data","javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"descri
ption","field_type":"string","include":true,"field_format":"","field_source":"data","javascript":"",
"ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"displayName","field_type":"string
","include":true,"field_format":"","field_source":"data","javascript":"","ref_col":[],"reference":fa
lse,"ref_col_fields":[]},{"field_name":"distinguishedName","field_type":"string","include":true,"fie
ld_format":"","field_source":"data","javascript":"","ref_col":[],"reference":true,"ref_col_fields":[
]},{"field_name":"division","field_type":"string","include":true,"field_format":"","field_source":"d
ata","javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"employeeID",
"field_type":"string","include":true,"field_format":"","field_source":"data","javascript":"","ref_co
l":[],"reference":false,"ref_col_fields":[]},{"field_name":"employeeNumber","field_type":"string","i
nclude":true,"field_format":"","field_source":"data","javascript":"","ref_col":[],"reference":false,
"ref_col_fields":[]},{"field_name":"employeeType","field_type":"string","include":true,"field_format
":"","field_source":"data","javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"fie
ld_name":"Enabled","field_type":"boolean","include":true,"field_format":"","field_source":"data","ja
vascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"givenName","field_ty
pe":"string","include":true,"field_format":"","field_source":"data","javascript":"","ref_col":[],"re
ference":false,"ref_col_fields":[]},{"field_name":"homeDirectory","field_type":"string","include":tr
ue,"field_format":"","field_source":"data","javascript":"","ref_col":[],"reference":false,"ref_col_f
ields":[]},{"field_name":"homeDrive","field_type":"string","include":true,"field_format":"","field_s
ource":"data","javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"hom
ePhone","field_type":"string","include":true,"field_format":"","field_source":"data","javascript":""
,"ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"initials","field_type":"string",
"include":true,"field_format":"","field_source":"data","javascript":"","ref_col":[],"reference":fals
e,"ref_col_fields":[]},{"field_name":"info","field_type":"string","include":true,"field_format":"","
field_source":"data","javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_nam
e":"ipPhone","field_type":"string","include":true,"field_format":"","field_source":"data","javascrip
t":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"l","field_type":"string","i
nclude":true,"field_format":"","field_source":"data","javascript":"","ref_col":[],"reference":false,
"ref_col_fields":[]},{"field_name":"lastLogon","field_type":"string","include":true,"field_format":"
","field_source":"data","javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_
name":"lastLogonTimestamp","field_type":"string","include":true,"field_format":"","field_source":"da
ta","javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"mail","field_
type":"string","include":true,"field_format":"","field_source":"data","javascript":"","ref_col":[],"
reference":false,"ref_col_fields":[]},{"field_name":"manager","field_type":"string","include":true,"
field_format":"","field_source":"data","javascript":"","ref_col":[],"reference":false,"ref_col_field
s":[{"col":"Users","field":"distinguishedName"}]},{"field_name":"middleName","field_type":"string","
include":true,"field_format":"","field_source":"data","javascript":"","ref_col":[],"reference":false
,"ref_col_fields":[]},{"field_name":"mobile","field_type":"string","include":true,"field_format":"",
"field_source":"data","javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_na
me":"name","field_type":"string","include":true,"field_format":"","field_source":"data","javascript"
:"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"objectClass","field_type":"st
ring","include":true,"field_format":"","field_source":"data","javascript":"","ref_col":[],"reference
":false,"ref_col_fields":[]},{"field_name":"objectSid","field_type":"string","include":true,"field_f
ormat":"","field_source":"data","javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},
{"field_name":"pager","field_type":"string","include":true,"field_format":"","field_source":"data","
javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"PasswordExpiration
Date","field_type":"date","include":true,"field_format":"yyyy-mm-dd (local)","field_source":"data","
javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"PasswordNeverExpir
es","field_type":"boolean","include":true,"field_format":"","field_source":"data","javascript":"","r
ef_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"PasswordNotRequired","field_type":"
boolean","include":true,"field_format":"","field_source":"data","javascript":"","ref_col":[],"refere
nce":false,"ref_col_fields":[]},{"field_name":"path","field_type":"string","include":true,"field_for
mat":"","field_source":"data","javascript":"","ref_col":[],"reference":false,"ref_col_fields":[{"col
":"OrganizationalUnits","field":"distinguishedName"}]},{"field_name":"physicalDeliveryOfficeName","f
ield_type":"string","include":true,"field_format":"","field_source":"data","javascript":"","ref_col"
:[],"reference":false,"ref_col_fields":[]},{"field_name":"primaryGroupID","field_type":"string","inc
lude":true,"field_format":"","field_source":"data","javascript":"","ref_col":[],"reference":false,"r
ef_col_fields":[]},{"field_name":"postalCode","field_type":"string","include":true,"field_format":""
,"field_source":"data","javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_n
ame":"postOfficeBox","field_type":"string","include":true,"field_format":"","field_source":"data","j
avascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"profilePath","field
_type":"string","include":true,"field_format":"","field_source":"data","javascript":"","ref_col":[],
"reference":false,"ref_col_fields":[]},{"field_name":"proxyAddresses","field_type":"string-array","i
nclude":true,"field_format":"","field_source":"data","javascript":"","ref_col":[],"reference":false,
"ref_col_fields":[]},{"field_name":"roomNumber","field_type":"string","include":true,"field_format":
"","field_source":"data","javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field
_name":"sAMAccountName","field_type":"string","include":true,"field_format":"","field_source":"data"
,"javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"scriptPath","fie
ld_type":"string","include":true,"field_format":"","field_source":"data","javascript":"","ref_col":[
],"reference":false,"ref_col_fields":[]},{"field_name":"sn","field_type":"string","include":true,"fi
eld_format":"","field_source":"data","javascript":"","ref_col":[],"reference":false,"ref_col_fields"
:[]},{"field_name":"st","field_type":"string","include":true,"field_format":"","field_source":"data"
,"javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"streetAddress","
field_type":"string","include":true,"field_format":"","field_source":"data","javascript":"","ref_col
":[],"reference":false,"ref_col_fields":[]},{"field_name":"telephoneNumber","field_type":"string","i
nclude":true,"field_format":"","field_source":"data","javascript":"","ref_col":[],"reference":false,
"ref_col_fields":[]},{"field_name":"title","field_type":"string","include":true,"field_format":"","f
ield_source":"data","javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name
":"userPrincipalName","field_type":"string","include":true,"field_format":"","field_source":"data","
javascript":"","ref_col":[],"reference":false,"ref_col_fields":[]},{"field_name":"whenCreated","fiel
d_type":"date","include":true,"field_format":"","field_source":"data","javascript":"","ref_col":[],"
reference":false,"ref_col_fields":[]},{"field_name":"wWWHomePage","field_type":"string","include":tr
ue,"field_format":"","field_source":"data","javascript":"","ref_col":[],"reference":false,"ref_col_f
ields":[]}],"key":"objectGUID","display":"sAMAccountName","name_values":[{"name":"filter","value":"*
"},{"name":"properties","value":["accountExpires","adminDescription","adminDisplayName","c","CannotC
hangePassword","canonicalName","ChangePasswordAtLogon","cn","co","company","countryCode","createTime
Stamp","department","description","displayName","distinguishedName","division","employeeID","employe
eNumber","employeeType","Enabled","givenName","homeDirectory","homeDrive","homePhone","info","initia
ls","ipPhone","l","lastLogon","lastLogonTimestamp","mail","manager","middleName","mobile","name","ob
jectClass","objectGUID","objectSid","pager","PasswordExpirationDate","PasswordNeverExpires","Passwor
dNotRequired","path","physicalDeliveryOfficeName","postalCode","postOfficeBox","primaryGroupID","pro
filePath","proxyAddresses","roomNumber","sAMAccountName","scriptPath","sn","st","streetAddress","tel
ephoneNumber","title","userPrincipalName","whenCreated","wWWHomePage"]}],"sys_nn":[],"source":"data"
}]}]
'@
