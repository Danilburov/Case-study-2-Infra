# ---- Client VPN endpoint ----
resource "aws_ec2_client_vpn_endpoint" "team_vpn" {
  description            = "case-study-2-client-vpn"
  server_certificate_arn = var.server_cert_arn
  client_cidr_block      = "10.100.0.0/22"
  split_tunnel           = true
  dns_servers            = ["8.8.8.8"]
  transport_protocol     = "udp"

  authentication_options {
    type                       = "certificate-authentication"
    root_certificate_chain_arn = var.server_cert_arn
  }

  connection_log_options { enabled = false }

  tags = { Name = "case-study-2-vpn" }
}

//associating the VPN to one private app subnet in the same vpc
resource "aws_ec2_client_vpn_network_association" "vpn_assoc" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.team_vpn.id
  subnet_id              = aws_subnet.app[0].id
}

//allow VPN clients to access the entire VPC CIDR
resource "aws_ec2_client_vpn_authorization_rule" "allow_vpc" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.team_vpn.id
  target_network_cidr    = var.vpc_cidr
  authorize_all_groups   = true
  description            = "Allow access to all VPC networks"
}

//making routes from VPN to private subnets
locals {
  vpn_target_subnet_id = aws_ec2_client_vpn_network_association.vpn_assoc.subnet_id
  private_cidrs        = concat(var.app_subnet_cidrs, var.data_subnet_cidrs)
}

resource "aws_ec2_client_vpn_route" "to_private" {
  for_each               = toset(local.private_cidrs)
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.team_vpn.id
  destination_cidr_block = each.value
  target_vpc_subnet_id   = local.vpn_target_subnet_id
  depends_on             = [aws_ec2_client_vpn_network_association.vpn_assoc]
}
