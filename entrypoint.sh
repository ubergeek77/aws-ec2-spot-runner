#!/bin/bash

# Exit on error
set -e

# Change to the app dir
cd /app

# Get input variables from GitHub Actions
aws_access_key_id=$(jq -r '.["aws-access-key-id"]' <<<"$INPUTS")
aws_default_region=$(jq -r '.["aws-default-region"]' <<<"$INPUTS")
aws_secret_access_key=$(jq -r '.["aws-secret-access-key"]' <<<"$INPUTS")
dry_run=$(jq -r '.["dry-run"]' <<<"$INPUTS")
ec2_ami=$(jq -r '.["ec2-ami"]' <<<"$INPUTS")
ec2_instance_type=$(jq -r '.["ec2-instance-type"]' <<<"$INPUTS")
ec2_keypair_name=$(jq -r '.["ec2-keypair-name"]' <<<"$INPUTS")
ec2_security_group_id=$(jq -r '.["ec2-security-group-id"]' <<<"$INPUTS")
ec2_timeout=$(jq -r '.["ec2-timeout"]' <<<"$INPUTS")
ec2_zone=$(jq -r '.["ec2-zone"]' <<<"$INPUTS")
ephemeral=$(jq -r '.["ephemeral"]' <<<"$INPUTS")
github_organization=$(jq -r '.["github-organization"]' <<<"$INPUTS")
github_repo=$(jq -r '.["github-repo"]' <<<"$INPUTS")
github_token=$(jq -r '.["github-token"]' <<<"$INPUTS")
runner_arch=$(jq -r '.["runner-arch"]' <<<"$INPUTS")
shutdown_label=$(jq -r '.["shutdown-label"]' <<<"$INPUTS")
runner_version=$(jq -r '.["runner-version"]' <<<"$INPUTS")
vm_user=$(jq -r '.["vm-user"]' <<<"$INPUTS")
volume_name=$(jq -r '.["volume-name"]' <<<"$INPUTS")
volume_size=$(jq -r '.["volume-size"]' <<<"$INPUTS")

# Calculate the GitHub API URL base
GITHUB_API_BASE="https://api.github.com"
if [[ -n "${github_organization}" ]]; then
	GITHUB_API_BASE="${GITHUB_API_BASE}/orgs/${github_organization}"
else
	GITHUB_API_BASE="${GITHUB_API_BASE}/repos/${github_repo}"
fi

