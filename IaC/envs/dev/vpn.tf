resource "aws_ec2_client_vpn_endpoint" "case-study-2-vpn" {
  description            = "case-study-2-client-vpn"
  server_certificate_arn = var.server_cert_arn
  client_cidr_block      = "10.100.0.0/22"
  split_tunnel           = true
  dns_servers            = ["10.0.0.2"]
  transport_protocol     = "udp"

  authentication_options {
    type                       = "certificate-authentication"
    root_certificate_chain_arn = var.server_cert_arn
  }

  connection_log_options { enabled = false }

  tags = { Name = "case-study-2-vpn" }
}

//associating VPN to a subnet
resource "aws_ec2_client_vpn_network_association" "vpn_assoc" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.case-study-2-vpn
  subnet_id              = aws_subnet.app[0].id
}

//auth rules
resource "aws_ec2_client_vpn_authorization_rule" "allow_vpc" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.case-study-2-vpn
  target_network_cidr    = var.vpc_cidr
  authorize_all_groups   = true
  description            = "Allow access to all VPC networks"
}

locals {
  assoc_cidr       = aws_subnet.app[0].cidr_block
  private_cidrs    = concat(var.app_subnet_cidrs, var.data_subnet_cidrs)
  route_destinations = [for c in local.private_cidrs : c if c != local.assoc_cidr]
}

resource "aws_ec2_client_vpn_route" "to_private" {
  for_each               = toset(local.route_destinations)
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.case-study-2-vpn
  destination_cidr_block = each.value
  target_vpc_subnet_id   = aws_ec2_client_vpn_network_association.vpn_assoc.subnet_id
  depends_on             = [aws_ec2_client_vpn_network_association.vpn_assoc]
}
#allow PostgreSQL from VPN clients
resource "aws_security_group_rule" "vpn_to_rds" {
  type              = "ingress"
  from_port         = 5432
  to_port           = 5432
  protocol          = "tcp"
  cidr_blocks       = ["10.100.0.0/22"]
  security_group_id = aws_security_group.rds.id
  description       = "Allow Postgres from VPN clients"
}
