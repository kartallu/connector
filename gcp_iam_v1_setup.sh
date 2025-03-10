#!/bin/bash
#
# GCP IAM setup script – exact transition from the Azure IAM script.
#
# This script creates (or uses an existing) service account (i.e., an “application”),
# generates a key for it (i.e., the “secret”), creates a custom role, and assigns that role 
# to the service account in one or more projects.
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
#   If you want to create an organization-level custom role, export ORG_ID.
#     e.g.: export ORG_ID="1234567890"
#

# Use a safe prefix for service account names (allowed characters include hyphen)
PREFIX="ciscocsw-"
# Use a safe prefix for custom roles (allowed characters: letters, digits, underscores, and periods)
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

# Parse command-line arguments.
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
    sa_name="${PREFIX}app-${timestamp}"
    echo "Service account (application) name: $sa_name"
    # By default, assign the custom role to the default project.
    project_ids="$DEFAULT_PROJECT"
    # Build a role name using the safe role prefix.
    role_name="${ROLE_PREFIX}role_${timestamp}"
    echo "Custom role name: $role_name"
    # If ORG_ID is set, then an organization-level custom role is created.
    if [ -z "$ORG_ID" ]; then
         org_id=""
         echo "No organization ID provided; will create a project-level custom role."
    else
         org_id="$ORG_ID"
         echo "Organization ID: $org_id"
    fi
fi

#---------------------------------------------------
# Functions for service account (application) operations.
#---------------------------------------------------

create_new_service_account() {
    if [ "$interactive" == "true" ]; then
        echo "Enter the name for the new GCP service account (without the prefix):"
        read input_sa_name
        if [ -z "$input_sa_name" ]; then
            echo "Error: Service account name cannot be empty."
            exit 1
        fi
        # Replace underscores with hyphens to comply with naming rules.
        input_sa_name=$(echo "$input_sa_name" | tr '_' '-')
        sa_name="${PREFIX}${input_sa_name}"
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
    # Pause to allow the service account to propagate.
    sleep 10
    create_key_for_service_account "$sa_email"
}

use_existing_service_account() {
    echo "Listing existing service accounts in project $DEFAULT_PROJECT..."
    gcloud iam service-accounts list --project "$DEFAULT_PROJECT" --format="table(email,displayName)"
    echo "Enter the email of the existing service account to use as your application:"
    read sa_email_input
    if [ -z "$sa_email_input" ]; then
         echo "Error: Service account email cannot be empty."
         exit 1
    fi
    sa_email="$sa_email_input"
    create_key_for_service_account "$sa_email"
}

create_key_for_service_account() {
    local sa_email=$1
    echo "Creating key for service account $sa_email..."
    key_file="key_${timestamp}.json"
    gcloud iam service-accounts keys create "$key_file" \
         --iam-account="$sa_email" \
         --project "$DEFAULT_PROJECT"
    if [ $? -ne 0 ]; then
         echo "Failed to create key for service account."
         cleanup=true
         exit 1
    fi
    echo "Key created and saved to $key_file"
}

#---------------------------------------------------
# Function to assign the custom role to the service account in projects.
#---------------------------------------------------
assign_role_to_service_account() {
    local projects_list=$1
    local sa_email=$2
    local role_ref=$3

    IFS=',' read -r -a projects_array <<< "$projects_list"
    for proj in "${projects_array[@]}"; do
         echo "Assigning role $role_ref to service account $sa_email in project $proj..."
         gcloud projects add-iam-policy-binding "$proj" --member="serviceAccount:$sa_email" --role="$role_ref"
         if [ $? -ne 0 ]; then
             echo "Failed to assign role in project $proj."
             cleanup=true
             exit 1
         fi
         echo "Role assigned in project $proj."
    done
}

#---------------------------------------------------
# Cleanup function.
#---------------------------------------------------
cleanup_resources() {
    # If a new service account was created by this script, delete it.
    if [ "$new_service_account" = true ]; then
         echo "Deleting service account $sa_email from project $DEFAULT_PROJECT..."
         gcloud iam service-accounts delete "$sa_email" \
              --project "$DEFAULT_PROJECT" --quiet
    fi

    IFS=',' read -r -a projects_array <<< "$project_ids"
    for proj in "${projects_array[@]}"; do
         if [ -n "$org_id" ]; then
             role_ref="organizations/$org_id/roles/$role_name"
         else
             role_ref="projects/$DEFAULT_PROJECT/roles/$role_name"
         fi
         echo "Removing IAM binding for role $role_ref for service account $sa_email in project $proj..."
         gcloud projects remove-iam-policy-binding "$proj" \
              --member="serviceAccount:$sa_email" \
              --role="$role_ref" --condition=None --quiet
    done

    # Delete the custom role using the proper deletion syntax.
    if [ -n "$org_id" ]; then
         echo "Deleting custom role $role_name from organization $org_id..."
         gcloud iam roles delete "$role_name" --organization="$org_id" --quiet
    else
         echo "Deleting custom role $role_name from project $DEFAULT_PROJECT..."
         gcloud iam roles delete "$role_name" --project="$DEFAULT_PROJECT" --quiet
    fi
}