# Start an EC2 Spot Instance and install a GitHub Actions Runner
function ec2_start() {
	(
		# Exit on error
		set -e

		# We need the template files
		if [[ ! -f ./user-data-template.sh ]]; then
			echo >&2 "--> FATAL: Not found: ./user-data-template.sh"
			exit 1
		fi

		if [[ ! -f ./spot-instance-launch-template.json ]]; then
			echo >&2 "--> FATAL: Not found: ./spot-instance-launch-template.json"
			exit 1
		fi

		# Pre-check variables
		variables=(
			aws_access_key_id
			aws_default_region
			aws_secret_access_key
			ec2_ami
			ec2_instance_type
			ec2_keypair_name
			ec2_security_group_id
			ec2_timeout
			ec2_zone
			github_token
			runner_arch
			runner_version
			vm_user
			volume_name
			volume_size
		)

		# Empty variables list
		empty_variables=()

		# Iterate over the variables
		for var in "${variables[@]}"; do
			# Check if the variable is empty
			if [[ -z ${!var} ]]; then
				empty_variables+=("$var")
			fi
		done

		# Print the list of empty variables
		if [[ ! ${#empty_variables[@]} -eq 0 ]]; then
			echo >&2 "--> ERROR: You are missing the following parameters:"
			for var in "${empty_variables[@]}"; do
				echo >&2 "  $var" | sed -e 's|_|-|g'
			done
			exit 1
		fi

		# We need either github_organization or github_repo
		if [[ -z "${github_repo}" ]] && [[ -z "${github_organization}" ]]; then
			echo >&2 "--> You must specify one of the following:"
			echo >&2 "  github-organization"
			echo >&2 "  github-repo"
			exit 1
		fi

		# If runner_version is 'latest', detect the latest version
		# Make the comparison case-insensitive by making the entire variable lowercase
		runner_version="${runner_version,,}"
		if [[ "${runner_version}" == "latest" ]]; then
			echo "--> Detecting latest GitHub Actions version"
			runner_version="$(curl -s https://api.github.com/repos/actions/runner/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')"
			echo "--> Latest GitHub Actions version: $runner_version"
		fi

		# Clean the version string
		if [[ $runner_version == v* ]]; then
			runner_version="${runner_version#v}"
		fi

		# Generate a unique label for this Runner
		RUNNER_LABEL="spot-runner-${runner_arch}-$(uuidgen)"

		# Set the label output
		echo "label=$RUNNER_LABEL" >>$GITHUB_OUTPUT

		# Define EPHEMERAL if ephemeral==true
		EPHEMERAL_FMT="No"
		if [[ "${ephemeral}" == "true" ]] || [[ "${ephemeral}" == "1" ]]; then
			EPHEMERAL="--ephemeral"
			EPHEMERAL_FMT="Yes"
		fi

		# Pre-check the credentials the user gave
		# If this fails, the EC2 instance might start but the Runner can never connect, so we fail
		echo "--> Checking GitHub credentials"
		RESPONSE=$(curl -sL -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${github_token}" "${GITHUB_API_BASE}/actions/runners") || true
		if [[ -z "${RESPONSE}" ]] || [[ $(echo "$RESPONSE" | grep '"message": "Not Found"') ]] || [[ $(echo "$RESPONSE" | grep '"message": "Bad credentials"') ]]; then
			echo >&2 "--> GitHub connection failed. Please check your token, and set 'github-organization' if needed."
			exit 1
		fi

		# Compile the userdata template
		echo "--> Compiling userdata template"
		USERDATA=$(sed -e "s|{{ GH_REPO }}|${github_repo}|g" \
			-e "s|{{ GH_ORG }}|${github_organization}|g" \
			-e "s|{{ GH_TOKEN }}|${github_token}|g" \
			-e "s|{{ RUNNER_ARCH }}|${runner_arch}|g" \
			-e "s|{{ RUNNER_VERSION }}|${runner_version}|g" \
			-e "s|{{ RUNNER_LABEL }}|${RUNNER_LABEL}|g" \
			-e "s|{{ TIMEOUT_SECONDS }}|${ec2_timeout}|g" \
			-e "s|{{ EPHEMERAL }}|${EPHEMERAL}|g" \
			-e "s|{{ USER_NONROOT }}|${vm_user}|g" ./user-data-template.sh | base64 -w 0)

		# Add a mask for the encoded userdata
		echo "::add-mask::$USERDATA"

		# Compile the launch template
		echo "--> Compiling launch template"
		sed -e "s|{{ EC2_AMI }}|${ec2_ami}|g" \
			-e "s|{{ EC2_KEYPAIR }}|${ec2_keypair_name}|g" \
			-e "s|{{ EC2_SG }}|${ec2_security_group_id}|g" \
			-e "s|{{ EC2_TYPE }}|${ec2_instance_type}|g" \
			-e "s|{{ EC2_USERDATA }}|${USERDATA}|g" \
			-e "s|{{ VOLUME_NAME }}|${volume_name}|g" \
			-e "s|{{ VOLUME_SIZE }}|${volume_size}|g" \
			-e "s|{{ EC2_ZONE }}|${ec2_zone}|g" ./spot-instance-launch-template.json >./launch.json

		# Launch the runner
		export AWS_ACCESS_KEY_ID="${aws_access_key_id}"
		export AWS_SECRET_ACCESS_KEY="${aws_secret_access_key}"
		export AWS_DEFAULT_REGION="${aws_default_region}"
		echo "--> Launch Specifications:"
		echo "---->        Runner Label: ${RUNNER_LABEL}"
		echo "---->      Runner Version: ${runner_version}"
		echo "----> Runner Architecture: ${runner_arch}"
		echo "---->    Ephemeral Runner: ${EPHEMERAL_FMT}"
		echo "---->   EC2 Instance Type: ${ec2_instance_type}"
		echo "---->    EC2 Instance AMI: ${ec2_ami}"
		echo "---->     EC2 Volume Size: ${volume_size}GiB"
		echo "---->     EC2 Volume Name: ${volume_name}"

		# Pre-Check if the runner the user provided exists
		echo "--> Checking Actions Runner version"
		ACTIONS_ARCHIVE_RESULT=$(curl -Is -w "%{http_code}" "https://github.com/actions/runner/releases/download/v${runner_version}/actions-runner-linux-${runner_arch}-${runner_version}.tar.gz" -o /dev/null)
		if [[ "${ACTIONS_ARCHIVE_RESULT}" != "302" ]]; then
			echo >&2 "--> ERROR: Could not find archive for the specified runner."
			echo >&2 "--> HTTP Response: ${ACTIONS_ARCHIVE_RESULT}"
			echo >&2 "--> Calculated url:"
			echo >&2 "----> https://github.com/actions/runner/releases/download/v${runner_version}/actions-runner-linux-${runner_arch}-${runner_version}.tar.gz"
			echo >&2 ""
			echo >&2 "--> The Runner architecture or version you have specified may not exist."
			echo >&2 "--> Supported architectures:"
			echo >&2 "----> x64"
			echo >&2 "----> arm"
			echo >&2 "----> arm64"
			echo >&2 ""
			echo >&2 "--> Check the official release page for a list of supported versions:"
			echo >&2 "----> https://github.com/actions/runner/releases"
			exit 1
		fi

		# Respect dry run
		if [[ "${dry_run}" == "true" ]] || [[ "${dry_run}" == "1" ]]; then
			echo "--> Dry run; NOT launching EC2 Spot Runner"
			return 0
		fi

		# Launch the instance
		echo "--> Requesting Spot Instance"
		aws ec2 request-spot-instances --instance-count 1 --type "one-time" --tag-specifications "ResourceType=spot-instances-request,Tags=[{Key=GH_RUNNER_LABEL,Value=${RUNNER_LABEL}}]" --launch-specification file://launch.json >/dev/null 2>&1
		echo "--> Spot Instance requested"

		# Verify the instance was launched successfully
		# Wait for up to 5 minutes, 10 seconds between checks
		loopcount=0
		while [ $loopcount -le 30 ]; do
			((++loopcount))
			unset INSTANCE_ID
			echo "--> Waiting for instance to start ($loopcount/30)"
			sleep 10
			INSTANCE_ID=$(aws ec2 describe-spot-instance-requests --no-cli-pager | jq -r ".SpotInstanceRequests[] | select(.Tags[]? | .Key==\"GH_RUNNER_LABEL\" and .Value==\"${RUNNER_LABEL}\") | select(.State==\"active\") | .InstanceId") || true

			# Placeholder condition for if block
			if [[ -n "${INSTANCE_ID}" ]]; then
				echo "--> Instance is running!"
				break
			fi
		done

		if [[ -z "${INSTANCE_ID}" ]]; then
			echo >&2 "--> Instance failed to launch!"
			exit 1
		fi

		# Verify the runner launched successfully
		# Wait for up to 10 minutes, 60 seconds between checks
		loopcount=0
		while [ $loopcount -le 20 ]; do
			((++loopcount))
			unset RESPONSE
			unset RUNNER_COUNT
			unset RUNNER_INFO
			unset RUNNER_STATUS
			echo "--> Waiting for runner to start ($loopcount/20)"
			sleep 30
			RESPONSE=$(curl -sL -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${github_token}" "${GITHUB_API_BASE}/actions/runners") || true

			# Check if the response is invalid
			if [[ $(echo "$RESPONSE" | grep '"message": "Not Found"') ]] || [[ $(echo "$RESPONSE" | grep '"message": "Bad credentials"') ]]; then
				echo >&2 "--> Failed to connect to GitHub, please check your token"
				exit 1
			fi

			# If it's blank for some reason, we just continue
			if [[ -z "${RESPONSE}" ]]; then
				continue
			fi

			# Read information about the runners
			RUNNER_COUNT=$(echo "$RESPONSE" | jq -r '.total_count')
			RUNNER_INFO=$(echo "$RESPONSE" | jq -r '.runners')

			if [[ "$RUNNER_COUNT" -gt 0 ]]; then
				RUNNER_STATUS=$(echo "$RUNNER_INFO" | jq -r --arg name "$RUNNER_LABEL" '.[] | select(.name == $name) | .status')

				if [[ "${RUNNER_STATUS}" == "online" ]]; then
					echo "--> Runner online: $RUNNER_LABEL"
					break
				fi
			else
				continue
			fi
		done

		if [[ "${RUNNER_STATUS}" != "online" ]]; then
			echo >&2 "--> Runner failed to start"
			exit 1
		fi

	)
}

# Terminate an EC2 Spot Instance for the given label
function ec2_stop() {
	(
		# Exit on error
		set -e

		# Pre-check variables
		variables=(
			aws_access_key_id
			aws_secret_access_key
			aws_default_region
			shutdown_label
		)

		# Empty variables list
		empty_variables=()

		# Iterate over the variables
		for var in "${variables[@]}"; do
			# Check if the variable is empty
			if [[ -z ${!var} ]]; then
				empty_variables+=("$var")
			fi
		done

		# Print the list of empty variables
		if [[ ! ${#empty_variables[@]} -eq 0 ]]; then
			echo "ERROR: You are missing the following parameters:"
			for var in "${empty_variables[@]}"; do
				echo "$var" | sed -e 's|_|-|g'
			done
			exit 1
		fi

		# Check if we can deregister
		CAN_DEREGISTER="true"
		if [[ -z ${github_token} ]] || [[ -z ${github_repo} && -z ${github_organization} ]]; then
			CAN_DEREGISTER="false"
			echo >&2 "--> WARN: Will not be able to automatically deregister Runner."
			echo >&2 "--> To automatically deregister Runner, please specify:"
			echo >&2 "----> github-token, and one of:"
			echo >&2 "------> github-organization"
			echo >&2 "------> github-repo"
		fi

		# De-register the runner first
		# Attempt to do this once, but if it fails, make it non fatal and continue to VM termination
		# Do it in a subshell to mask any errors
		(
			if [[ "${CAN_DEREGISTER}" == "true" ]]; then
				echo "--> Deregistering Runner"
				RESPONSE=$(curl -sL -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${github_token}" "${GITHUB_API_BASE}/actions/runners") || true
				if [[ -z "${RESPONSE}" ]] || [[ $(echo "$RESPONSE" | grep '"message": "Not Found"') ]] || [[ $(echo "$RESPONSE" | grep '"message": "Bad credentials"') ]]; then
					echo >&2 "--> WARN: Failed to connect to GitHub, unable to deregister Runner"
					exit 1
				fi

				# If the ID isn't found, it was probably already deregistered
				# This is expected for ephemeral runners
				RUNNER_ID=$(echo "$RESPONSE" | jq -r --arg name "$shutdown_label" '.runners[] | select(.name == $name) | .id')
				if [[ -z "${RUNNER_ID}" ]]; then
					echo "--> Already deregistered: ${shutdown_label}"
					exit 0
				fi

				# Send the DELETE request
				echo "--> Deregistering Runner from GitHub: $shutdown_label"
				curl -sL -X DELETE -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${github_token}" "${GITHUB_API_BASE}/actions/runners/${RUNNER_ID}" >/dev/null 2>&1
				DELETE_RESULT=$?
				if [[ "${DELETE_RESULT}" == "0" ]]; then
					echo "--> Runner deregistered: $shutdown_label"
				else
					echo >&2 "--> WARN: Deregister request failed with non-zero exit code (${DELETE_RESULT})"
				fi
			fi
		) || true

		# Detect instance ID
		echo "--> Detecting Instance ID for runner: ${shutdown_label}"
		export AWS_ACCESS_KEY_ID="${aws_access_key_id}"
		export AWS_SECRET_ACCESS_KEY="${aws_secret_access_key}"
		export AWS_DEFAULT_REGION="${aws_default_region}"

		# Respect dry run
		if [[ "${dry_run}" == "true" ]] || [[ "${dry_run}" == "1" ]]; then
			echo "--> Dry run; NOT terminating EC2 Spot Runner"
			exit 0
		fi
		INSTANCE_ID=$(aws ec2 describe-spot-instance-requests --no-cli-pager | jq -r ".SpotInstanceRequests[] | select(.Tags[]? | .Key==\"GH_RUNNER_LABEL\" and .Value==\"${shutdown_label}\") | select(.State==\"active\") | .InstanceId") || true

		# Terminate the instance
		if [[ -n "${INSTANCE_ID}" ]]; then
			echo "--> Sending termination request"
			aws ec2 terminate-instances --instance-ids $INSTANCE_ID >/dev/null 2>&1
			echo "--> Termination request sent"
		else
			echo >&2 "--> Could not find an instance for runner: ${shutdown_label}"
			exit 1
		fi
	)
}

# Decide what to do
if [[ -z "${shutdown_label}" ]]; then
	echo "--> Operation: Launch a new runner on an EC2 Spot Instance"
	ec2_start
else
	echo "--> Operation: Deregister Runner and terminate its EC2 Spot Instance"
	ec2_stop
fi
