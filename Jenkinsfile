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
    HELM_CACHE_HOME  = '/tmp/helm-cache'
    HELM_DATA_HOME   = '/tmp/helm-data'
    HELM_CONFIG_HOME = '/tmp/helm-config'
    TF_SKIP          = 'false'
  }

  stages {

    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Check Changes') {
      steps {
        script {
          // PR 빌드는 merge commit + shallow clone이라 HEAD~1 기준 diff가 틀어짐.
          // → 머지 대상(CHANGE_TARGET)을 fetch해 FETCH_HEAD 기준으로 "이 PR이 더한 변경"만 잡는다.
          //   (origin/<branch> ref 존재에 의존하지 않으려고 FETCH_HEAD 사용)
          // branch 빌드(직접 push)는 CHANGE_TARGET이 없어 직전 커밋 기준 fallback.
          // sh는 set +e·2>/dev/null·true로 항상 0 종료 → returnStdout 예외(빌드 ERROR) 방지.
          def isPR = (env.CHANGE_TARGET != null && env.CHANGE_TARGET != '')
          def changed = sh(
            returnStdout: true,
            script: isPR
              ? """
                set +e
                git fetch --no-tags --depth=100 origin ${env.CHANGE_TARGET} >/dev/null 2>&1
                git diff --name-only FETCH_HEAD HEAD 2>/dev/null
                true
              """
              : """
                set +e
                git diff --name-only HEAD~1 HEAD 2>/dev/null || git show --name-only --format='' HEAD 2>/dev/null
                true
              """
          ).trim()

          // 진단: 다음 빌드 로그에서 base·변경목록을 바로 확인(오작동 시 원인 추적용)
          echo "Check Changes — base=${isPR ? "FETCH_HEAD(${env.CHANGE_TARGET})" : 'HEAD~1'} / 변경 파일:\n${changed ?: '(없음/판정불가)'}"

          // terraform 코드는 전부 Desktop/VPC/ 아래(environments·modules)에 있다.
          // 기존 'environments/'·'modules/'(루트) 매칭은 실제 경로와 안 맞아 무력 → Desktop/VPC/로 교정.
          def tfChanged
          if (isPR && changed == '') {
            // PR인데 변경목록을 못 구함(fetch 실패 등) → 안전하게 Terraform 실행(skip 안 함 = false-skip 방지)
            tfChanged = true
            echo "PR 변경목록 판정불가 — 안전상 Terraform 실행"
          } else {
            tfChanged = changed.split('\n').any { f -> f.startsWith('Desktop/VPC/') }
          }

          if (!tfChanged) {
            env.TF_SKIP = 'true'
            echo "Terraform(Desktop/VPC/) 변경 없음 (gitops/·docker/·policy/ 등) — Terraform 단계 전체 건너뜀"
          } else {
            echo "Terraform 변경 감지(또는 판정불가) — plan/apply 진행"
          }
        }
      }
    }

    stage('Assume Role') {
      when { environment name: 'TF_SKIP', value: 'false' }
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

    stage('Load Vars') {
      when { environment name: 'TF_SKIP', value: 'false' }
      steps {
        script {
          def ssm = { String key ->
            sh(returnStdout: true,
               script: "aws ssm get-parameter --name '/farmily/${ENV}/${key}' --with-decryption --query Parameter.Value --output text").trim()
          }
          env.TF_VAR_container_image = ssm('container_image')
          env.TF_VAR_db_name         = ssm('db_name')
          env.TF_VAR_db_username     = ssm('db_username')
          env.TF_VAR_db_password     = ssm('db_password')
          env.TF_VAR_s3_bucket_name  = ssm('s3_bucket_name')
        }
      }
    }

    stage('Validate') {
      when { environment name: 'TF_SKIP', value: 'false' }
      steps {
        dir(TF_DIR) {
          sh 'terraform fmt -check -recursive'
          sh 'terraform init -backend=false'
          sh 'terraform validate'
          sh 'tflint --recursive || true'
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
      when { environment name: 'TF_SKIP', value: 'false' }
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
              // farmily-gitops-bot GitHub App credential — 빌드마다 단명 installation 토큰 발급.
              // 개인 PAT(github-pat-token) 제거 → terraform plan 코멘트가 사람이 아닌 봇 이름으로 게시됨.
              // GitHub App credential은 usernamePassword 형: username=App ID, password=발급된 토큰.
              withCredentials([usernamePassword(credentialsId: 'github-app-gitops-bot',
                                                usernameVariable: 'GH_APP_ID',
                                                passwordVariable: 'GH_TOKEN')]) {
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
          withCredentials([string(credentialsId: 'slack-infra-webhook', variable: 'SLACK_URL')]) {
            sh """curl -s -X POST "\$SLACK_URL" \
              -H 'Content-type: application/json' \
              -d '{"text":"[Infra/${ENV}] terraform apply 완료\\n${env.JOB_NAME} #${env.BUILD_NUMBER} <${env.BUILD_URL}|빌드 로그>"}'"""
          }
        }
      }
    }
    failure {
      script {
        withCredentials([string(credentialsId: 'slack-infra-webhook', variable: 'SLACK_URL')]) {
          sh """curl -s -X POST "\$SLACK_URL" \
            -H 'Content-type: application/json' \
            -d '{"text":"[Infra/${ENV}] 파이프라인 실패\\n${env.JOB_NAME} #${env.BUILD_NUMBER} <${env.BUILD_URL}|로그 확인>"}'"""
        }
      }
    }
    always {
      cleanWs()
    }
  }
}
