# Terraform Azure Infrastructure — CI/CD Pipeline

A production-ready Terraform workflow for Azure infrastructure, enforcing version consistency, remote state locking, and automated plan/apply via Azure DevOps.

---

## Table of Contents

- [Overview](#overview)
- [Repository Structure](#repository-structure)
- [Prerequisites](#prerequisites)
- [Setup Guide](#setup-guide)
- [Pipeline Walkthrough](#pipeline-walkthrough)
- [Version Management](#version-management)
- [Remote State](#remote-state)
- [Local Development](#local-development)
- [Team Workflow](#team-workflow)
- [Troubleshooting](#troubleshooting)

---

## Overview

| Feature | Detail |
|---|---|
| Terraform Version | Pinned via `TF_VERSION` in pipeline + `.terraform-version` for local |
| Provider Locking | `.terraform.lock.hcl` committed to repo |
| State Backend | Azure Storage Account with blob lease locking |
| Plan → Apply | Plan saved as artifact; apply consumes exact plan |
| PR Checks | `fmt`, `validate`, `plan` run on every pull request |
| Apply Gate | Manual approval required before applying to production |

---

## Repository Structure

```
.
├── azure-pipelines.yml          # CI/CD pipeline definition
├── .terraform-version           # Pins Terraform version for tfenv
├── .terraform.lock.hcl          # Provider version lock file — DO NOT gitignore
├── versions.tf                  # required_version + required_providers
├── main.tf                      # Core infrastructure resources
├── variables.tf                 # Input variable declarations
├── outputs.tf                   # Output value declarations
├── terraform.tfvars             # Variable values (non-sensitive)
└── modules/
    └── ...                      # Reusable child modules
```

---

## Prerequisites

### Tools

| Tool | Purpose | Install |
|---|---|---|
| Terraform | IaC engine | [terraform.io](https://developer.hashicorp.com/terraform/install) |
| tfenv | Terraform version manager | [github.com/tfutils/tfenv](https://github.com/tfutils/tfenv) |
| Azure CLI | Local auth + backend setup | [docs.microsoft.com](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) |

### Azure Resources

- An Azure **Service Principal** with Contributor access to your target subscription
- An Azure **Storage Account** for Terraform remote state (see [Remote State](#remote-state))

### Azure DevOps

- A **Variable Group** named `terraform-secrets` (see [Setup Guide](#setup-guide))
- An **Azure Service Connection** named `AzureServiceConnection`
- A **production Environment** with a manual approval gate

---

## Setup Guide

### 1. Create the Remote State Storage Account

```bash
# Login
az login

# Create resource group for state
az group create \
  --name tfstate-rg \
  --location eastus

# Create storage account (name must be globally unique)
az storage account create \
  --name tfstate12345 \
  --resource-group tfstate-rg \
  --sku Standard_LRS \
  --encryption-services blob

# Create blob container
az storage container create \
  --name tfstate \
  --account-name tfstate12345
```

### 2. Create the Service Principal

```bash
az ad sp create-for-rbac \
  --name "terraform-sp" \
  --role Contributor \
  --scopes /subscriptions/<YOUR_SUBSCRIPTION_ID>
```

Save the output — you'll need these values:

```json
{
  "appId":       "→ ARM_CLIENT_ID",
  "password":    "→ ARM_CLIENT_SECRET",
  "tenant":      "→ ARM_TENANT_ID"
}
```

### 3. Create the Azure DevOps Variable Group

In Azure DevOps → **Pipelines → Library → + Variable Group**

Name it exactly: `terraform-secrets`

| Variable | Value | Secret |
|---|---|---|
| `ARM_CLIENT_ID` | Service principal `appId` | ✅ |
| `ARM_CLIENT_SECRET` | Service principal `password` | ✅ |
| `ARM_SUBSCRIPTION_ID` | Your Azure subscription ID | ✅ |
| `ARM_TENANT_ID` | Your Azure tenant ID | ✅ |

### 4. Create the Azure DevOps Service Connection

**Project Settings → Service Connections → New → Azure Resource Manager**

- Authentication: Service Principal (manual)
- Fill in the SP credentials from step 2
- Name it: `AzureServiceConnection`
- Grant access to all pipelines

### 5. Create the Production Environment with Approval Gate

**Pipelines → Environments → New Environment**

- Name: `production`
- Add approval: **Approvals and checks → Approvals → add your team lead or yourself**

### 6. Install tfenv and Pin the Terraform Version

```bash
# Install tfenv (macOS)
brew install tfenv

# Install tfenv (Linux)
git clone https://github.com/tfutils/tfenv.git ~/.tfenv
echo 'export PATH="$HOME/.tfenv/bin:$PATH"' >> ~/.bashrc

# Install and use the pinned version
tfenv install 1.7.5
tfenv use 1.7.5
```

The `.terraform-version` file in the repo root ensures tfenv automatically switches to the correct version when you enter the directory.

---

## Pipeline Walkthrough

```
PR opened / push to any branch
        │
        ▼
┌─────────────────────────────┐
│   STAGE 1: Validate & Plan  │
│                             │
│  terraform fmt -check       │  ← fails PR if code isn't formatted
│  terraform validate         │  ← catches syntax errors
│  terraform plan -out=tfplan │  ← plan saved as pipeline artifact
└─────────────────────────────┘
        │
        │  (only if merged to main)
        ▼
┌─────────────────────────────┐
│   Manual Approval Gate      │  ← team lead reviews and approves
└─────────────────────────────┘
        │
        ▼
┌─────────────────────────────┐
│   STAGE 2: Apply            │
│                             │
│  terraform init             │
│  terraform apply tfplan     │  ← applies the exact saved plan
└─────────────────────────────┘
```

**Why save the plan as an artifact?**
The apply stage uses the exact plan file produced in the plan stage. This means what your team reviewed and approved is precisely what gets applied — no drift between plan and apply.

---

## Version Management

### Terraform Binary

Pinned in two places for consistency between local and CI:

**.terraform-version** (used by tfenv locally)
```
1.7.5
```

**azure-pipelines.yml** (used by CI)
```yaml
- name: TF_VERSION
  value: '1.7.5'
```

Both must match. When upgrading Terraform, update both files in the same commit.

### Provider Versions

Pinned in `versions.tf`:

```hcl
terraform {
  required_version = "~> 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.90.0"
    }
  }
}
```

The `.terraform.lock.hcl` file pins the exact provider checksum. **This file must be committed to the repository.** It is what prevents "works on my machine" provider version conflicts across the team.

```bash
# After changing provider versions, regenerate the lock file
terraform init -upgrade
git add .terraform.lock.hcl
git commit -m "chore: upgrade azurerm provider to 3.90.0"
```

---

## Remote State

State is stored in Azure Blob Storage with automatic locking via blob leases — preventing two pipeline runs or two developers from applying simultaneously.

**Backend configuration in `versions.tf`:**

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "tfstate-rg"
    storage_account_name = "tfstate12345"
    container_name       = "tfstate"
    key                  = "prod.terraform.tfstate"
  }
}
```

**Never store state locally in production.** The `.gitignore` should exclude local state files:

```gitignore
*.tfstate
*.tfstate.backup
.terraform/
*.tfplan
```

---

## Local Development

```bash
# 1. Clone the repo — tfenv auto-switches Terraform version
git clone <your-repo>
cd <your-repo>

# 2. Authenticate to Azure
az login

# 3. Set environment variables (use a .env file, never commit credentials)
export ARM_CLIENT_ID="..."
export ARM_CLIENT_SECRET="..."
export ARM_SUBSCRIPTION_ID="..."
export ARM_TENANT_ID="..."

# 4. Initialize
terraform init

# 5. Format your code before committing
terraform fmt -recursive

# 6. Validate
terraform validate

# 7. Plan
terraform plan
```

> ⚠️ **Never run `terraform apply` locally against production.** All applies go through the pipeline so there is a full audit trail.

---

## Team Workflow

```
1. Branch off main
        │
        ▼
2. Write Terraform code
        │
        ▼
3. Run terraform fmt -recursive locally
        │
        ▼
4. Run terraform validate + terraform plan locally
        │
        ▼
5. Open a Pull Request
   → Pipeline runs fmt check, validate, plan automatically
   → Team reviews the plan output in the pipeline logs
        │
        ▼
6. PR approved and merged to main
        │
        ▼
7. Pipeline runs plan again, waits for manual approval
        │
        ▼
8. Approver reviews and approves in Azure DevOps
        │
        ▼
9. Pipeline applies — infrastructure updated
```

---

## Troubleshooting

### `Error acquiring the state lock`

Another process holds the state lock or a previous run crashed without releasing it.

```bash
# Check who holds the lock
az storage blob show \
  --account-name tfstate12345 \
  --container-name tfstate \
  --name prod.terraform.tfstate

# Force unlock (get the lock ID from the error message)
terraform force-unlock <LOCK_ID>
```

### `Error: Permission denied on terraform.tfstate`

```bash
chmod 644 terraform.tfstate
rm -f .terraform.tfstate.lock.info
```

### `fmt check failed in CI`

Run locally before pushing:

```bash
terraform fmt -recursive
git add -u
git commit -m "chore: terraform fmt"
```

### Provider version conflict

```bash
# Reinitialize and upgrade the lock file
terraform init -upgrade
git add .terraform.lock.hcl
git commit -m "chore: update provider lock file"
```

### Plan and apply are out of sync

This happens if someone merged another PR between your plan and apply. Re-run the pipeline from the beginning — the plan stage will produce a fresh plan against the current state.

---

## Security Notes

- All credentials are stored in Azure DevOps Variable Groups as **secret variables** — they are never echoed in logs
- The Service Principal should follow least-privilege — scope it to only the resource groups it needs, not the entire subscription if possible
- State files can contain sensitive values — ensure the Storage Account has private access only and enable Azure Storage encryption at rest
- Rotate the Service Principal secret regularly and update the Variable Group accordingly
