#!/bin/bash

# Set up variables
GH_REPO="{{ GH_REPO }}"
GH_ORG="{{ GH_ORG }}"
GH_TOKEN="{{ GH_TOKEN }}"
RUNNER_ARCH="{{ RUNNER_ARCH }}"
RUNNER_VERSION="{{ RUNNER_VERSION }}"
RUNNER_LABEL="{{ RUNNER_LABEL }}"
USER_NONROOT="{{ USER_NONROOT }}"
TIMEOUT_SECONDS="{{ TIMEOUT_SECONDS }}"

# Calculate the GitHub API URL base and Runner URL to use
GITHUB_API_BASE="https://api.github.com"
if [[ -n "${GH_ORG}" ]]; then
	RUNNER_URL="https://github.com/${GH_ORG}"
	GITHUB_API_BASE="${GITHUB_API_BASE}/orgs/${GH_ORG}"
else
	RUNNER_URL="https://github.com/${GH_REPO}"
	GITHUB_API_BASE="${GITHUB_API_BASE}/repos/${GH_REPO}"
fi

# Use sudo if available
SUDOCMD="sudo"
SUDO_AS="${SUDOCMD} -u ${USER_NONROOT}"
if ! command -v $SUDOCMD &>/dev/null; then
	unset SUDOCMD
	unset $SUDO_AS
fi

# Noninteractive
export DEBIAN_FRONTEND=noninteractive

# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
$SUDOCMD sh get-docker.sh

# Create the docker group if needed
if ! grep -q "^docker:" /etc/group; then
	# Create docker group
	if command -v groupadd &>/dev/null; then
		$SUDOCMD groupadd docker
	fi
fi

# Add non-root user to the docker group if possible
if command -v usermod &>/dev/null; then
	$SUDOCMD usermod -aG docker ${USER_NONROOT}
elif command -v gpasswd &>/dev/null; then
	$SUDOCMD gpasswd -a ${USER_NONROOT} docker
fi

# Make folder for the Actions runner
$SUDOCMD mkdir /actions-runner && cd /actions-runner
$SUDOCMD chown ${USER_NONROOT} -R /actions-runner

# Download the runner installer
curl -o actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz -L https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz
tar xzf ./actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz

# Fix directory permissions
$SUDOCMD chown ${USER_NONROOT} -R /actions-runner

# Request a Runner token
RUNNER_TOKEN=$(curl -s -XPOST -H "authorization: token ${GH_TOKEN}" "${GITHUB_API_BASE}/actions/runners/registration-token" | grep -o '"token": "[^"]*' | awk -F': "' '{print $2}')

# Install dependencies for the Runner
$SUDOCMD ./bin/installdependencies.sh

# Install and start the runner
$SUDO_AS ./config.sh --url "${RUNNER_URL}" --token ${RUNNER_TOKEN} --name "${RUNNER_LABEL}" --labels "${RUNNER_LABEL}" --unattended {{ EPHEMERAL }}
$SUDOCMD ./svc.sh install
$SUDOCMD ./svc.sh start

echo ""
echo "--> Started GitHub Actions Runner"
echo ""

# If TIMEOUT_SECONDS is somehow not an integer, set it to 3600 (60 minutes) as a failsafe
if [[ ! ${TIMEOUT_SECONDS} =~ ^-?[0-9]+$ ]]; then
	echo "--> WARN: 'ec2-timeout' input is not an integer: (${TIMEOUT_SECONDS})"
	echo "--> Using value: 3600"
	TIMEOUT_SECONDS=3600
fi

# If TIMEOUT_SECONDS is not 0, shut down the instance when time runs out
if [[ "${TIMEOUT_SECONDS}" != "0" ]]; then
	echo "--> Server Expiration:"
	echo "----> Current Time: $(TZ=America/Los_Angeles date)"
	echo "---->  Expire time: $(TZ=America/Los_Angeles date -d "+${TIMEOUT_SECONDS} seconds")"
	echo ""
	echo "--> Sleeping for ${TIMEOUT_SECONDS} seconds until server expiration"
	sleep "${TIMEOUT_SECONDS}"
	echo ""
	echo "--> Expiration time reached; terminating instance"
	echo ""
	$SUDOCMD shutdown -h now
else
	echo "--> Server Expiration DISABLED"
	echo "--> This server will stay online until it is terminated manually."
	echo "--> This could run up your bill!"
	echo "--> To avoid this, set the 'ec2-timeout' input to a number of seconds to sleep before termination."
	echo ""
fi
