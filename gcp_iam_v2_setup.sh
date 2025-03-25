#!/bin/bash
#
# GCP IAM setup script – modeled after the Azure IAM setup.
#
# This script creates (or uses an existing) service account (the “application”),
# generates a key for it, creates a custom role with an extended permission set,
# assigns that role (both conditionally and unconditionally) to the service account
# in one or more projects, and then prints the credentials required for onboarding your connector.
#
# Modes:
#   iam     : Setup mode (default)
#   cleanup : Cleanup mode.
#
# Options:
#   -m, --mode          Mode of operation (iam (default) or cleanup)
#   -i, --interactive   Interactive mode (true or false (default))
#
# Environment:
#   (Set ORG_ID if you want to create an organization-level custom role.)
#

# Use safe prefixes. For service accounts, hyphens are allowed.
SA_PREFIX="ciscocsw-app-"
# For custom roles, only letters, digits, underscores, and periods are allowed.
ROLE_PREFIX="ciscocsw_"

new_service_account=false
cleanup=false
mode="iam"
interactive=false
timestamp=$(date +%s)

# Function to display usage.
usage() {
    echo "Usage: $0 -m <mode> -i <interactive>"
    echo "  -m, --mode          Mode of operation (iam (default) or cleanup)"
    echo "  -i, --interactive   Interactive mode (true or false (default))"
    exit 1
}

# Parse command line arguments.
while getopts ":m:i:" opt; do
    case ${opt} in
        m )
            mode=$OPTARG
            ;;
        i )
            interactive=$OPTARG
            ;;
        \? )
            echo "Invalid option: $OPTARG" 1>&2
            usage
            ;;
        : )
            echo "Option -$OPTARG requires an argument." 1>&2
            usage
            ;;
    esac
done
shift $((OPTIND -1))

# Validate mode.
if [ "$mode" != "iam" ] && [ "$mode" != "cleanup" ]; then
    echo "Error: Mode must be 'iam' or 'cleanup'."
    usage
fi

# Validate interactive.
if [ "$interactive" != "true" ] && [ "$interactive" != "false" ]; then
    echo "Error: Interactive must be 'true' or 'false'."
    usage
fi

active_account=$(gcloud config get-value account 2>/dev/null)
if [ -z "$active_account" ]; then
    echo "No active gcloud account detected. Initiating login..."
    gcloud auth login
    # Re-check active account after login
    active_account=$(gcloud config get-value account 2>/dev/null)
    if [ -z "$active_account" ]; then
         echo "Login failed. Exiting."
         exit 1
    fi
fi

# Get the default project from gcloud configuration.
DEFAULT_PROJECT=$(gcloud config get-value project 2>/dev/null)
if [ -z "$DEFAULT_PROJECT" ]; then
    echo "No default project set. Please set one with: gcloud config set project PROJECT_ID"
    exit 1
fi

# Set default values if not in interactive mode.
if [ "$interactive" == "false" ]; then
    app_choice="new"
    # In GCP the "application" is a service account.
    sa_name="${SA_PREFIX}${timestamp}"
    echo "Service account (application) name: $sa_name"
    # In non-interactive mode, assign the role only to the default project.
    project_ids="$DEFAULT_PROJECT"
    role_name="${ROLE_PREFIX}role_${timestamp}"
    echo "Custom role name: $role_name"
    if [ -z "$ORG_ID" ]; then
         org_id=""
         echo "No organization ID provided; creating a project-level custom role."
    else
         org_id="$ORG_ID"
         echo "Organization ID: $org_id"
    fi
fi

#---------------------------------------------------
# Functions for service account operations.
#---------------------------------------------------

create_new_service_account() {
    if [ "$interactive" == "true" ]; then
        echo "Enter the name for the new GCP service account (without prefix):"
        read input_name
        if [ -z "$input_name" ]; then
            echo "Error: Service account name cannot be empty."
            exit 1
        fi
        # Replace underscores with hyphens if any.
        input_name=$(echo "$input_name" | tr '_' '-')
        sa_name="${SA_PREFIX}${input_name}"
    fi

    echo "Creating new service account: $sa_name in project $DEFAULT_PROJECT..."
    gcloud iam service-accounts create "$sa_name" \
         --display-name "$sa_name" \
         --project "$DEFAULT_PROJECT"
    if [ $? -ne 0 ]; then
         echo "Failed to create service account."
         exit 1
    fi
    new_service_account=true
    # GCP auto-generates the service account email.
    sa_email="${sa_name}@${DEFAULT_PROJECT}.iam.gserviceaccount.com"
    echo "Service account created: $sa_email"
    # Wait for propagation.
    sleep 10
    create_key_for_service_account "$sa_email"
}

