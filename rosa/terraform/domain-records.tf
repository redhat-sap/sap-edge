# SPDX-FileCopyrightText: 2024 SAP edge team
# SPDX-License-Identifier: Apache-2.0

# Data source to get the hosted zone
# Only lookup if create_domain_records is true
data "aws_route53_zone" "main" {
  count = var.domain_name != "" && var.create_domain_records ? 1 : 0
  name  = var.domain_name
}

# API A Record
resource "aws_route53_record" "api_a" {
  count   = var.domain_name != "" && var.create_domain_records && var.create_domain_records && !var.use_cname_records && var.ipv4_address != "" ? 1 : 0
  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = "api.${var.cluster_name}.${var.domain_name}"
  type    = "A"
  ttl     = var.dns_ttl
  records = [var.ipv4_address]
}

# Apps Wildcard A Record
resource "aws_route53_record" "apps_a" {
  count   = var.domain_name != "" && var.create_domain_records && !var.use_cname_records && var.ipv4_address != "" ? 1 : 0
  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = "*.apps.${var.cluster_name}.${var.domain_name}"
  type    = "A"
  ttl     = var.dns_ttl
  records = [var.ipv4_address]
}

# Console A Record
resource "aws_route53_record" "console_a" {
  count   = var.domain_name != "" && var.create_domain_records && !var.use_cname_records && var.ipv4_address != "" ? 1 : 0
  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = "console-openshift-console.apps.${var.cluster_name}.${var.domain_name}"
  type    = "A"
  ttl     = var.dns_ttl
  records = [var.ipv4_address]
}

# API CNAME Record
resource "aws_route53_record" "api_cname" {
  count   = var.domain_name != "" && var.create_domain_records && var.use_cname_records && var.api_target != "" ? 1 : 0
  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = "api.${var.cluster_name}.${var.domain_name}"
  type    = "CNAME"
  ttl     = var.dns_ttl
  records = [var.api_target]
}

# Apps Wildcard CNAME Record
resource "aws_route53_record" "apps_cname" {
  count   = var.domain_name != "" && var.create_domain_records && var.use_cname_records && var.ingress_target != "" ? 1 : 0
  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = "*.apps.${var.cluster_name}.${var.domain_name}"
  type    = "CNAME"
  ttl     = var.dns_ttl
  records = [var.ingress_target]
}

# Console CNAME Record
resource "aws_route53_record" "console_cname" {
  count   = var.domain_name != "" && var.create_domain_records && var.use_cname_records && var.ingress_target != "" ? 1 : 0
  zone_id = data.aws_route53_zone.main[0].zone_id
  name    = "console-openshift-console.apps.${var.cluster_name}.${var.domain_name}"
  type    = "CNAME"
  ttl     = var.dns_ttl
  records = ["console-openshift-console.${var.ingress_target}"]
}
