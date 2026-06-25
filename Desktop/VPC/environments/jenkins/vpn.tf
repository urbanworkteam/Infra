# AWS Client VPN — Jenkins·Grafana 등 dev VPC 내부망 접근용
#
# 인증 방식: mutual TLS (서버 + 클라이언트 인증서)
# 연결 후 접근 가능: Jenkins EC2(8080), Grafana(EKS 전환 후), dev RDS/Redis
#
# 인증서 ARN: ACM에 수동 업로드 완료 (vpn-certs/ 디렉토리, git 제외)
# 서버: arn:aws:acm:ap-northeast-2:851957594139:certificate/e285d384-b788-4a8a-b33d-d356b985e806 (Key Usage + EKU 포함)
# 클라이언트: arn:aws:acm:ap-northeast-2:851957594139:certificate/3643b889-ed8e-4a0f-b646-7da26504c728

locals {
  dev_vpc_id         = "vpc-0bbc10947088b1d1c"
  dev_private_subnet = "subnet-04bde333b9e019d43" # dev-private-subnet-a (ap-northeast-2a)
  vpn_cidr           = "10.2.0.0/22"              # dev VPC(10.0.0.0/16)와 겹치지 않는 클라이언트 IP 대역

  server_cert_arn = "arn:aws:acm:ap-northeast-2:851957594139:certificate/e285d384-b788-4a8a-b33d-d356b985e806"
  client_cert_arn = "arn:aws:acm:ap-northeast-2:851957594139:certificate/3643b889-ed8e-4a0f-b646-7da26504c728"
}

# ────────────────────────────────────────────────────────────────
# 1. VPN 엔드포인트용 SG
# ────────────────────────────────────────────────────────────────
resource "aws_security_group" "vpn_endpoint" {
  name        = "farmily-vpn-endpoint-sg"
  description = "Client VPN endpoint - UDP 443 inbound"
  vpc_id      = local.dev_vpc_id

  ingress {
    description = "OpenVPN"
    from_port   = 443
    to_port     = 443
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { project = "farmily", team = "urbanwork", purpose = "client-vpn" }
}

# ────────────────────────────────────────────────────────────────
# 2. Jenkins EC2용 SG (VPN 클라이언트 CIDR에서만 8080 허용)
# ────────────────────────────────────────────────────────────────
resource "aws_security_group" "jenkins" {
  name        = "farmily-jenkins-sg"
  description = "Jenkins EC2 - VPN clients only 8080"
  vpc_id      = local.dev_vpc_id

  ingress {
    description = "Jenkins UI - via VPN ENI (Client VPN NAT: src IP = VPN ENI, not client IP)"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["10.0.10.0/24"]
  }

  ingress {
    description = "SSH - via VPN ENI"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.10.0/24"]
  }

  # ALB → Jenkins 8080. 인라인으로 통합(전엔 alb.tf의 별도 aws_security_group_rule.jenkins_from_alb).
  # 인라인 ingress + 별도 rule 혼용은 같은 SG 충돌(provider) → plan마다 이 규칙 삭제 시도하던 것 해소.
  ingress {
    description     = "Jenkins UI from External ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.jenkins_alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { project = "farmily", team = "urbanwork", env = "jenkins" }
}

# ────────────────────────────────────────────────────────────────
# 3. Client VPN 엔드포인트
# ────────────────────────────────────────────────────────────────
resource "aws_ec2_client_vpn_endpoint" "farmily" {
  description            = "farmily-client-vpn"
  client_cidr_block      = local.vpn_cidr
  server_certificate_arn = local.server_cert_arn
  vpc_id                 = local.dev_vpc_id
  security_group_ids     = [aws_security_group.vpn_endpoint.id]

  # mutual TLS — 클라이언트도 인증서 제시해야 연결 허용
  authentication_options {
    type                       = "certificate-authentication"
    root_certificate_chain_arn = local.client_cert_arn
  }

  connection_log_options {
    enabled               = true
    cloudwatch_log_group  = aws_cloudwatch_log_group.vpn.name
    cloudwatch_log_stream = aws_cloudwatch_log_stream.vpn.name
  }

  # split tunnel — VPN 연결 시 AWS 트래픽만 터널로, 일반 인터넷은 직접
  # false(full tunnel)로 하면 모든 트래픽이 VPN 경유 → 인터넷 느려짐
  split_tunnel = true

  tags = { project = "farmily", team = "urbanwork", purpose = "client-vpn" }
}

# ────────────────────────────────────────────────────────────────
# 4. 서브넷 연결 (dev private subnet-a)
# ────────────────────────────────────────────────────────────────
resource "aws_ec2_client_vpn_network_association" "farmily" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.farmily.id
  subnet_id              = local.dev_private_subnet
}

# ────────────────────────────────────────────────────────────────
# 5. 인증 규칙 — VPN 클라이언트 → dev VPC 전체 허용
# ────────────────────────────────────────────────────────────────
resource "aws_ec2_client_vpn_authorization_rule" "dev_vpc" {
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.farmily.id
  target_network_cidr    = "10.0.0.0/16" # dev VPC 전체
  authorize_all_groups   = true
}

# ────────────────────────────────────────────────────────────────
# 6. VPN 연결 로그 (CloudWatch)
# ────────────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "vpn" {
  name              = "/farmily/vpn/connections"
  retention_in_days = 30
  tags              = { project = "farmily", team = "urbanwork" }
}

resource "aws_cloudwatch_log_stream" "vpn" {
  name           = "client-vpn"
  log_group_name = aws_cloudwatch_log_group.vpn.name
}
