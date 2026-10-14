# TestAndDemo release notes

`scripts/Get-WorkItems.ps1` writes release notes for the latest successful deployments of one Octopus project to Production and ATEST. It resolves each Octopus release version to exactly one Azure DevOps build number, retrieves the work items associated with the build range, fetches their titles, and writes linked work item IDs to `Polaris/<ATEST-version>.md`. When the range has no work items, the report explains that rather than producing an empty file.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7.
- Network access to the configured Octopus Deploy and Azure DevOps Services instances.
- An Octopus API key with permission to view the configured space, project, deployments, and releases.
- An Azure DevOps PAT with permission to read builds and work items in the configured organization and project.
- Pester to run the tests.

## Configuration and authentication

Pass the tenant/resource identifiers explicitly; credentials are read only from environment variables and are never stored in the script:

```powershell
$env:OCTOPUS_API_KEY = '<Octopus API key>'
$env:AZDO_PAT = '<Azure DevOps PAT>'
```

The Azure DevOps PAT is sent using HTTP Basic authentication. Octopus requests use the `X-Octopus-ApiKey` header. Avoid putting credentials in command-line arguments or committing them to the repository.

## Run

From the repository root, replace the example values with the Octopus URL, space/project IDs, Production and ATEST environment IDs, and Azure DevOps organization/project names:

```powershell
.\scripts\Get-WorkItems.ps1 `
  -OctopusUrl 'https://octopus.example.com' `
  -OctopusSpaceId 'Spaces-1' `
  -OctopusProjectId 'Projects-42' `
  -ProductionEnvironmentId 'Environments-1' `
  -AtestEnvironmentId 'Environments-2' `
  -AdoOrganization 'my-organization' `
  -AdoProject 'my-project'
```

The default destination is the repository's `Polaris` directory. Set `-OutputDirectory` to use another location. Release versions used as filenames must contain only letters, digits, periods, underscores, plus signs, or hyphens and cannot end in a period.

The script paginates Octopus deployments and Azure DevOps build/work-item responses. It reports missing credentials, failed API requests, missing successful deployments, and missing or ambiguous exact build-number matches rather than silently selecting a substitute.

## Tests

Run the mocked API tests from the repository root:

```powershell
Invoke-Pester .\tests\Get-WorkItems.Tests.ps1
```
