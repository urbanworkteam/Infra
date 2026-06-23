terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
  }
}

provider "aws" {
  region = var.region
}

# CloudFront용 ACM 인증서는 반드시 us-east-1 에 있어야 함
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

# Route53에서 도메인 구매 시 자동 생성된 호스팅 영역 참조 (새로 만들지 않음)
data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

# ALB(앱/API)용 인증서 - 서울 리전
module "acm_alb" {
  source = "../../modules/acm"

  domain_name = var.api_domain
  zone_id     = data.aws_route53_zone.main.zone_id
  # TODO(직접) ③ — ECS 전용 호스트를 인증서 SAN 에 추가(module.ecs.ecs_only_host 와 동일 값).
  #   dev 예: subject_alternative_names = ["ecs.dev.farmily.info"]
  subject_alternative_names = ["ecs.farmily.info"]
}

# CloudFront(정적 웹)용 인증서 - us-east-1
module "acm_cloudfront" {
  source = "../../modules/acm"
  providers = {
    aws = aws.us_east_1
  }

  domain_name               = var.web_domain
  subject_alternative_names = var.web_domain_aliases
  zone_id                   = data.aws_route53_zone.main.zone_id
}

# 앱 시크릿(Secrets Manager) — 값이 아니라 ARN만 참조(평문 노출 없음). secrets[] 주입·정책에 사용.
data "aws_secretsmanager_secret" "app" {
  name = "farmily/prod/app"
}

locals {
  app_secret_keys = [
    "DB_PASSWORD", "JWT_SECRET", "KAKAO_CLIENT_SECRET", "KAKAO_ADMIN_KEY",
    "KMA_SERVICE_KEY", "PORTONE_API_KEY", "PORTONE_API_SECRET",
    "PORTONE_WEBHOOK_SECRET", "FCM_SERVICE_ACCOUNT_JSON",
  ]
  app_secrets = [for k in local.app_secret_keys : {
    name      = k
    valueFrom = "${data.aws_secretsmanager_secret.app.arn}:${k}::"
  }]

  # 민감 키는 env에서 제외(secrets[]로만 주입) — tfvars에 값이 남아 있어도 평문 env로 새거나 secrets와 중복되지 않게 방어
  app_environment = [
    for e in concat(var.extra_environment, [
      { name = "S3_BUCKET", value = module.s3.bucket_id },
      { name = "S3_REGION", value = var.region },
      { name = "CDN_BASE_URL", value = "https://${aws_cloudfront_distribution.images.domain_name}" },
      { name = "AI_PROVIDER", value = var.ai_provider },
      { name = "AWS_REGION", value = var.bedrock_region },
      { name = "BEDROCK_AGENT_ID", value = var.bedrock_agent_id },
      { name = "BEDROCK_AGENT_ALIAS_ID", value = var.bedrock_agent_alias_id },
    ]) : e if !contains(local.app_secret_keys, e.name)
  ]
}

module "vpc" {
  source = "../../modules/vpc"

  env                   = "prod"
  region                = var.region
  vpc_cidr              = "10.1.0.0/16"
  public_subnet_a_cidr  = "10.1.1.0/24"
  public_subnet_c_cidr  = "10.1.2.0/24"
  private_subnet_a_cidr = "10.1.10.0/24"
  private_subnet_c_cidr = "10.1.11.0/24"
  enable_multi_nat      = true
  enable_vpn            = false
}

module "sg" {
  source = "../../modules/sg"

  env                   = "prod"
  vpc_id                = module.vpc.vpc_id
  enable_lambda_sg      = true
  enable_noti_lambda_sg = true
  agentcore_sg_id       = aws_security_group.agentcore.id      # AgentCore->RDS(5432) 인바운드 추가
  eks_cluster_sg_id     = module.eks.cluster_security_group_id # EKS 파드 -> RDS/Redis 인바운드 허용(추가만)
}

