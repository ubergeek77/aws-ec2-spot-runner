# AWS EC2 Spot Runner GitHub Action

AWS EC2 Spot Runner is a GitHub Action that allows you to quickly spin up a GitHub Actions Runner on AWS EC2 using Spot Instances.

## Quick Start

```yml
...

jobs:
  launch-runner:
    runs-on: ubuntu-latest
    outputs:
      label: ${{ steps.launch.outputs.label}}
    steps:
      - id: launch
        name: Launch Spot Runner
        uses: ubergeek77/aws-ec2-spot-runner@v1
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          ec2-keypair-name: ${{ secrets.EC2_KEYPAIR }}
          ec2-security-group-id: ${{ secrets.EC2_SG }}
          github-repo: ${{ github.repository }} # Use 'github-organization' instead if you're deploying on a GitHub Organization
          github-token: ${{ secrets.GH_TOKEN }}
  use-runner:
    needs: launch-runner
    runs-on: ${{ needs.launch-runner.outputs.label }}
    steps:
      - name: Use the runner
        run: echo "Do whatever you want!"
  stop-runner:
    needs: [launch-runner,use-runner]
    runs-on: ubuntu-latest
    if: always()
    steps:
      - name: Terminate Runner
        uses: ubergeek77/aws-ec2-spot-runner@v1
        with:
          shutdown-label: ${{ needs.launch-runner.outputs.label }} # This is how the action knows to STOP instead of START, don't forget this!
          github-token: ${{ secrets.GH_TOKEN }} # Used to de-register the Runner automatically. Technically optional, but recommended. HIGHLY recommended if ephemeral==false
          github-repo: ${{ github.repository }} # Ditto^, use 'github-organization' instead if you're deploying on a GitHub Organization
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}

...
```

## Prerequisites

- GitHub Personal Access Token with the `repo` scope (personal repositories) or `admin:org` scope (Organizations)
- An EC2 Keypair already made. This action will not make one for you. It also doesn't need to use it, so just pick one in case you need to log in to debug a build.
- An EC2 Security Group already made. This action will not make one for you. It also doesn't need any special ports, just make sure the Security Group allows outbound connections (which is the default anyway).
- AWS CLI credentials with at least these permissions (you can copy this JSON into AWS's policy editor):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:TerminateInstances",
        "ec2:RequestSpotInstances",
        "ec2:CreateTags",
        "ec2:DescribeSpotInstanceRequests"
      ],
      "Resource": "*"
    }
  ]
}
```

## Usage

See the **Quick Start** above for the most minimal configuration. That example workflow will:

- Request a new EC2 Spot Instance
- Install a GitHub Actions Runner on the instance
- Wait for the Runner to go online
- Run the `use-runner` task on the newly deployed runner
- Deregister the Runner from GitHub
- Shut down the EC2 Spot Instance

See **Configuration** below for which instance type will be used by default. The AMI and instance type can be changed as needed.

To avoid accidentally running up an AWS bill, any EC2 instance launched will automatically shut itself down after 1 hour. This time window is configurable. It ***WILL*** shut down even if a job is running, so be sure to adjust the timeout length as needed. The timeout length should be longer than the expected job run time. This is just a failsafe in case the shutdown task is forgotten, or if the termination command fails for some reason.

By default, the runner is created to be "Ephemeral," meaning it can only run one job. If you need to use the same deployed runner for multiple jobs, set `ephemeral` to `false` when launching. *If you are launching a non-ephemeral Runner, you should specify `github-token` and `github-repo`/`github-org` in the shutdown task containing `shutdown-label`, otherwise the dead Runner will stay registered for 14 days.*

## Why?

The free GitHub Actions runners are extremely underpowered. Something that could take ***4 hours*** on the free GitHub Actions runners can be done in ***15 minutes*** on an EC2 Spot Instance, costing about 1 ***cent*** for the job ($0.01). You also only get 8,000 minutes of free GitHub Actions minutes per month, which you'll easily burn through with its extremely slow compute power. EC2 Spot Instances are, as I put them, *"so cheap they're basically free",* so it just makes sense to run all your build tasks there.

I made this because there weren't any GitHub Actions that launched Runners on ***Spot*** instances specifically (which are MUCH cheaper). None of the popular EC2 Runner actions even support Spot instances at all, which is honestly pretty crazy to me considering how much cheaper they are. And, with just a few simple scripts under the hood instead of a full Node project, this is easy to read *and* easy to modify.

## Configuration

#### Inputs:

- `aws-access-key-id`:
  - Your AWS Access Key ID
- `aws-default-region`:
  - The default AWS Region, needed for the CLI 
  - Default: `us-east-2`
- `aws-secret-access-key`:
  - Your AWS Secret Access Key
- `dry-run`:
  - Whether or not do do a dry run (pretends to set up a runner but does not interact with AWS) 
  - Default: `false`
- `ec2-ami`:
  - The ID of the AMI to use for the EC2 Spot Instance 
  - Default: `ami-024e6efaf93d85776` / Ubuntu 22.04
- `ec2-instance-type`:
  - The EC2 Instance Type to use for the EC2 Spot Instance 
  - Default: `c5d.large`
- `ec2-keypair-name`:
  - The name of the pre-existing AWS keypair to use for the EC2 Spot Instance
- `ec2-security-group-id`:
  - The pre-existing Security Group ID to use for the EC2 Spot Instance
- `ec2-timeout`:
  - The number of seconds to wait before terminating the instance 
  - Default: `3600`
- `ec2-zone`:
  - The AWS EC2 Zone to deploy the Spot Instance to 
  - Default: `us-east-2a`
- `ephemeral`:
  - If `true`, will unregister the runner after it runs a single job
  - Set to `false` if you want to use it for more than a single job in the same workflow
  - Default: `true`
- `github-organization`:
  - If set, the GitHub Organization to attach the runner to
  - If NOT deploying to a GitHub github-Organization, use `github-repo` instead!
- `github-repo`:
  - The repo to deploy the runner for; just pass through `${{ github.repository }}`
  - If deploying to a GitHub Organization, use `github-organization` instead!
- `github-token`:
  - Your GitHub Access Token with the `repo` scope (repos) or `admin:org` scope (Orgs)
  - Must be a 'classic' token.
- `runner-arch`:
  - The architecture to use for the runner (`x64`, `arm`, or `arm64`) 
  - Default: `x64`
- `runner-version`:
  - The version of the GitHub Actions runner to use 
  - Default: `2.305.0`
- `shutdown-label`:
  - The label of the runner to shut down
- `vm-user`:
  - The username of the non-root user in the VM 
  - Default: `ubuntu`
- `volume-name`:
  - The name of the block device to provision.
  - Default: `/dev/sda1`
  - To mount on '/', this must match the AMI's root volume name! 
- `volume-size`:
  - The size, in GiBs, that `volume-name` should be 
  - Default: `32`

#### Output:

- `label`:
  - The label of the temporary runner that was just deployed.
  - Pass to `runs-to` to run jobs on the newly deployed Runner
  - Pass this variable to this Action as `shutdown-label` to shut it down.

## Disclaimer

I made this for myself and decided to make it public. You can use it if you want, too. But, while I have published this, I don't make any security or usage guarantees. This is provided as-is. ***I*** think I did a pretty good job, but I'm biased :)

## Donate

If this Action helped you, and you would like to support me, I have crypto addresses:

- Bitcoin: `bc1qekqn4ek0dkuzp8mau3z5h2y3mz64tj22tuqycg`
- Monero/Ethereum: `0xdAe4F90E4350bcDf5945e6Fe5ceFE4772c3B9c9e`