#---------------------------------------------------
# Main logic based on mode.
#---------------------------------------------------
if [ "$mode" == "cleanup" ]; then
    echo "Cleanup mode selected."
    echo "Enter the service account email to clean up:"
    read sa_email
    echo "Enter the custom role name to clean up:"
    read role_name
    if [ -z "$role_name" ]; then
         echo "Role name unavailable."
         exit 0
    fi
    # If no organization ID is set, assume project-level.
    if [ -z "$org_id" ]; then
         project_ids="$DEFAULT_PROJECT"
    fi
    cleanup_resources
    echo "Cleanup finished."
    exit 0
elif [ "$mode" == "iam" ]; then
    echo "Setting up required IAM resources on GCP..."
else
    echo "Invalid mode. Please choose 'iam' or 'cleanup'."
    exit 1
fi

# Set a trap to run cleanup if an error occurs.
trap 'if [ "$cleanup" = true ]; then cleanup_resources; fi' EXIT

#---------------------------------------------------
# Service Account (Application) Creation
#---------------------------------------------------
if [ "$interactive" == "true" ]; then
    echo "Do you want to create a new service account (application) or use an existing one? (new/existing):"
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
    echo "Invalid choice. Please choose 'new' or 'existing'."
    exit 1
fi

echo ""
#---------------------------------------------------
# Projects Selection for Role Binding.
#---------------------------------------------------
echo "Fetching available projects..."
gcloud projects list --format="table(projectId, name)"

if [ "$interactive" == "true" ]; then
    echo ""
    echo "Enter project IDs (comma-separated, no spaces) in which to assign the custom role."
    echo "To use the default project ($DEFAULT_PROJECT), enter: default"
    read input_projects
    if [ "$input_projects" == "default" ]; then
         project_ids="$DEFAULT_PROJECT"
    else
         project_ids="$input_projects"
    fi
fi

if [ "$project_ids" == "all" ]; then
    project_ids=$(gcloud projects list --format="value(projectId)" | paste -sd, -)
fi

#---------------------------------------------------
# Custom Role Creation
#---------------------------------------------------
if [ "$interactive" == "true" ]; then
    echo "Enter a custom role name (without the prefix):"
    read input_role_name
    if [ -z "$input_role_name" ]; then
         echo "Error: Role name cannot be empty."
         cleanup=true
         exit 1
    fi
    role_name="${ROLE_PREFIX}${input_role_name}"
fi

# Create a custom role definition file.
cat > /tmp/role.yaml <<EOF
title: "$role_name"
description: "Cisco Secure Workload (CSW) generated custom role."
stage: "GA"
includedPermissions:
  - compute.instances.get
  - compute.instances.list
  - compute.networks.get
  - compute.networks.list
  - compute.subnetworks.get
  - compute.subnetworks.list
  - compute.firewalls.list
  - compute.firewalls.get
  - compute.addresses.list
  - compute.addresses.get
  - storage.buckets.get
  - storage.objects.get
  - resourcemanager.projects.getIamPolicy
  - iam.roles.get
  - iam.roles.list
EOF

echo ""
# Create the custom role.
if [ -n "$org_id" ]; then
    echo "Creating custom role in organization $org_id using /tmp/role.yaml..."
    gcloud iam roles create "$role_name" --organization="$org_id" --file=/tmp/role.yaml
    role_ref="organizations/$org_id/roles/$role_name"
else
    echo "Creating custom role in project $DEFAULT_PROJECT using /tmp/role.yaml..."
    gcloud iam roles create "$role_name" --project="$DEFAULT_PROJECT" --file=/tmp/role.yaml
    role_ref="projects/$DEFAULT_PROJECT/roles/$role_name"
fi

if [ $? -ne 0 ]; then
    echo "Custom role creation failed."
    cleanup=true
    exit 1
fi

echo ""
echo "Custom role created successfully with role reference: $role_ref"

#---------------------------------------------------
# Bind the custom role to the service account in selected projects.
#---------------------------------------------------
assign_role_to_service_account "$project_ids" "$sa_email" "$role_ref"

#---------------------------------------------------
# Output Credentials and Cleanup Information.
#---------------------------------------------------
echo ""
echo "-------------------------------------------------------"
echo "Credentials required to onboard the GCP Connector:"
if [ -n "$org_id" ]; then
    echo "Organization ID: $org_id"
else
    echo "Project ID: $DEFAULT_PROJECT"
fi
echo "Service Account Email: $sa_email"
echo "Key File: key_${timestamp}.json"
echo "Role Reference: $role_ref"
echo "-------------------------------------------------------"
echo "Information required to initiate cleanup (Save these details!!):"
echo "  Service Account Email: $sa_email"
echo "  Custom Role Name: $role_name"
if [ -n "$org_id" ]; then
    echo "  Organization ID: $org_id"
else
    echo "  Project ID: $DEFAULT_PROJECT"
fi
echo "-------------------------------------------------------"
echo ""

# Disable cleanup on successful completion.
cleanup=false
