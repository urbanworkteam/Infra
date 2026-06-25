# Jenkins EC2 인스턴스 — dev private subnet, VPN 접속 전용
#
# 접속 경로: Client VPN → 10.2.0.0/22(VPN CIDR) → farmily-jenkins-sg → 8080/22
# IAM 체인: EC2(인스턴스 프로파일) → farmily-jenkins-ec2-role → jenkins-tf-runner-{dev,prod}
# ⚠️ B-lite(2026-06-25) 후: terraform assume-role은 prod-eks 파드의 IRSA(prod-eks-jenkins-tf-role)가 수행.
#    이 EC2 인스턴스 프로파일 체인은 컨트롤러용으로만 잔존(빌드는 파드).
#
# 초기 비밀번호: sudo cat /var/lib/jenkins/secrets/initialAdminPassword

# SSM Parameter Store에서 최신 Amazon Linux 2023 AMI 자동 조회
# hardcode 대신 SSM 참조 — 매번 apply 시 최신 AL2023 AMI를 가져옴
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

variable "jenkins_key_name" {
  description = "EC2 키페어 이름 (SSH 접속용). 빈 문자열이면 키페어 없이 생성"
  type        = string
  default     = ""
}

resource "aws_instance" "jenkins" {
  ami           = data.aws_ssm_parameter.al2023.value
  instance_type = "t3.medium"   # 2 vCPU / 4 GB — Jenkins LTS 최소 권장
  subnet_id     = local.dev_private_subnet

  vpc_security_group_ids = [aws_security_group.jenkins.id]
  iam_instance_profile   = aws_iam_instance_profile.jenkins_ec2.name
  private_ip             = "10.0.10.250"

  key_name = var.jenkins_key_name != "" ? var.jenkins_key_name : null

  # IMDSv2 강제
  # http_tokens=required : v1(curl 169.254.169.254 직접 호출) 차단 → SSRF로 토큰 탈취 불가
  # hop_limit=1          : host(네이티브 Jenkins systemd)만 IMDS 접근 — 컨테이너는 차단(하드닝).
  #   한때 2였던 이유 = 옛 agent{docker} 빌드 컨테이너가 IMDS(assume-role) 필요했기 때문.
  #   B-lite(2026-06-25)로 빌드가 prod-eks 파드로 이동 → EC2 빌드 컨테이너 소멸(실측 컨테이너 0) → 1로 환원.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    delete_on_termination = true
    encrypted             = true

    tags = { Name = "farmily-jenkins-root", project = "farmily" }
  }

  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail

    hostnamectl set-hostname farmily-jenkins

    # 시스템 패키지 최신화
    dnf update -y

    # Java 21 — Jenkins LTS 최소 요구 버전 (Amazon Corretto)
    dnf install -y java-21-amazon-corretto-headless

    # Jenkins LTS 레포 등록 및 설치
    wget -O /etc/yum.repos.d/jenkins.repo \
      https://pkg.jenkins.io/redhat-stable/jenkins.repo
    rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
    dnf install -y jenkins

    # Jenkins 서비스 시작 (부팅 시 자동 시작 포함)
    systemctl enable --now jenkins

    # CloudWatch Agent 설치 (로그 수집 — 별도 config 적용 필요)
    dnf install -y amazon-cloudwatch-agent
  EOF

  tags = {
    Name    = "farmily-jenkins"
    project = "farmily"
    team    = "urbanwork"
    env     = "jenkins"
    purpose = "ci-cd-terraform-pipeline"
  }
}
