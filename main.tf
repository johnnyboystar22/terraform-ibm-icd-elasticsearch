locals {
  # Validation (approach based on https://github.com/hashicorp/terraform/issues/25609#issuecomment-1057614400)
  # tflint-ignore: terraform_unused_declarations
  validate_kms_values = !var.kms_encryption_enabled && (var.kms_key_crn != null || var.backup_encryption_key_crn != null) ? tobool("When passing values for var.backup_encryption_key_crn or var.kms_key_crn, you must set var.kms_encryption_enabled to true. Otherwise unset them to use default encryption") : true
  # tflint-ignore: terraform_unused_declarations
  validate_kms_vars = var.kms_encryption_enabled && var.kms_key_crn == null && var.backup_encryption_key_crn == null ? tobool("When setting var.kms_encryption_enabled to true, a value must be passed for var.kms_key_crn and/or var.backup_encryption_key_crn") : true
  # tflint-ignore: terraform_unused_declarations
  validate_auth_policy = var.kms_encryption_enabled && var.skip_iam_authorization_policy == false && var.existing_kms_instance_guid == null ? tobool("When var.skip_iam_authorization_policy is set to false, and var.kms_encryption_enabled to true, a value must be passed for var.existing_kms_instance_guid in order to create the auth policy.") : true
  # tflint-ignore: terraform_unused_declarations
  validate_backup_key = var.backup_encryption_key_crn != null && var.use_default_backup_encryption_key == true ? tobool("When passing a value for 'backup_encryption_key_crn' you cannot set 'use_default_backup_encryption_key' to 'true'") : true
  # tflint-ignore: terraform_unused_declarations
  validate_plan = var.enable_elser_model && var.plan != "platinum" ? tobool("When var.enable_elser_model is set to true, a value for var.plan must be 'platinum' in order to enable ELSER model.") : true
  # tflint-ignore: terraform_unused_declarations
  validate_es_user = var.enable_elser_model && !((length(var.service_credential_names) > 0 && length([for k, v in var.service_credential_names : k if v == "Administrator"]) > 0) || var.admin_pass != null) ? tobool("When var.enable_elser_model is set to true, a value must be passed for var.service_credential_names or var.admin_pass. var.service_credential_names must contain at least one credential name with Administrator role.") : true

  # If no value passed for 'backup_encryption_key_crn' use the value of 'kms_key_crn' and perform validation of 'kms_key_crn' to check if region is supported by backup encryption key.

  # For more info, see https://cloud.ibm.com/docs/cloud-databases?topic=cloud-databases-key-protect&interface=ui#key-byok and https://cloud.ibm.com/docs/cloud-databases?topic=cloud-databases-hpcs#use-hpcs-backups"

  backup_encryption_key_crn = var.use_default_backup_encryption_key == true ? null : (var.backup_encryption_key_crn != null ? var.backup_encryption_key_crn : var.kms_key_crn)

  # Determine if auto scaling is enabled
  auto_scaling_enabled = var.auto_scaling == null ? [] : [1]

  # Determine if host_flavor is used
  host_flavor_set = var.member_host_flavor != null ? true : false

  # Determine what KMS service is being used for database encryption
  kms_service = var.kms_key_crn != null ? (
    can(regex(".*kms.*", var.kms_key_crn)) ? "kms" : (
      can(regex(".*hs-crypto.*", var.kms_key_crn)) ? "hs-crypto" : "unrecognized key type"
    )
  ) : "no key crn"
}

# Create IAM Access Policy to allow Key protect to access Elasticsearch instance
resource "ibm_iam_authorization_policy" "policy" {
  count                       = var.kms_encryption_enabled == false || var.skip_iam_authorization_policy ? 0 : 1
  source_service_name         = "databases-for-elasticsearch"
  source_resource_group_id    = var.resource_group_id
  target_service_name         = local.kms_service
  target_resource_instance_id = var.existing_kms_instance_guid
  roles                       = ["Reader"]
}

# workaround for https://github.com/IBM-Cloud/terraform-provider-ibm/issues/4478
resource "time_sleep" "wait_for_authorization_policy" {
  depends_on = [ibm_iam_authorization_policy.policy]

  create_duration = "30s"
}


