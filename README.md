# HelloID-Conn-Prov-Target-NewBlack

> [!IMPORTANT]
> This repository contains the connector and configuration code only. The implementer is responsible to acquire the connection details such as username, password, certificate, etc. You might even need to sign a contract or agreement with the supplier before implementing this connector. Please contact the client's application manager to coordinate the connector requirements.

<p align="center">
  <img src="https://avatars.githubusercontent.com/u/14044098?s=200&v=4">
</p>

## Table of contents

- [HelloID-Conn-Prov-Target-NewBlack](#helloid-conn-prov-target-newblack)
  - [Table of contents](#table-of-contents)
  - [Introduction](#introduction)
  - [Getting started](#getting-started)
    - [Prerequisites](#prerequisites)
    - [Connection settings](#connection-settings)
    - [Correlation configuration](#correlation-configuration)
    - [Available lifecycle actions](#available-lifecycle-actions)
    - [Field mapping](#field-mapping)
  - [Remarks](#remarks)
    - [Concurrent actions](#concurrent-actions)
    - [Account Access](#account-access)
    - [Account object](#account-object)
      - [Employee- and UserObject](#employee--and-userobject)
      - [Properties](#properties)
      - [Reboarding](#reboarding)
      - [Encoding](#encoding)
    - [Permissions](#permissions)
      - [Mapping](#mapping)
- [Script Configuration](#script-configuration)
    - [Correlation](#correlation)
  - [Development resources](#development-resources)
    - [API endpoints](#api-endpoints)
    - [API documentation](#api-documentation)
  - [Getting help](#getting-help)
  - [HelloID docs](#helloid-docs)

## Introduction

_HelloID-Conn-Prov-Target-NewBlack_ is a _target_ connector. _NewBlack_ provides a set of REST API's that allow you to programmatically interact with its data.

## Getting started

### Prerequisites

<!--
Describe the specific requirements that must be met before using this connector, such as the need for an agent, a certificate or IP whitelisting.

**Please ensure to list the requirements using bullet points for clarity.**

Example:

- **SSL Certificate**:<br>
  A valid SSL certificate must be installed on the server to ensure secure communication. The certificate should be trusted by a recognized Certificate Authority (CA) and must not be self-signed.
- **IP Whitelisting**:<br>
  The IP addresses used by the connector must be whitelisted on the target system's firewall to allow access. Ensure that the firewall rules are configured to permit incoming and outgoing connections from these IPs.
-->

### Connection settings

The following settings are required to connect to the API.

| Setting                   | Description                                                                  | Mandatory |
| ------------------------- | ---------------------------------------------------------------------------- | --------- |
| ApiKey                    | The ApiKey to connect to the API                                             | Yes       |
| BaseUrl                   | The URL to the API                                                           | Yes       |
| OrganizationUnitIdMapping | The mapping file between HelloID department and New Black OrganizationUnitId | Yes       |
| CSVDelimiter              | The Delimiter for the mapping file                                           | Yes       |

### Correlation configuration

The correlation configuration is used to specify which properties will be used to match an existing account within _NewBlack_ to a person in _HelloID_.

| Setting                   | Value            |
| ------------------------- | ---------------- |
| Enable correlation        | `True`           |
| Person correlation field  | `ExternalId`     |
| Account correlation field | `EmployeeNumber` |

> [!TIP]
> _For more information on correlation, please refer to our correlation [documentation](https://docs.helloid.com/en/provisioning/target-systems/powershell-v2-target-systems/correlation.html) pages_.

### Available lifecycle actions

The following lifecycle actions are available:

| Action                                  | Description                                                                     |
| --------------------------------------- | ------------------------------------------------------------------------------- |
| create.ps1                              | Creates a new account.                                                          |
| delete.ps1                              | n/a                                                                             |
| disable.ps1                             | n/a **Account access will be managed with a login group*                        |
| enable.ps1                              | n/a **Account access will be managed with a login group*                        |
| update.ps1                              | Updates the attributes of an account.                                           |
| permissions/roles/subPermissions.ps1    | Grants and revoke permissions to an account to the associated organizationUnits. *(Based on ExternalMapping CSV file.)*                                   |
| permissions/groups/permissions.ps1      | Retrieves all available permissions (Roles).                                    |
| configuration.json                      | Contains the connection settings and general configuration for the connector.   |
| fieldMapping.json                       | Defines mappings between person fields and target system person account fields. |

### Field mapping

The field mapping can be imported by using the _fieldMapping.json_ file.

## Remarks
### Concurrent actions
> [!IMPORTANT]
> Granting and revoking Roles is done by editing roles after receiving the currently assigned roles. For this reason, the concurrent actions need to be set to `1`.


### Account Access
- Enable/Disable is managed through a separate group that must be created specifically for each system. In New-Black, there is no standalone account property for enabling or disabling. However, there is a permission that handles this. This permission can be assigned to a group, which HelloID can then use as a login permission.
- This group can be named for example 'Login' and managed like any other group.


### Account object
#### Employee- and UserObject
- There are two separate account objects in New Black, one for the user and one for the employee.
- The relation between those object is always one-on-one.
- Currently the EmployeeNumber and the function are fields of the Employee Object, the rest are fields  of the user object.

#### Properties
- The property `EmployeeNumber` and `BackendRelationID` are **NOT** unique.
- The `NickName` and the `EmailAddress` are unique in New Black. *The `NickName` is not used by this connector.*
- The `CreateEmployeeUser` endpoint, which is used to create accounts, can also update an existing account based on the NickName or EmailAddress. If the EmailAddress already exists, it will not create a new account but will instead update the existing account associated with the corresponding email address. The connector is designed to prevent this unintended behavior.

#### Reboarding
- Currently, there is no logic added to the connector to support reboarding, such as renaming or clearing the email address during the delete action. This is mostly because the way accounts are deleted or disabled is often customer-specific. However, reboarding can be an issue in the New Black Connector, as the API does not support deleting accounts, and the email address must be unique within NewBlack.

- The connector currently checks if the email already exists and throws an error if it does. This must be discussed with the customer to determine how to handle it. For example, it is also possible to reuse a previously created account. To make this possible, you can remove the email uniqueness check, and the connector will handle the rest. In this case, the create action will update the existing account with the matching email instead of creating a new one.
  - This results in a different result number, and currently, the connector shows a warning when this happens.

#### Encoding
The connector is created for the HelloID agent; therefore, the encoding is based on PowerShell 5.1. This presents a drawback when using the connector in the cloud. You need to convert the response differently to correctly display diacritics, as demonstrated below in multiple places in the code.

```PowerShell
$responseSearchUser = (Invoke-WebRequest @splatSearchUser)
$correlatedAccount = ([Text.Encoding]::UTF8.GetString([Text.Encoding]::GetEncoding(28591).GetBytes(($responseSearchUser.Content))) | ConvertFrom-Json).Result.Page
```

Powershell 7.1 Example:
```PowerShell
$correlatedAccount = (Invoke-RestMethod @splatSearchUser).Result.Page
```


### Permissions
- The roles include a UserType, where UserType '1' is specified for employees. The connector currently does not filter based on UserType, but this functionality can be incorporated into the permissions script to meet customer requirements.
- A role is assigned to a specific OrganizationUnit. If an employee is associated with multiple OrganizationUnits, the role can or must be assigned to each relevant unit. To support this, the connector implements SubPermissions to supports multiple assignments per role.
- To obtain the OrganizationUnitID, a mapping file is used to map the HelloID department to one or more New Black OrganizationUnits. (See: [Mapping](#mapping))

#### Mapping
- The headers in the mapping file are fixed.
- The mapping is intended to create a mapping between a HelloID department and the New Black `OrganizationUnitIDs`.
- An example mapping file can be found in the `permissions\Roles` folder as `OrganizationUnitIdMapping.csv`.
- To define the property in the HelloID contracts, there is a script configuration in the `SubPermissions.ps1` script.
    ```PowerShell
  # Script Configuration
  $departmentLookupProperty = { $_.Department.ExternalId }
    ```
### Correlation
- IncludeAllCountries: By default the search will only return users from the same Country as the current OrganizationUnit. Optionally an extensive search can be performed by enabling this option. But keep in mind this will take some time in real production scenario's. It is advised to only show this option in the frontend after an initial search has been done in the current country.

## Development resources

### API endpoints

The following endpoints are used by the connector

| Endpoint                            | Description                              |
| ----------------------------------- | ---------------------------------------- |
| /message/SearchUsers                | Retrieve user information                |
| /message/GetUser                    | Retrieve user information by UserID      |
| /message/GetEmployeeData            | Retrieve Employee information by UserID  |
| /message/CreateEmployeeUser         | Create users and Employees               |
| /message/UpdateUser                 | Update users                             |
| /message/CreateOrUpdateEmployeeData | Update Employees                         |
| /message/ListRoles                  | Retrieve roles information               |
| /message/GetUserRoles               | Retrieve existing user roles information |
| /message/SetUserRoles               | Set roles to a user                      |

### API documentation
Access to the API documentation is restricted to users with valid credentials

## Getting help

> [!TIP]
> _For more information on how to configure a HelloID PowerShell connector, please refer to our [documentation](https://docs.helloid.com/en/provisioning/target-systems/powershell-v2-target-systems.html) pages_.

> [!TIP]
>  _If you need help, feel free to ask questions on our [forum](https://forum.helloid.com/forum/helloid-connectors/provisioning/5294-helloid-conn-prov-target-newblack)_.

## HelloID docs

The official HelloID documentation can be found at: https://docs.helloid.com/
