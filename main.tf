
terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 0.6.12"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 2.22"
    }
  }
}

variable "python_version" {
  description = "What python version would you like to use for your workspace?"
  default     = "latest"
}

variable "private_docker_network" {
  description = "Create a private docker network?"
  type        = bool
  default     = false
}

variable "workspace_envs" {
  description = "ENV vars to be injected into workspace"
  type        = list
  default     = []
}

# those labels will be applied to pretty much everything
locals {
  common_labels = [
    # Add labels in Docker to keep track of orphan resources.
    {
      label = "coder.owner"
      value = data.coder_workspace.me.owner
    },
    {
      label = "coder.owner_id"
      value = data.coder_workspace.me.owner_id
    },
    {
      label = "coder.workspace_id"
      value = data.coder_workspace.me.id
    },
    {
      label = "coder.workspace_name"
      value = data.coder_workspace.me.name
    }
  ]
}

resource "docker_network" "private_network" {
  count = var.private_docker_network ? 1 : 0
  name = "network-${data.coder_workspace.me.id}"
}

data "coder_provisioner" "me" {
}

data "coder_workspace" "me" {
}

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"

  login_before_ready     = false
  startup_script_timeout = 180
  # TODO: move install to docker image
  startup_script         = <<-EOT
    set -e

    # install and start code-server
    curl -fsSL https://code-server.dev/install.sh | sh -s -- --method=standalone --prefix=/tmp/code-server --version 4.8.3
    /tmp/code-server/bin/code-server --auth none --port 13337 >/tmp/code-server.log 2>&1 &

    # setup a project folder
    mkdir -p /home/coder/project

    # install poetry
    curl -sSL https://install.python-poetry.org | python3 -
    sudo ln -s /home/coder/.local/bin/poetry /usr/local/bin/poetry
  EOT

  # These environment variables allow you to make Git commits right away after creating a
  # workspace. Note that they take precedence over configuration defined in ~/.gitconfig!
  # You can remove this block if you'd prefer to configure Git manually or using
  # dotfiles. (see docs/dotfiles.md)
  env = {
    GIT_AUTHOR_NAME     = "${data.coder_workspace.me.owner}"
    GIT_COMMITTER_NAME  = "${data.coder_workspace.me.owner}"
    GIT_AUTHOR_EMAIL    = "${data.coder_workspace.me.owner_email}"
    GIT_COMMITTER_EMAIL = "${data.coder_workspace.me.owner_email}"
  }
}

resource "coder_app" "code-server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "code-server"
  url          = "http://localhost:13337/?folder=/home/coder/project"
  icon         = "/icon/code.svg"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 3
    threshold = 10
  }
}

resource "docker_volume" "home_volume" {
  name = "coder-${data.coder_workspace.me.id}-home"
  # Protect the volume from being deleted due to changes in attributes.
  lifecycle {
    ignore_changes = all
  }
  dynamic "labels" {
    for_each = local.common_labels
    content {
      label = labels.value.label
      value = labels.value.value
    }
  }
  labels {
    label = "coder.python_version"
    value = var.python_version
  }
  # This field becomes outdated if the workspace is renamed but can
  # be useful for debugging or cleaning out dangling volumes.
  labels {
    label = "coder.workspace_name_at_creation"
    value = data.coder_workspace.me.name
  }
}

# cf https://github.com/abulte/coder-python-image
data "docker_registry_image" "coder_image" {
  name = "ghcr.io/abulte/coder-python-image:${var.python_version}"
}

resource "docker_image" "coder_image" {
  name          = "${data.docker_registry_image.coder_image.name}@${data.docker_registry_image.coder_image.sha256_digest}"
  # update image when it changes on remote
  pull_triggers = [data.docker_registry_image.coder_image.sha256_digest]
}

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count
  image = docker_image.coder_image.image_id
  # Uses lower() to avoid Docker restriction on container names.
  name = "coder-${data.coder_workspace.me.owner}-${lower(data.coder_workspace.me.name)}"
  # Hostname makes the shell more user friendly: coder@my-workspace:~$
  hostname = data.coder_workspace.me.name
  # Use the docker gateway if the access URL is 127.0.0.1
  entrypoint = ["sh", "-c", replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")]
  env        = concat(["CODER_AGENT_TOKEN=${coder_agent.main.token}"], var.workspace_envs)
  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }
  volumes {
    container_path = "/home/coder/"
    volume_name    = docker_volume.home_volume.name
    read_only      = false
  }
  # attach to docker private network(s) if the list is not empty
  dynamic "networks_advanced" {
    for_each = docker_network.private_network
    content {
      name = networks_advanced.value.name
    }
  }
  dynamic "labels" {
    for_each = local.common_labels
    content {
      label = labels.value.label
      value = labels.value.value
    }
  }
}

resource "coder_metadata" "container_info" {
  count       = data.coder_workspace.me.start_count
  resource_id = docker_container.workspace[0].id

  item {
    key   = "image"
    value = "python-${var.python_version}"
  }
}

output "coder_workspace_data" {
  value = data.coder_workspace.me
}

output "docker_network_name" {
  value = var.private_docker_network ? docker_network.private_network[0].name : null
}

output "common_labels" {
  value = local.common_labels
}
