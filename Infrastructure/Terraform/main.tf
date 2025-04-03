terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
  required_version = ">= 0.13"
}

provider "yandex" {
  token     = var.token
  cloud_id  = var.cloud_id
  folder_id = var.folder_id
  zone      = "ru-central1-a"
}

data "yandex_compute_image" "my-ubuntu-2004-1" {
  family = "ubuntu-2004-lts"
}


resource "yandex_iam_service_account" "for-autoscale" {
  name = "for-autoscale"
}

resource "yandex_resourcemanager_folder_iam_member" "vm-autoscale-sa-role-compute" {
  folder_id = var.folder_id
  role      = "editor"
  member    = "serviceAccount:${yandex_iam_service_account.for-autoscale.id}"
}

resource "yandex_vpc_security_group" "my-sg-1" {
  name                = "sg-autoscale"
  network_id          = yandex_vpc_network.default.id
  egress {
    protocol          = "ANY"
    description       = "any"
    v4_cidr_blocks    = ["0.0.0.0/0"]
  }
  ingress {
    protocol          = "TCP"
    description       = "ext-http"
    v4_cidr_blocks    = ["0.0.0.0/0"]
    port              = 80
  }
  ingress {
    protocol          = "TCP"
    description       = "healthchecks"
    predefined_target = "loadbalancer_healthchecks"
    port              = 80
  }
  ingress {
    protocol          = "TCP"
    description       = "ext-ssh"
    v4_cidr_blocks    = ["0.0.0.0/0"]
    port              = 22
  }
}

# Создание группы ВМ

resource "yandex_compute_instance_group" "autoscale-group" {
  name                = "nginx-ig"
  folder_id           = var.folder_id
  service_account_id  = yandex_iam_service_account.for-autoscale.id
  instance_template {

    name = "nginx-{instance.index}"

    platform_id = "standard-v3"
    resources {
      cores  = 2
      memory = 2
    }
  
    boot_disk {
      mode = "READ_WRITE"
      initialize_params {
        image_id = "${data.yandex_compute_image.my-ubuntu-2004-1.id}"
        size     = 10
      }
    }

    network_interface {
      network_id = yandex_vpc_network.default.id
      subnet_ids = [
        yandex_vpc_subnet.my-sn-a.id,
        yandex_vpc_subnet.my-sn-b.id
      ]
      security_group_ids = [ yandex_vpc_security_group.my-sg-1.id ]
      nat                = true
    }

    metadata = {
      ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
      user-data = "${file("cloud-init.yaml")}"
    }
   
    scheduling_policy {
      preemptible = true
    }

  }

  scale_policy {
    auto_scale {
      initial_size           = 2
      measurement_duration   = 60
      cpu_utilization_target = 40
      min_zone_size          = 1
      max_size               = 2
      warmup_duration        = 60
    }
  }

  allocation_policy {
    zones = [
      "ru-central1-a",
      "ru-central1-b"
    ]
  }

  deploy_policy {
    max_unavailable = 1
    max_expansion   = 0
  }

  load_balancer {
    target_group_name        = "nginx-tg"
    target_group_description = "load balancer target group"
  }

  depends_on = [ yandex_resourcemanager_folder_iam_member.vm-autoscale-sa-role-compute ]

}


resource "yandex_compute_instance" "prod" {
  name        = "prod"
  platform_id = "standard-v3"
  zone        = "ru-central1-a"

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = "${data.yandex_compute_image.my-ubuntu-2004-1.id}"
      size = 10
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.my-sn-a.id
    nat = true
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }

  scheduling_policy {
    preemptible = true
  }
}

resource "yandex_compute_instance" "test" {
  name        = "test"
  platform_id = "standard-v3"
  zone        = "ru-central1-a"

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = "${data.yandex_compute_image.my-ubuntu-2004-1.id}"
      size = 10
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.my-sn-a.id
    nat = true
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }

  scheduling_policy {
    preemptible = true
  }
}

resource "yandex_compute_instance" "monitoring" {
  name        = "monitoring"
  platform_id = "standard-v3"
  zone        = "ru-central1-a"

  resources {
    cores  = 2
    memory = 2
  }

  boot_disk {
    initialize_params {
      image_id = "${data.yandex_compute_image.my-ubuntu-2004-1.id}"
      size = 10
    }
  }

  network_interface {
    subnet_id = yandex_vpc_subnet.my-sn-a.id
    nat = true
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }

  scheduling_policy {
    preemptible = true
  }
}

resource "yandex_vpc_network" "default" {
  name = "my-nw-2"
}

resource "yandex_vpc_subnet" "my-sn-a" {
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.default.id
  v4_cidr_blocks = ["192.168.10.0/24"]
}

resource "yandex_vpc_subnet" "my-sn-b" {
  zone           = "ru-central1-b"
  network_id     = yandex_vpc_network.default.id
  v4_cidr_blocks = ["192.168.20.0/24"]
}


# Создание сетевого балансировщика

resource "yandex_lb_network_load_balancer" "balancer" {
  name = "nginx-load-balancer"

  listener {
    name        = "http"
    port        = 80
    target_port = 80
  }

  attached_target_group {
    target_group_id = yandex_compute_instance_group.autoscale-group.load_balancer[0].target_group_id
    healthcheck {
      name = "tcp"
      tcp_options {
        port = 80
      }
    }
  }

  depends_on = [ yandex_compute_instance_group.autoscale-group ]

}

output "internal_ip_address_docker {
  value = yandex_compute_instance.docker.network_interface.0.ip_address
}

output "external_ip_address_docker" {
  value = yandex_compute_instance.docker.network_interface.0.nat_ip_address
}

output "load_balancer_ip" {
  value = yandex_lb_network_load_balancer.balancer.listener
}