# AgentCore 서비스 SG — 콘솔로 먼저 생성(sg-02e5f7d4280c8b580)한 것을 terraform import 로 흡수.
# ⚠️ 이름에 env 프리픽스(prod-)가 없는 이유: 콘솔 생성명 "farmily-agentcore-sg"를 그대로 둬야 import가 깨지지 않음
#    (SG name 은 변경 불가 속성이라, 이름이 다르면 import 후 apply 가 destroy+create 로 재생성 시도 → 운영 중이면 위험).
# 규칙은 실제 SG와 1:1 일치시켜 import 후 plan 이 zero-diff(또는 태그 1개만) 되도록 함.
# AgentCore→RDS(5432) 인바운드는 별도(relay 드리프트 해결 후 분리형 ingress rule 로 추가) — 본 정의엔 미포함.
resource "aws_security_group" "agentcore" {
  name        = "farmily-agentcore-sg"
  description = "AgentCore ECS security group"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Backend calls AgentCore"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["10.1.0.0/16"] # VPC 내부에서 호출 (실제 SG 규칙과 동일)
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "farmily-agentcore-sg" }
}

module "ecs" {
  source = "../../modules/ecs"

  env                       = "prod"
  region                    = var.region
  vpc_id                    = module.vpc.vpc_id
  public_subnet_ids         = [module.vpc.public_subnet_a_id, module.vpc.public_subnet_c_id]
  private_subnet_ids        = [module.vpc.private_subnet_a_id, module.vpc.private_subnet_c_id]
  container_image           = var.container_image
  desired_count             = 1
  max_count                 = 8
  task_cpu                  = "512"
  task_memory               = "1024"
  ecs_security_group_ids    = [module.sg.ecs_sg_id]
  alb_security_group_ids    = [module.sg.alb_sg_id]
  spring_profile            = "prod"
  enable_https              = true
  alb_certificate_arn       = module.acm_alb.certificate_arn
  db_address                = module.rds.address
  db_name                   = var.db_name
  db_username               = var.db_username
  db_password               = var.db_password
  redis_endpoint            = module.elasticache.primary_endpoint
  extra_environment         = local.app_environment
  app_secrets               = local.app_secrets
  app_secret_arn_patterns   = [data.aws_secretsmanager_secret.app.arn]
  s3_bucket_arn             = module.s3.bucket_arn
  enable_bedrock            = var.ai_provider == "bedrock"
  enable_container_insights = true

  # 블루그린 토대: prod-eks-tg + ecs_only 리스너 룰 생성. 리스너 가중 라우팅은
  # modules/ecs/main.tf:214 의 ignore_changes=[default_action] 때문에 Terraform 이 안 건드림
  # → 트래픽 100% ECS 유지(라이브 무영향). EKS TG weight-0 등록은 콘솔/CLI 로 수동.
  enable_eks_bluegreen = true
  # TODO(직접) ③ — ECS 전용 탈출 호스트. dev = "ecs.dev.farmily.info".
  #   prod 는 새 호스트(예: "ecs.farmily.info")로 정하고, 아래 acm_alb SAN + route53 에도 같은 값 추가.
  ecs_only_host = "ecs.farmily.info" # TODO(직접): 예 "ecs.farmily.info"
}

module "rds" {
  source = "../../modules/rds"

  env                 = "prod"
  private_subnet_ids  = [module.vpc.private_subnet_a_id, module.vpc.private_subnet_c_id]
  security_group_ids  = [module.sg.rds_sg_id]
  instance_class      = "db.t3.small"
  allocated_storage   = 20
  db_name             = var.db_name
  db_username         = var.db_username
  db_password         = var.db_password
  multi_az            = true
  monitoring_interval = 30
  enable_read_replica = true
}

module "elasticache" {
  source = "../../modules/elasticache"

  env                        = "prod"
  private_subnet_ids         = [module.vpc.private_subnet_a_id, module.vpc.private_subnet_c_id]
  security_group_ids         = [module.sg.redis_sg_id]
  node_type                  = "cache.t3.small"
  num_cache_clusters         = 2
  transit_encryption_enabled = true
  transit_encryption_mode    = "required"
}