use_existing_service_account() {
    echo "Listing existing service accounts in project $DEFAULT_PROJECT..."
    gcloud iam service-accounts list --project "$DEFAULT_PROJECT" --format="table(email,displayName)"
    echo "Enter the email of the existing service account:"
    read input_email
    if [ -z "$input_email" ]; then
         echo "Error: Service account email cannot be empty."
         exit 1
    fi
    sa_email="$input_email"
    create_key_for_service_account "$sa_email"
}

# Create the key file for the service account, but do not activate it immediately.
create_key_for_service_account() {
    local email=$1
    echo "Creating key for service account $email..."
    key_file="key_${timestamp}.json"
    gcloud iam service-accounts keys create "$key_file" \
         --iam-account="$email" \
         --project "$DEFAULT_PROJECT"
    if [ $? -ne 0 ]; then
         echo "Failed to create key for service account."
         cleanup=true
         exit 1
    fi
    echo "Key created and saved to $key_file"
}

#---------------------------------------------------
# Function to assign the custom role to the service account.
#---------------------------------------------------
assign_role_to_service_account() {
    local proj_list=$1
    local email=$2
    local role_ref=$3

    IFS=',' read -r -a proj_array <<< "$proj_list"
    for proj in "${proj_array[@]}"; do
         echo "Assigning role binding $role_ref to $email in project $proj..."
         gcloud projects add-iam-policy-binding "$proj" \
              --member="serviceAccount:$email" \
              --role="$role_ref" 
         if [ $? -ne 0 ]; then
             echo "Failed to assign role binding in project $proj."
             cleanup=true
             exit 1
         fi
         echo "Role binding assigned in project $proj."
    done
}

#---------------------------------------------------
# Cleanup function.
#---------------------------------------------------
cleanup_resources() {
    if [ "$new_service_account" = true ]; then
         echo "Deleting service account $sa_email from project $DEFAULT_PROJECT..."
         gcloud iam service-accounts delete "$sa_email" --project "$DEFAULT_PROJECT" --quiet
    fi
    if [ -n "$org_id" ]; then
         echo "Deleting custom role $role_name from organization $org_id..."
         gcloud iam roles delete "$role_name" --organization="$org_id" --quiet
    else
         echo "Deleting custom role $role_name from project $DEFAULT_PROJECT..."
         gcloud iam roles delete "$role_name" --project "$DEFAULT_PROJECT" --quiet
    fi
}

#---------------------------------------------------
# Main logic based on mode.
#---------------------------------------------------
if [ "$mode" == "cleanup" ]; then
    # Check that the active account is not a service account
    active_account=$(gcloud config get-value account 2>/dev/null)
    if [[ "$active_account" == "ciscocsw-app-"* ]]; then
        echo "Error: Cleanup mode must be run with a user account with sufficient privileges."
        echo "Please switch the active account using:"
        echo "  gcloud config set account YOUR_USER_ACCOUNT_EMAIL"
        exit 1
    fi

    echo "Cleanup mode selected."
    echo "Enter service account email to delete:"
    read sa_email
    echo "Enter custom role name to delete:"
    read role_name
    cleanup_resources
    echo "Cleanup finished."
    exit 0
fi
elif [ "$mode" == "iam" ]; then
    echo "Setting up required IAM resources..."
else
    echo "Invalid mode."
    exit 1
fi

# Register a trap for cleanup on error.
trap 'if [ "$cleanup" = true ]; then cleanup_resources; fi' EXIT

#---------------------------------------------------
# Service Account Creation / Selection
#---------------------------------------------------
if [ "$interactive" == "true" ]; then
    echo "Do you want to create a new service account or use an existing one? (new/existing):"
    read app_choice
    if [ -z "$app_choice" ]; then
         echo "Error: Choice cannot be empty."
         exit 1
    fi
fi

