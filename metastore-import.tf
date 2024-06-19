# Infrastructure for transfering data between two Data Proc clusters
#
# RU: https://cloud.yandex.ru/docs/data-proc/tutorials/metastore-import
# EN: https://cloud.yandex.com/en/docs/data-proc/tutorials/metastore-import
#
# Set the configuration of the Data Proc clusters

# Specify the following settings:
locals {
  folder_id  = "" # Your cloud folder ID, same as for provider
  dp_ssh_key = "" # Аbsolute path to an SSH public key for the Data Proc clusters

  # The following settings are predefined. Change them only if necessary.
  network_name         = "dataproc-network" # Name of the network
  nat_name             = "dataproc-nat" # Name of the NAT gateway
  subnet_name          = "dataproc-subnet-a" # Name of the subnet
  sa_name              = "dataproc-s3-sa" # Name of the service account
  dataproc_source_name = "dataproc-source" # Name of the Data Proc source cluster
  dataproc_target_name = "dataproc-target" # Name of the Data Proc target cluster
  bucket_name          = "dataproc-bucket" # Name of the Object Storage bucket
}

resource "yandex_vpc_network" "dataproc_network" {
  description = "Network for Data Proc and Metastore"
  name        = local.network_name
}

# NAT gateway for Data Proc and Metastore
resource "yandex_vpc_gateway" "dataproc_nat" {
  name = local.nat_name
  shared_egress_gateway {}
}

# Routing table for Data Proc and Metastore
resource "yandex_vpc_route_table" "dataproc_rt" {
  network_id = yandex_vpc_network.dataproc_network.id

  static_route {
    destination_prefix = "0.0.0.0/0"
    gateway_id         = yandex_vpc_gateway.dataproc_nat.id
  }
}

resource "yandex_vpc_subnet" "dataproc_subnet-a" {
  description    = "Subnet for Data Proc and Metastore"
  name           = local.subnet_name
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.dataproc_network.id
  v4_cidr_blocks = ["10.140.0.0/24"]
  route_table_id = yandex_vpc_route_table.dataproc_rt.id
}

