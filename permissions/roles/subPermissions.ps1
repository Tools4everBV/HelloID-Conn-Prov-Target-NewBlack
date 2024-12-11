#########################################################
# HelloID-Conn-Prov-Target-NewBlack-SubPermissions-Rol
# PowerShell V2
#########################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Script Configuration
$departmentLookupProperty = { $_.Department.ExternalId }


#region functions
function Resolve-NewBlackError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]
        $ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            ScriptLineNumber = $ErrorObject.InvocationInfo.ScriptLineNumber
            Line             = $ErrorObject.InvocationInfo.Line
            ErrorDetails     = $ErrorObject.Exception.Message
            FriendlyMessage  = $ErrorObject.Exception.Message
        }
        if (-not [string]::IsNullOrEmpty($ErrorObject.ErrorDetails.Message)) {
            $httpErrorObj.ErrorDetails = $ErrorObject.ErrorDetails.Message
        } elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {
            if ($null -ne $ErrorObject.Exception.Response) {
                $streamReaderResponse = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
                if (-not [string]::IsNullOrEmpty($streamReaderResponse)) {
                    $httpErrorObj.ErrorDetails = $streamReaderResponse
                }
            }
        }
        try {
            $errorDetailsObject = ($httpErrorObj.ErrorDetails | ConvertFrom-Json)
            $httpErrorObj.FriendlyMessage = $errorDetailsObject.Error.Message
        } catch {
            $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails
        }
        Write-Output $httpErrorObj
    }
}
#endregion

try {
    $successAuditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ([string]::IsNullOrEmpty($($actionContext.References.Account))) {
        throw 'The account reference could not be found'
    }

    $headers = @{
        'EVA-User-Agent' = 'HelloID/1.0.0'
        'Content-Type'   = 'application/json'
        Authorization    = "Bearer $($actionContext.Configuration.ApiKey)"
    }

    Write-Information 'Verifying if a NewBlack account exists and existing Get User Roles'
    $splatGetUser = @{
        Uri     = "$($actionContext.Configuration.BaseUrl)/message/GetUserRoles"
        Method  = 'POST'
        Headers = $headers
        Body    = @{
            UserId = $actionContext.References.Account
        } | ConvertTo-Json
    }

    $currentUserRoles = (Invoke-RestMethod @splatGetUser).Roles
    $allUserRoles = [System.Collections.Generic.List[object]]::new($currentUserRoles)

    [array]$organizationUnitIdMapping = Import-Csv -Path $actionContext.Configuration.OrganizationUnitIdMapping -Delimiter $actionContext.Configuration.CSVDelimiter

    # Collect current permissions
    $updateRequired = $false
    $currentDepartments = [System.Collections.Generic.List[int]]::new()
    foreach ($department in $actionContext.CurrentPermissions) {
        $currentDepartments.Add($department.Reference.Id)
    }

    # Collect desired permissions
    $desiredDepartments = [System.Collections.Generic.List[int]]::new()
    if (-Not($actionContext.Operation -eq 'revoke')) {
        foreach ($contract in $personContext.Person.Contracts) {
            if ($contract.Context.InConditions -or $actionContext.DryRun) {
                $departmentCode = ($contract | Select-Object $departmentLookupProperty).$departmentLookupProperty

                Write-Information "Check the CSV-mapping file with [$($departmentCode)] for the New Black OrganizationUnitId."
                $mappedOrgUnitId = $organizationUnitIdMapping | Where-Object { $_.HelloIDDepartment -eq $departmentCode }
                if ($null -eq $mappedOrgUnitId) {
                    $outputContext.AuditLogs.Add([PSCustomObject]@{
                            Message = "Calculation error. No entry found in the CSV file for [$($departmentLookupProperty) - $($departmentCode)]"
                            IsError = $true
                        })
                    continue
                }
                foreach ($id in $mappedOrgUnitId.NewBlackOrganizationUnitId -split ',') {
                    $desiredDepartments.Add($id)
                }
            }
        }
    }
    # When a mapping error occurs, do not continue executing the code.
    if ($true -in $outputContext.AuditLogs.IsError) {
        throw 'Validation Error'
    }

    # Filter Unique values
    $desiredDepartments = [System.Collections.Generic.List[int]]($desiredDepartments | Select-Object -Unique)

    # Process desired permissions to grant
    foreach ($departmentId in $desiredDepartments) {
        $role = $allUserRoles | Where-Object {
            $_.RoleID -eq $actionContext.References.Permission.Reference -and
            $_.OrganizationUnitSetID -eq $departmentId
        }
        if ($null -eq $role) {
            $updateRequired = $true
            $allUserRoles.Add([PSCustomObject]@{
                    RoleID                = $actionContext.References.Permission.Reference
                    OrganizationUnitSetID = $departmentId
                }
            )
        }

        $successAuditLogs.Add([PSCustomObject]@{
                Action  = 'GrantPermission'
                Message = "Granted access [$($actionContext.References.Permission.DisplayName)] to OrganizationUnitId [$($departmentId)]"
                IsError = $false
            })

        $outputContext.SubPermissions.Add([PSCustomObject]@{
                DisplayName = "$($actionContext.References.Permission.DisplayName) | OrganizationUnitId: $($departmentId)"
                Reference   = @{
                    id = $departmentId
                }
            })
    }

    # Process current permissions to revoke
    foreach ($departmentId in $currentDepartments) {
        if ( -not ($departmentId -in $desiredDepartments) ) {
            $role = $allUserRoles | Where-Object {
                $_.RoleID -eq $actionContext.References.Permission.Reference -and
                $_.OrganizationUnitSetID -eq $departmentId
            }
            if ($null -ne $role) {
                $updateRequired = $true
                $null = $allUserRoles.Remove($role)
            }

            $successAuditLogs.Add([PSCustomObject]@{
                    Action  = 'RevokePermission'
                    Message = "Revoked access [$($actionContext.References.Permission.DisplayName)] from OrganizationUnitId [$($departmentId)]"
                    IsError = $false
                })
        }
    }

    if ( $updateRequired ) {
        $splatSetUser = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/message/SetUserRoles"
            Method  = 'POST'
            Headers = $headers
            Body    = @{
                UserId = $actionContext.References.Account
                Roles  = [array]@($allUserRoles )
            } | ConvertTo-Json
        }
        $null = (Invoke-RestMethod @splatSetUser)
    }

    if (-not ($true -in $outputContext.AuditLogs.IsError)) {
        $outputContext.AuditLogs.AddRange($successAuditLogs)
        $outputContext.Success = $true
    }
} catch {
    $outputContext.Success = $false
    $ex = $PSItem
    if (-not ($_.Exception.Message -eq 'Validation Error')) {
        if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
            $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
            $errorObj = Resolve-NewBlackError -ErrorObject $ex
            $auditMessage = "Could not manage NewBlack [$($actionContext.References.Permission.DisplayName)] permission. Error: $($errorObj.FriendlyMessage)"
            Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
        } else {
            $auditMessage = "Could not manage NewBlack [$($actionContext.References.Permission.DisplayName)] permission. Error: $($_.Exception.Message)"
            Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
        }
        $outputContext.AuditLogs.Add([PSCustomObject]@{
                Message = $auditMessage
                IsError = $true
            })
    }
}