# 업로드 전용 버킷 (앱 presigned, CORS 필요 - 디지털명함/Expo 웹이 이미지 직접 GET/PUT)
module "s3" {
  source = "../../modules/s3"

  env                  = "prod"
  bucket_name          = var.s3_bucket_name
  cors_allowed_origins = ["http://localhost:3000", "https://farmily.info", "https://www.farmily.info"]
}

# S3 CRR: farmily-s3-bucket → 도쿄 복제
resource "aws_iam_role" "s3_replication" {
  name = "prod-s3-replication-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "s3_replication" {
  name = "prod-s3-replication-policy"
  role = aws_iam_role.s3_replication.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
        Resource = [module.s3.bucket_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObjectVersionForReplication", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"]
        Resource = ["${module.s3.bucket_arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags"]
        Resource = ["arn:aws:s3:::farmily-s3-bucket-dr/*"]
      }
    ]
  })
}

resource "aws_s3_bucket_replication_configuration" "images_crr" {
  bucket = module.s3.bucket_id
  role   = aws_iam_role.s3_replication.arn

  rule {
    id     = "dr-replication"
    status = "Enabled"

    destination {
      bucket        = "arn:aws:s3:::farmily-s3-bucket-dr"
      storage_class = "STANDARD"
    }
  }
}

# ECR Replication: farmily-api → 도쿄 자동 복제
resource "aws_ecr_replication_configuration" "dr" {
  replication_configuration {
    rule {
      destination {
        region      = "ap-northeast-1"
        registry_id = "851957594139"
      }
      repository_filter {
        filter      = "farmily"
        filter_type = "PREFIX_MATCH"
      }
    }
  }
}

# 프론트(디지털명함) 정적 웹 전용 버킷 (CloudFront 오리진, CORS 불필요)
module "s3_web" {
  source = "../../modules/s3"

  env         = "prod"
  bucket_name = "farmily-prod-frontend-web"
}

# AI 디지털명함 HTML 템플릿 버킷 — 콘솔로 먼저 생성(farmily-templates, template_a/*.html 보유)한 것을 import 로 흡수.
# CORS 미설정(빈 배열) = 현 버킷과 동일. PAB 4종 true 도 모듈 기본과 일치.
# ⚠️ import 후 plan 에서 2가지 delta 예상(둘 다 무해/개선): ① Name=prod-s3 태그 추가 ② 버저닝 Enabled
#    (현 버킷은 버저닝 비활성 → 모듈이 Enabled 적용. 템플릿 덮어쓰기 복구 가능해지는 의도된 개선).
module "s3_templates" {
  source = "../../modules/s3"

  env         = "prod"
  bucket_name = "farmily-templates"
}

module "cloudfront" {
  source = "../../modules/cloudfront"

  env                   = "prod"
  s3_bucket_domain_name = module.s3_web.bucket_domain_name
  aliases               = concat([var.web_domain], var.web_domain_aliases)
  acm_certificate_arn   = module.acm_cloudfront.certificate_arn
}

module "route53" {
  source = "../../modules/route53"

  zone_id = data.aws_route53_zone.main.zone_id

  # 앱/API -> ALB 직접 (api.farmily.info는 Failover로 분리)
  alb_dns_name     = module.ecs.alb_dns_name
  alb_zone_id      = module.ecs.alb_zone_id
  alb_record_names = ["ecs.farmily.info"]

  # 정적 웹 -> CloudFront
  cloudfront_domain_name  = module.cloudfront.distribution_domain_name
  cloudfront_record_names = concat([var.web_domain], var.web_domain_aliases)
}

# ==============================================================================
# Route 53 Failover (api.farmily.info)
# ==============================================================================
resource "aws_route53_health_check" "seoul_alb" {
  fqdn              = "api.farmily.info"
  port              = 443
  type              = "HTTPS"
  resource_path     = "/api/v1/health"
  failure_threshold = 3
  request_interval  = 10

  tags = { Name = "seoul-alb-health" }
}

