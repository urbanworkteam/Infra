# Jenkins External ALB — GitHub 웹훅 수신 전용
# jenkins.farmily.info → ALB(internet-facing, GitHub IPs only) → Jenkins EC2:8080

locals {
  dev_public_subnet_a = "subnet-0e6c50470bd82b2f0"
  dev_public_subnet_c = "subnet-0e84497444f496f84"
}

data "aws_route53_zone" "main" {
  name = "farmily.info."
}

# ────────────────────────────────────────────────────────────────
# 1. ACM 인증서
# ────────────────────────────────────────────────────────────────
resource "aws_acm_certificate" "jenkins" {
  domain_name       = "jenkins.farmily.info"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { project = "farmily", team = "urbanwork", purpose = "jenkins-alb-tls" }
}

resource "aws_route53_record" "jenkins_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.jenkins.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = data.aws_route53_zone.main.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]
}

resource "aws_acm_certificate_validation" "jenkins" {
  certificate_arn         = aws_acm_certificate.jenkins.arn
  validation_record_fqdns = [for r in aws_route53_record.jenkins_cert_validation : r.fqdn]
}

# ────────────────────────────────────────────────────────────────
# 2. External ALB SG — GitHub webhook IP만 허용
# name_prefix 사용: create_before_destroy 시 동일 이름 충돌 방지
# ────────────────────────────────────────────────────────────────
resource "aws_security_group" "jenkins_alb" {
  name_prefix = "farmily-jenkins-alb-sg-"
  description = "Jenkins ALB - GitHub webhook IPs only"
  vpc_id      = local.dev_vpc_id

  ingress {
    description = "GitHub webhook HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [
      "192.30.252.0/22",
      "185.199.108.0/22",
      "140.82.112.0/20",
      "143.55.64.0/20",
    ]
    ipv6_cidr_blocks = ["2a0a:a440::/29", "2606:50c0::/32"]
  }

  ingress {
    description = "GitHub webhook HTTP (redirect)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [
      "192.30.252.0/22",
      "185.199.108.0/22",
      "140.82.112.0/20",
      "143.55.64.0/20",
    ]
    ipv6_cidr_blocks = ["2a0a:a440::/29", "2606:50c0::/32"]
  }

  # prod-eks 빌드 에이전트(WebSocket) — prod NAT EIP 2개만 443 허용 (B-lite)
  # 에이전트 파드(prod VPC) → prod NAT egress → 인터넷 → 이 ALB → 컨트롤러 8080(WS 업그레이드)
  ingress {
    description = "prod-eks Jenkins agents (WebSocket over 443)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["3.39.94.155/32", "52.78.114.190/32"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = { project = "farmily", team = "urbanwork", purpose = "jenkins-alb" }
}

# [2026-06-25] jenkins_from_alb(8080 from ALB)는 vpn.tf의 aws_security_group.jenkins 인라인 ingress로 통합.
#   사유: 인라인 ingress + 별도 aws_security_group_rule 혼용 = 같은 SG 충돌(provider) → plan마다 ALB 규칙 삭제 시도.
#   state 분리: terraform state rm aws_security_group_rule.jenkins_from_alb (실제 AWS 규칙은 인라인이 그대로 소유).

# ────────────────────────────────────────────────────────────────
# 3. External ALB
# ────────────────────────────────────────────────────────────────
resource "aws_lb" "jenkins" {
  name               = "farmily-jenkins-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.jenkins_alb.id]
  subnets            = [local.dev_public_subnet_a, local.dev_public_subnet_c]

  # WebSocket 에이전트 연결은 장수명 — 기본 60s면 조용한 구간에 끊길 수 있어 상향 (B-lite)
  idle_timeout = 300

  tags = { project = "farmily", team = "urbanwork", purpose = "jenkins-webhook" }
}

# ────────────────────────────────────────────────────────────────
# 4. Target Group
# ────────────────────────────────────────────────────────────────
resource "aws_lb_target_group" "jenkins" {
  name     = "farmily-jenkins-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = local.dev_vpc_id

  health_check {
    path                = "/login"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 10
  }

  tags = { project = "farmily", team = "urbanwork" }
}

resource "aws_lb_target_group_attachment" "jenkins" {
  target_group_arn = aws_lb_target_group.jenkins.arn
  target_id        = aws_instance.jenkins.id
  port             = 8080
}

# ────────────────────────────────────────────────────────────────
# 5. 리스너
# ────────────────────────────────────────────────────────────────
resource "aws_lb_listener" "jenkins_https" {
  load_balancer_arn = aws_lb.jenkins.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.jenkins.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.jenkins.arn
  }
}

resource "aws_lb_listener" "jenkins_http" {
  load_balancer_arn = aws_lb.jenkins.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# ────────────────────────────────────────────────────────────────
# 6. Route53 — jenkins.farmily.info → External ALB (공개 zone)
# ────────────────────────────────────────────────────────────────
resource "aws_route53_record" "jenkins" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "jenkins.farmily.info"
  type    = "A"

  alias {
    name                   = aws_lb.jenkins.dns_name
    zone_id                = aws_lb.jenkins.zone_id
    evaluate_target_health = true
  }
}

output "jenkins_alb_dns" {
  value = aws_lb.jenkins.dns_name
}

output "jenkins_url" {
  value = "https://jenkins.farmily.info (GitHub webhook only)"
}