if [ "$app_choice" == "new" ]; then
    create_new_service_account
elif [ "$app_choice" == "existing" ]; then
    use_existing_service_account
else
    echo "Invalid choice. Exiting."
    exit 1
fi

#---------------------------------------------------
# Custom Role Creation
#---------------------------------------------------
if [ "$interactive" == "true" ]; then
    echo "Enter custom role name (without prefix):"
    read input_role
    if [ -z "$input_role" ]; then
         echo "Error: Role name cannot be empty."
         exit 1
    fi
    role_name="${ROLE_PREFIX}role_${input_role}"
fi

cat > /tmp/role.json <<EOF
{
  "title": "$role_name",
  "description": "Cisco Secure Workload (CSW) generated custom role with permissions for compute, networking, container clusters, and storage.",
  "stage": "GA",
  "includedPermissions": [
    "compute.firewallPolicies.get",
    "compute.firewallPolicies.list",
    "compute.firewallPolicies.use",
    "compute.firewallPolicies.update",
    "compute.firewallPolicies.create",
    "compute.globalOperations.get",
    "compute.instances.get",
    "compute.instances.list",
    "compute.instances.getEffectiveFirewalls",
    "compute.networks.get",
    "compute.networks.list",
    "compute.networks.getEffectiveFirewalls",
    "compute.networks.setFirewallPolicy",
    "compute.subnetworks.get",
    "compute.subnetworks.list",
    "compute.firewalls.list",
    "compute.firewalls.create",
    "compute.firewalls.update",
    "compute.firewalls.delete",
    "container.clusters.list",
    "storage.buckets.get",
    "storage.objects.get",
    "resourcemanager.projects.getIamPolicy",
    "iam.roles.get",
    "iam.roles.list",
    "iam.roles.delete",
    "iam.serviceAccounts.get",
    "iam.serviceAccounts.list",
    "iam.serviceAccounts.create",
  ]
}
EOF

echo "Creating custom role in project $DEFAULT_PROJECT using /tmp/role.json..."
gcloud iam roles create "$role_name" --project="$DEFAULT_PROJECT" --file=/tmp/role.json
if [ $? -ne 0 ]; then
    echo "Custom role creation failed."
    cleanup=true
    exit 1
fi
role_ref="projects/$DEFAULT_PROJECT/roles/$role_name"
echo "Custom role created successfully with role reference: $role_ref"

#---------------------------------------------------
# Role Assignment
#---------------------------------------------------
if [ "$interactive" == "true" ]; then
    echo "Enter project IDs (comma-separated, no spaces) to assign the role (default is $DEFAULT_PROJECT):"
    read input_projects
    if [ "$input_projects" == "" ]; then
         project_ids="$DEFAULT_PROJECT"
    else
         project_ids="$input_projects"
    fi
fi

assign_role_to_service_account "$project_ids" "$sa_email" "$role_ref"

#---------------------------------------------------
# Output Credentials for Onboarding and Download Key File
#---------------------------------------------------
echo "-------------------------------------------------------"
echo "Credentials required to onboard the GCP Connector:"
echo "Project ID: $DEFAULT_PROJECT"
echo "Service Account Email: $sa_email"
echo "Key File: $key_file"
echo "Role Reference: $role_ref"
echo "-------------------------------------------------------"
echo "Information required to initiate cleanup (Save these details!!):"
echo "  Service Account Email: $sa_email"
echo "  Custom Role Name: $role_name"
echo "  Project ID: $DEFAULT_PROJECT"
echo "-------------------------------------------------------"

echo "Initiating download of key file ($key_file) to your local machine..."
cloudshell download "$key_file"

#---------------------------------------------------
# Optional: Activate the service account for connector use.
#---------------------------------------------------
echo "Note: The IAM resources were created using your user account."
echo "Activating the service account now will switch your active credentials."
echo "Do you want to activate the service account for connector use? (yes/no)"
read activate_choice
if [ "$activate_choice" == "yes" ]; then
    echo "Activating service account using key file $key_file..."
    gcloud auth activate-service-account --key-file="$key_file"
    if [ $? -ne 0 ]; then
         echo "Failed to activate service account."
         exit 1
    fi
    echo "Service account activated."
else
    echo "Service account activation skipped."
fi

# Reset cleanup flag upon success.
cleanup=false
