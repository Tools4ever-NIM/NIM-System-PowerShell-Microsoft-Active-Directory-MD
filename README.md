# Microsoft Active Directory Multi-Domain

<img src="https://user-images.githubusercontent.com/24281600/134387458-b0686b64-7252-41b0-9d6d-a8b084bac626.png" width="256px" />

# Description
This Multi-Domain variant of the Microsoft Active Directory connector supports operations on multiple domains in a forest. It shares most of the capabilities with the [basic Active Directory connector](https://github.com/Tools4ever-NIM/NIM-System-PowerShell-Microsoft-Active-Directory), with the following remarks:

- The NIM service running this connector must be part of the involved forest / root domain.
- One set of credentials must be valid for operations on all involved domain controllers.
- The domain controller marked as *SchemaRoleOwner* of the root domain is used to retrieve the available properties (schema) per Data Table (users/groups/...).
- The *Search base* menu item, known from the basic Active Directory connector, is not available as it is non-trivial to apply to multiple domains.
- Als long as there are full trusts between the domains, objects from any domain can be added as member of groups in any (other) domain, unless the involved Group Scope prohibits that.
- Als long as there are full trusts between the domains, objects can be freely moved between domains, unless the involved Group Scope prohibits that.
- Since multiple domains are involved and *objectGUID* is used to reference objects, a way is needed to find the domain to be addressed for Update and Delete operations. The Global Catalog of the root domain is used for this. This, however, requires replication to be completed after creation of objects. If addressed too fast, objects created in a subdomain may not yet be found in the Global Catalog of the root domain. For those situations, the *distinguishedName* is added as an optional attribute for Update and Delete operations - the domain can then be determined without querying the Global Catalog.

# Data Tables
- Computers
- Groups
- Memberships
- Organizational Units
- Users


# Actions
- Computers
    - Create/Update/Delete
- Groups
    - Create/Update/Delete
- Memberships
    - Add/Remove
- Organizational Units
    - Create/Update/Delete
- Users
    - Create/Update/Delete

# NIM Docs
The official NIM documentation can be found at: https://docs.nimsuite.com
