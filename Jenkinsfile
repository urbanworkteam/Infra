pipeline {
  agent {
    docker {
      image '851957594139.dkr.ecr.ap-northeast-2.amazonaws.com/farmily-tf-agent:1.1'
      label 'tf-ec2'
    }
  }

  options {
    timeout(time: 30, unit: 'MINUTES')
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '20'))
  }

  environment {
    AWS_REGION       = 'ap-northeast-2'
    TF_IN_AUTOMATION = 'true'
    TF_INPUT         = 'false'
    ENV              = "${env.BRANCH_NAME == 'main' ? 'prod' : 'dev'}"
    TF_DIR           = "Desktop/VPC/environments/${ENV}"
    ROLE_ARN         = "arn:aws:iam::851957594139:role/farmily/irsa/jenkins-tf-runner-${ENV}"
  }

  stages {

    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Assume Role') {
      steps {
        script {
          // EC2 인스턴스 프로파일(IMDSv2) → apply 역할 가정 (키리스)
          // readJSON: Pipeline Utility Steps 플러그인 필요
          def out = sh(returnStdout: true, script: """
            aws sts assume-role \
              --role-arn ${ROLE_ARN} \
              --role-session-name jenkins-tf-${ENV}-${BUILD_NUMBER} \
              --external-id farmily-tf-${ENV} \
              --output json
          """).trim()
          def json = readJSON text: out
          env.AWS_ACCESS_KEY_ID     = json.Credentials.AccessKeyId
          env.AWS_SECRET_ACCESS_KEY = json.Credentials.SecretAccessKey
          env.AWS_SESSION_TOKEN     = json.Credentials.SessionToken
        }
      }
    }

    stage('Validate') {
      steps {
        dir(TF_DIR) {
          sh 'terraform fmt -check -recursive'
          sh 'terraform init -backend=false'
          sh 'terraform validate'
          sh 'tflint --recursive'
          sh '''
            checkov -d . --framework terraform \
              --compact \
              --output cli \
              --output junitxml \
              --output-file-path console,checkov.xml \
              --soft-fail
          '''
        }
      }
      post {
        always {
          dir(TF_DIR) {
            junit allowEmptyResults: true, testResults: 'checkov.xml'
          }
        }
      }
    }

    stage('Plan') {
      steps {
        dir(TF_DIR) {
          sh 'terraform init -input=false'
          script {
            def rc = sh(returnStatus: true, script: '''
              terraform plan -input=false -lock-timeout=120s \
                -out=tfplan -detailed-exitcode
            ''')
            if (rc == 1) { error('terraform plan 실패') }
            env.TF_HAS_CHANGES = (rc == 2) ? 'true' : 'false'
          }
          stash name: 'tfplan', includes: 'tfplan'
          script {
            // PR 빌드일 때만 plan 결과를 PR 코멘트로 기록 (CHANGE_ID = PR 번호)
            if (env.CHANGE_ID) {
              sh 'terraform show -no-color tfplan > plan.txt'
              withCredentials([string(credentialsId: 'github-token', variable: 'GH_TOKEN')]) {
                sh """
                  gh pr comment ${env.CHANGE_ID} \
                    --body "\$(cat plan.txt)" \
                    --repo urbanworkteam/Infra
                """
              }
            }
          }
        }
      }
    }

    stage('Guard: No Destructive Changes') {
      // PR 빌드(CHANGE_ID 있음)는 plan 미리보기만 — apply 없으므로 Guard 불필요
      when {
        allOf {
          environment name: 'TF_HAS_CHANGES', value: 'true'
          not { expression { return env.CHANGE_ID != null } }
        }
      }
      steps {
        dir(TF_DIR) {
          sh '''
            terraform show -json tfplan > plan.json
            DESTROY=$(jq '[.resource_changes[]
                           | select(.change.actions | index("delete"))] | length' plan.json)
            echo "파괴적 변경(삭제/교체) 리소스 수: $DESTROY"
            if [ "$DESTROY" -gt 0 ]; then
              echo "삭제/교체가 포함됨 → 자동 적용 차단. plan을 사람이 검토할 것"
              jq -r '.resource_changes[]
                     | select(.change.actions | index("delete"))
                     | "  - \\(.address): \\(.change.actions|join(","))"' plan.json
              exit 1
            fi
          '''
        }
      }
    }

    stage('Approval (prod)') {
      // prod = main 브랜치, PR 빌드 아님, 변경 있을 때만 사람 승인
      when {
        allOf {
          branch 'main'
          environment name: 'TF_HAS_CHANGES', value: 'true'
          not { expression { return env.CHANGE_ID != null } }
        }
      }
      steps {
        input message: 'prod terraform apply 승인하시겠습니까?', ok: '적용'
      }
    }

    stage('Apply') {
      // PR 빌드는 plan 미리보기만 — 실제 apply는 PR 머지 후 빌드에서 실행
      when {
        allOf {
          environment name: 'TF_HAS_CHANGES', value: 'true'
          not { expression { return env.CHANGE_ID != null } }
        }
      }
      steps {
        dir(TF_DIR) {
          unstash 'tfplan'
          sh 'terraform init -input=false'
          sh 'terraform apply -input=false -lock-timeout=120s tfplan'
        }
      }
    }
  }

  post {
    success {
      script {
        if (env.TF_HAS_CHANGES == 'true' && !env.CHANGE_ID) {
          try {
            slackSend(
              channel: '#farmily-infra',
              color: 'good',
              message: "[Infra/${ENV}] terraform apply 완료\n${env.JOB_NAME} #${env.BUILD_NUMBER}\n<${env.BUILD_URL}|빌드 로그>"
            )
          } catch (e) { echo "Slack 알림 실패(토큰 미설정): ${e.message}" }
        }
      }
    }
    failure {
      script {
        try {
          slackSend(
            channel: '#farmily-infra',
            color: 'danger',
            message: "[Infra/${ENV}] 파이프라인 실패 (가드 차단 가능)\n${env.JOB_NAME} #${env.BUILD_NUMBER}\n<${env.BUILD_URL}|로그 확인>"
          )
        } catch (e) { echo "Slack 알림 실패(토큰 미설정): ${e.message}" }
      }
    }
    always {
      cleanWs()
    }
  }
}