resource "ibm_database" "elasticsearch" {
  depends_on                = [time_sleep.wait_for_authorization_policy]
  name                      = var.name
  plan                      = var.plan
  location                  = var.region
  service                   = "databases-for-elasticsearch"
  version                   = var.elasticsearch_version
  resource_group_id         = var.resource_group_id
  service_endpoints         = var.service_endpoints
  tags                      = var.tags
  adminpassword             = var.admin_pass
  key_protect_key           = var.kms_key_crn
  backup_encryption_key_crn = local.backup_encryption_key_crn
  backup_id                 = var.backup_crn

  dynamic "users" {
    for_each = nonsensitive(var.users != null ? var.users : [])
    content {
      name     = users.value.name
      password = users.value.password
      type     = users.value.type
      role     = (users.value.role != "" ? users.value.role : null)
    }
  }

  ## This for_each block is NOT a loop to attach to multiple group blocks.
  ## This is used to conditionally add one, OR, the other group block depending on var.local.host_flavor_set
  ## This block is for if host_flavor IS set to specific pre-defined host sizes and not set to "multitenant"
  dynamic "group" {
    for_each = local.host_flavor_set && var.member_host_flavor != "multitenant" ? [1] : []
    content {
      group_id = "member" # Only member type is allowed for postgresql
      host_flavor {
        id = var.member_host_flavor
      }
      disk {
        allocation_mb = var.member_disk_mb
      }
      members {
        allocation_count = var.members
      }
    }
  }

  ## This block is for if host_flavor IS set to "multitenant"
  dynamic "group" {
    for_each = local.host_flavor_set && var.member_host_flavor == "multitenant" ? [1] : []
    content {
      group_id = "member" # Only member type is allowed for postgresql
      host_flavor {
        id = var.member_host_flavor
      }
      disk {
        allocation_mb = var.member_disk_mb
      }
      memory {
        allocation_mb = var.member_memory_mb
      }
      cpu {
        allocation_count = var.member_cpu_count
      }
      members {
        allocation_count = var.members
      }
    }
  }

  ## This block is for if host_flavor IS NOT set
  dynamic "group" {
    for_each = local.host_flavor_set ? [] : [1]
    content {
      group_id = "member" # Only member type is allowed for postgresql
      memory {
        allocation_mb = var.member_memory_mb
      }
      disk {
        allocation_mb = var.member_disk_mb
      }
      cpu {
        allocation_count = var.member_cpu_count
      }
      members {
        allocation_count = var.members
      }
    }
  }

  ## This for_each block is NOT a loop to attach to multiple auto_scaling blocks.
  ## This block is only used to conditionally add auto_scaling block depending on var.auto_scaling
  dynamic "auto_scaling" {
    for_each = local.auto_scaling_enabled
    content {
      disk {
        capacity_enabled             = var.auto_scaling.disk.capacity_enabled
        free_space_less_than_percent = var.auto_scaling.disk.free_space_less_than_percent
        io_above_percent             = var.auto_scaling.disk.io_above_percent
        io_enabled                   = var.auto_scaling.disk.io_enabled
        io_over_period               = var.auto_scaling.disk.io_over_period
        rate_increase_percent        = var.auto_scaling.disk.rate_increase_percent
        rate_limit_mb_per_member     = var.auto_scaling.disk.rate_limit_mb_per_member
        rate_period_seconds          = var.auto_scaling.disk.rate_period_seconds
        rate_units                   = var.auto_scaling.disk.rate_units
      }
      memory {
        io_above_percent         = var.auto_scaling.memory.io_above_percent
        io_enabled               = var.auto_scaling.memory.io_enabled
        io_over_period           = var.auto_scaling.memory.io_over_period
        rate_increase_percent    = var.auto_scaling.memory.rate_increase_percent
        rate_limit_mb_per_member = var.auto_scaling.memory.rate_limit_mb_per_member
        rate_period_seconds      = var.auto_scaling.memory.rate_period_seconds
        rate_units               = var.auto_scaling.memory.rate_units
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # Ignore changes to these because a change will destroy and recreate the instance
      version,
      key_protect_key,
      backup_encryption_key_crn,
      connectionstrings # https://github.com/IBM-Cloud/terraform-provider-ibm/issues/5546
    ]
  }

  timeouts {
    create = "120m" #Extending provisioning time to 120 minutes
  }
}

resource "ibm_resource_tag" "elasticsearch_tag" {
  count       = length(var.access_tags) == 0 ? 0 : 1
  resource_id = ibm_database.elasticsearch.resource_crn
  tags        = var.access_tags
  tag_type    = "access"
}


##############################################################################
# Context Based Restrictions
##############################################################################

module "cbr_rule" {
  count            = length(var.cbr_rules) > 0 ? length(var.cbr_rules) : 0
  source           = "terraform-ibm-modules/cbr/ibm//modules/cbr-rule-module"
  version          = "1.23.5"
  rule_description = var.cbr_rules[count.index].description
  enforcement_mode = var.cbr_rules[count.index].enforcement_mode
  rule_contexts    = var.cbr_rules[count.index].rule_contexts
  resources = [{
    attributes = [
      {
        name     = "accountId"
        value    = var.cbr_rules[count.index].account_id
        operator = "stringEquals"
      },
      {
        name     = "serviceInstance"
        value    = ibm_database.elasticsearch.guid
        operator = "stringEquals"
      },
      {
        name     = "serviceName"
        value    = "databases-for-elasticsearch"
        operator = "stringEquals"
      }
    ]
  }]
  #  There is only 1 operation type for Elasticsearch so it is not exposed as a configuration
  operations = [{
    api_types = [
      {
        api_type_id = "crn:v1:bluemix:public:context-based-restrictions::::api-type:data-plane"
      }
    ]
  }]
}

##############################################################################
# Service Credentials
##############################################################################

resource "ibm_resource_key" "service_credentials" {
  for_each             = var.service_credential_names
  name                 = each.key
  role                 = each.value
  resource_instance_id = ibm_database.elasticsearch.id
}

locals {
  # used for output only
  service_credentials_json = length(var.service_credential_names) > 0 ? {
    for service_credential in ibm_resource_key.service_credentials :
    service_credential["name"] => service_credential["credentials_json"]
  } : null

  service_credentials_object = length(var.service_credential_names) > 0 ? {
    hostname    = ibm_resource_key.service_credentials[keys(var.service_credential_names)[0]].credentials["connection.https.hosts.0.hostname"]
    port        = ibm_resource_key.service_credentials[keys(var.service_credential_names)[0]].credentials["connection.https.hosts.0.port"]
    certificate = ibm_resource_key.service_credentials[keys(var.service_credential_names)[0]].credentials["connection.https.certificate.certificate_base64"]
    credentials = {
      for service_credential in ibm_resource_key.service_credentials :
      service_credential["name"] => {
        username = service_credential.credentials["connection.https.authentication.username"]
        password = service_credential.credentials["connection.https.authentication.password"]
      }
    }
  } : null
}

data "ibm_database_connection" "database_connection" {
  endpoint_type = var.service_endpoints == "public-and-private" ? "public" : var.service_endpoints
  deployment_id = ibm_database.elasticsearch.id
  user_id       = ibm_database.elasticsearch.adminuser
  user_type     = "database"
}

##############################################################################
# ELSER support
##############################################################################

# Enable Elastic's Natural Language Processing model (ELSER) support by calling ES REST API directly using shell script. Learn more https://cloud.ibm.com/docs/databases-for-elasticsearch?topic=databases-for-elasticsearch-elser-embeddings-elasticsearch
# Firstly, ELSER model is installed using 'put_vectordb_model' null_resource. Secondly, ELSER model is started with `start_vectordb_model` null_resource.
#
# To authenticate ES rest API, the credentials are extracted from 'service_credential_names' or ES 'adminpassword' using the following logic:
# if elser_model is enabled, then
#   if service_credential_names are used, then get the key name of a credential where role is 'Administrator'
#       use the key name to obtain username and password from service_credentials_object
#   else if admin_pass is used, then use 'admin' for username and password from ES password
locals {
  es_admin_users = var.enable_elser_model && var.service_credential_names != null && length(var.service_credential_names) > 0 ? [for k, v in var.service_credential_names : k if v == "Administrator"] : []
  es_admin_user  = length(local.es_admin_users) > 0 ? local.es_admin_users[0] : null
  es_username    = local.es_admin_user != null ? local.service_credentials_object["credentials"][local.es_admin_user]["username"] : var.admin_pass != null ? "admin" : null
  es_password    = local.es_admin_user != null ? local.service_credentials_object["credentials"][local.es_admin_user]["password"] : var.admin_pass != null ? ibm_database.elasticsearch.adminpassword : null
  es_url         = local.es_username != null && local.es_password != null ? "https://${local.es_username}:${local.es_password}@${data.ibm_database_connection.database_connection.https[0].hosts[0].hostname}:${data.ibm_database_connection.database_connection.https[0].hosts[0].port}" : null
}

resource "null_resource" "put_vectordb_model" {
  count = var.enable_elser_model ? 1 : 0
  provisioner "local-exec" {
    command     = "${path.module}/scripts/put_vectordb_model.sh"
    interpreter = ["/bin/bash", "-c"]
    environment = {
      ES = local.es_url
    }
  }
}

resource "null_resource" "start_vectordb_model" {
  depends_on = [null_resource.put_vectordb_model]
  count      = var.enable_elser_model ? 1 : 0
  provisioner "local-exec" {
    command     = "${path.module}/scripts/start_vectordb_model.sh"
    interpreter = ["/bin/bash", "-c"]
    environment = {
      ES = local.es_url
    }
  }
}