resource "yandex_vpc_security_group" "dataproc-security-group" {
  description = "Security group for the Data Proc clusters"
  network_id  = yandex_vpc_network.dataproc_network.id

  ingress {
    description       = "Allow any incoming traffic within the security group"
    protocol          = "ANY"
    from_port         = 0
    to_port           = 65535
    predefined_target = "self_security_group"
  }

  ingress {
    description    = "Allow access to NTP servers for time syncing"
    protocol       = "UDP"
    port           = 123
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "Allow SSH connections from any IP address to subcluster hosts with public addresses"
    protocol       = "TCP"
    port           = 22
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description    = "Allow any incoming traffic from clients to the Metastore cluster"
    protocol       = "ANY"
    from_port      = 30000
    to_port        = 32767
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description       = "Allow any incoming traffic from a load balancer to the Metastore cluster"
    protocol          = "ANY"
    port              = 10256
    predefined_target = "loadbalancer_healthchecks"
  }

  egress {
    description       = "Allow any outgoing traffic within the security group"
    protocol          = "ANY"
    from_port         = 0
    to_port           = 65535
    predefined_target = "self_security_group"
  }

  egress {
    description    = "Allow connections to the HTTPS port from any IP address"
    protocol       = "TCP"
    port           = 443
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description    = "Allow access to NTP servers for time syncing"
    protocol       = "UDP"
    port           = 123
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description    = "Allow connections to the Metastore port from any IP address"
    protocol       = "ANY"
    port           = 9083
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "yandex_iam_service_account" "dataproc-sa" {
  description = "Service account to manage the Data Proc clusters"
  name        = local.sa_name
}

# Assign the dataproc.agent role to the Data Proc service account
resource "yandex_resourcemanager_folder_iam_binding" "dataproc-agent" {
  folder_id = local.folder_id
  role      = "dataproc.agent"
  members   = ["serviceAccount:${yandex_iam_service_account.dataproc-sa.id}"]
}

# Assign the dataproc.provisioner role to the Data Proc service account
resource "yandex_resourcemanager_folder_iam_binding" "dataproc-provisioner" {
  folder_id = local.folder_id
  role      = "dataproc.provisioner"
  members   = ["serviceAccount:${yandex_iam_service_account.dataproc-sa.id}"]
}

# Assign the storage.admin role to the Data Proc service account
resource "yandex_resourcemanager_folder_iam_binding" "storage-admin" {
  folder_id = local.folder_id
  role      = "storage.admin"
  members   = ["serviceAccount:${yandex_iam_service_account.dataproc-sa.id}"]
}

resource "yandex_iam_service_account_static_access_key" "sa-static-key" {
  description        = "Static access key for Object Storage"
  service_account_id = yandex_iam_service_account.dataproc-sa.id
}

# Use the key to create a bucket and grant permission to the service account in order to read from the bucket and write to it
resource "yandex_storage_bucket" "dataproc-bucket" {
  access_key = yandex_iam_service_account_static_access_key.sa-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.sa-static-key.secret_key
  bucket     = local.bucket_name

  grant {
    id = yandex_iam_service_account.dataproc-sa.id
    type        = "CanonicalUser"
    permissions = ["READ", "WRITE"]
  }
}

resource "yandex_dataproc_cluster" "dataproc-source-cluster" {
  description        = "Data Proc source cluster"
  depends_on         = [yandex_resourcemanager_folder_iam_binding.dataproc-agent,yandex_resourcemanager_folder_iam_binding.dataproc-provisioner]
  bucket             = yandex_storage_bucket.dataproc-bucket.id
  security_group_ids = [yandex_vpc_security_group.dataproc-security-group.id]
  name               = local.dataproc_source_name
  service_account_id = yandex_iam_service_account.dataproc-sa.id
  zone_id            = "ru-central1-a"
  ui_proxy           = true

  cluster_config {
    version_id = "2.0"

    hadoop {
      services        = ["HDFS", "HIVE", "SPARK", "YARN", "ZEPPELIN"]
      ssh_public_keys = [file(local.dp_ssh_key)]
      properties = {
        # For running PySpark jobs when Data Proc is integrated with Metastore
        "spark:spark.sql.hive.metastore.sharedPrefixes" = "com.amazonaws,ru.yandex.cloud"
      }
    }

    subcluster_spec {
      name = "main"
      role = "MASTERNODE"
      resources {
        resource_preset_id = "s2.micro" # 2 vCPU, 8 GB of RAM
        disk_type_id       = "network-hdd"
        disk_size          = 20 # GB
      }
      subnet_id        = yandex_vpc_subnet.dataproc_subnet-a.id
      hosts_count      = 1
      assign_public_ip = true
    }

    subcluster_spec {
      name = "data"
      role = "DATANODE"
      resources {
        resource_preset_id = "s2.micro" # 2 vCPU, 8 GB of RAM
        disk_type_id       = "network-hdd"
        disk_size          = 20 # GB
      }
      subnet_id   = yandex_vpc_subnet.dataproc_subnet-a.id
      hosts_count = 1
    }
  }
}

resource "yandex_dataproc_cluster" "dataproc-target-cluster" {
  description        = "Data Proc target cluster"
  depends_on         = [yandex_resourcemanager_folder_iam_binding.dataproc-agent,yandex_resourcemanager_folder_iam_binding.dataproc-provisioner]
  bucket             = yandex_storage_bucket.dataproc-bucket.id
  security_group_ids = [yandex_vpc_security_group.dataproc-security-group.id]
  name               = local.dataproc_target_name
  service_account_id = yandex_iam_service_account.dataproc-sa.id
  zone_id            = "ru-central1-a"
  ui_proxy           = true

  cluster_config {
    version_id = "2.0"

    hadoop {
      services        = ["HDFS", "HIVE", "SPARK", "YARN", "ZEPPELIN"]
      ssh_public_keys = [file(local.dp_ssh_key)]
      properties = {
        # For running PySpark jobs when Data Proc is integrated with Metastore
        "spark:spark.sql.hive.metastore.sharedPrefixes" = "com.amazonaws,ru.yandex.cloud"
      }
    }

    subcluster_spec {
      name = "main"
      role = "MASTERNODE"
      resources {
        resource_preset_id = "s2.micro" # 2 vCPU, 8 GB of RAM
        disk_type_id       = "network-hdd"
        disk_size          = 20 # GB
      }
      subnet_id        = yandex_vpc_subnet.dataproc_subnet-a.id
      hosts_count      = 1
      assign_public_ip = true
    }

    subcluster_spec {
      name = "data"
      role = "DATANODE"
      resources {
        resource_preset_id = "s2.micro" # 2 vCPU, 8 GB of RAM
        disk_type_id       = "network-hdd"
        disk_size          = 20 # GB
      }
      subnet_id   = yandex_vpc_subnet.dataproc_subnet-a.id
      hosts_count = 1
    }
  }
}
