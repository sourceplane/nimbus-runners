// Prebuilt GitHub Actions runner image for the nimbus-runners fleet.
//
// Everything a lane would otherwise install at boot is baked in, so an
// instance goes from launch to "job started" in well under a minute and the
// fleet never runs user data. The start script and install script are the
// module's own templates (rendered from a checkout of
// github-aws-runners/terraform-aws-github-runner at the same tag as the
// Terraform module), so JIT registration and ephemeral termination behave
// exactly as the module expects.
//
// Built by .github/workflows/runner-ami.yaml, which writes the new image id to
// the SSM parameter the launch template resolves (/nimbus-runners/ami-id).

packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "module_dir" {
  description = "Checkout of github-aws-runners/terraform-aws-github-runner at the module tag"
  type        = string
}

variable "runner_version" {
  description = "actions/runner version, no v prefix"
  type        = string
}

variable "subnet_name" {
  type    = string
  default = "nimbus-runners-public-us-east-1a"
}

variable "node_versions" {
  description = "Node versions seeded into the hosted tool cache (setup-node finds them offline)"
  type        = list(string)
  default     = ["20.19.5", "22.20.0"]
}

source "amazon-ebs" "runner" {
  region        = var.region
  ami_name      = "nimbus-runner-ubuntu-noble-x64-${formatdate("YYYYMMDDhhmm", timestamp())}"
  instance_type = "m7i-flex.large"

  subnet_filter {
    filters = { "tag:Name" = var.subnet_name }
  }
  associate_public_ip_address               = true
  temporary_security_group_source_public_ip = true

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"]
  }
  ssh_username = "ubuntu"

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name        = "nimbus-runner"
    ManagedBy   = "packer"
    Fleet       = "nimbus-runners"
    Repo        = "nimbus-runners"
    RunnerVer   = var.runner_version
    Base_AMI_ID = "{{ .SourceAMI }}"
  }
  snapshot_tags = {
    Name  = "nimbus-runner"
    Fleet = "nimbus-runners"
  }
  run_tags = {
    Name  = "nimbus-runner-packer"
    Fleet = "nimbus-runners"
  }
}

build {
  sources = ["source.amazon-ebs.runner"]

  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "NODE_VERSIONS=${join(" ", var.node_versions)}",
    ]
    execute_command = "sudo -E env {{ .Vars }} bash '{{ .Path }}'"
    script          = "${path.root}/provision.sh"
  }

  provisioner "file" {
    content = templatefile("${var.module_dir}/images/install-runner.sh", {
      install_runner = templatefile("${var.module_dir}/modules/runners/templates/install-runner.sh", {
        ARM_PATCH                       = ""
        S3_LOCATION_RUNNER_DISTRIBUTION = ""
        RUNNER_ARCHITECTURE             = "x64"
      })
    })
    destination = "/tmp/install-runner.sh"
  }

  provisioner "shell" {
    inline = [
      "echo runner > /tmp/install-user.txt",
      "sudo RUNNER_ARCHITECTURE=x64 RUNNER_TARBALL_URL=https://github.com/actions/runner/releases/download/v${var.runner_version}/actions-runner-linux-x64-${var.runner_version}.tar.gz bash /tmp/install-runner.sh",
      "echo ImageOS=ubuntu24 | sudo tee -a /opt/actions-runner/.env",
      "echo RUNNER_TOOL_CACHE=/opt/hostedtoolcache | sudo tee -a /opt/actions-runner/.env",
      "echo AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache | sudo tee -a /opt/actions-runner/.env",
    ]
  }

  provisioner "file" {
    content = templatefile("${var.module_dir}/images/start-runner.sh", {
      start_runner = templatefile("${var.module_dir}/modules/runners/templates/start-runner.sh", { metadata_tags = "enabled" })
    })
    destination = "/tmp/start-runner.sh"
  }

  provisioner "shell" {
    inline = [
      "sudo mv /tmp/start-runner.sh /var/lib/cloud/scripts/per-boot/start-runner.sh",
      "sudo chmod +x /var/lib/cloud/scripts/per-boot/start-runner.sh",
      # Leave no instance identity behind: cloud-init must treat the first boot
      # of every runner as new so the per-boot start script runs.
      "sudo cloud-init clean --logs --machine-id",
      "sudo rm -rf /tmp/* /var/lib/apt/lists/*",
    ]
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