resource "aws_route53_record" "api_primary" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "api.farmily.info"
  type    = "A"

  set_identifier = "primary-seoul"
  failover_routing_policy { type = "PRIMARY" }
  health_check_id = aws_route53_health_check.seoul_alb.id

  alias {
    name                   = module.ecs.alb_dns_name
    zone_id                = module.ecs.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "api_secondary" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "api.farmily.info"
  type    = "A"

  set_identifier = "secondary-tokyo"
  failover_routing_policy { type = "SECONDARY" }

  alias {
    name                   = "dr-alb-489281855.ap-northeast-1.elb.amazonaws.com"
    zone_id                = "Z14GRHDCWA56QT" # ap-northeast-1 ALB hosted zone ID
    evaluate_target_health = true
  }
}

# ==============================================================================
# DR Failover Alert (CloudWatch + SNS)
# ==============================================================================
resource "aws_sns_topic" "dr_alerts" {
  name = "dr-failover-alerts"
}

resource "aws_cloudwatch_metric_alarm" "dr_health_check" {
  alarm_name          = "dr-seoul-health-check-failed"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  alarm_description   = "Seoul ALB health check failed - potential region failure"

  dimensions = {
    HealthCheckId = aws_route53_health_check.seoul_alb.id
  }

  alarm_actions = [aws_sns_topic.dr_alerts.arn]
  ok_actions    = [aws_sns_topic.dr_alerts.arn]
}

module "cloudwatch" {
  source = "../../modules/cloudwatch"

  env              = "prod"
  ecs_cluster_name = "prod-cluster"
  ecs_service_name = "prod-app-service"
  rds_instance_id  = "prod-rds"
}

# ALB L7 방어 — AWS WAF(rate-limit + AWS managed 룰). Shield Standard(L3/L4)는 자동.
# common_rule_action="count": SQLi/XSS 룰은 초기 관측 → 오탐 검증 후 "none"(차단)으로 승격.
module "waf" {
  source = "../../modules/waf"

  env                = "prod"
  alb_arn            = module.ecs.alb_arn
  rate_limit_global  = 2000   # AWS SRT 권장 예시값
  rate_limit_auth    = 100    # 로그인 brute-force, 로그 보고 10~50으로 조임
  common_rule_action = "none" # 2026-06-15 Count 관측(오탐0, .git 스캐너만 매치) 후 Block 승격
}

resource "aws_s3_bucket_policy" "frontend_oac" {
  bucket = module.s3_web.bucket_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${module.s3_web.bucket_arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = module.cloudfront.distribution_arn
        }
      }
    }]
  })
}

# 이미지 업로드/AI카드 전용, CloudFront - farmily-s3-bucket 전체를 OAC로 서빙
resource "aws_cloudfront_origin_access_control" "images" {
  name                              = "prod-image-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "images" {
  enabled = true

  origin {
    domain_name              = module.s3.bucket_domain_name # farmily-s3-bucket 리전 도메인
    origin_id                = "images-s3-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.images.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "images-s3-origin"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
    min_ttl     = 0
    default_ttl = 86400 # 1일 (카드/이미지는 한 번 쓰고 안 바뀜)
    max_ttl     = 31536000
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  # 기본 *.cloudfront.net 도메인 사용 (커스텀 도메인 불필요)
  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Name = "prod-images-cloudfront" }
}

resource "aws_s3_bucket_policy" "images_oac" {
  bucket = module.s3.bucket_id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${module.s3.bucket_arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.images.arn
        }
      }
    }]
  })
}

# EKS — ECS 옆에 세우는 블루그린 토대 (prod). 트래픽은 100% ECS 유지, EKS는 0%.
# 컨트롤플레인 ENI는 private+public 서브넷, 노드는 private 서브넷에만.
module "eks" {
  source = "../../modules/eks"

  env                = "prod"
  region             = var.region
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = [module.vpc.private_subnet_a_id, module.vpc.private_subnet_c_id]
  public_subnet_ids  = [module.vpc.public_subnet_a_id, module.vpc.public_subnet_c_id]

  cluster_version = "1.35"

  node_instance_types = ["t3.medium"]
  node_desired_size   = 2
}

