// ── GitHub 커스텀 상태 context 게시 ─────────────────────────────────────────
// 문제: terraform·gitops 두 Multibranch Job이 같은 'continuous-integration/jenkins/pr-head'
//   context로 보고 → GitHub는 commit당 context별 최신 1개만 보관 → 늦게 끝난 Job이 덮어써 비결정적.
// 해결: 이 Job 전용 context(CONTEXT)로 별도 게시 → PR 체크가 terraform/gitops로 분리됨.
//   (github-branch-source 옛 버전이라 'Custom GitHub Notification Context' trait 부재 → 코드로 직접.)
// 도구: curl + git만 사용(gitops-agent엔 jq·gh 없음 — 두 파일 동일 방식). 게시 실패는 빌드 안 깸(best-effort).
def ghStatus(String state, String description) {
  def CONTEXT = 'continuous-integration/jenkins/terraform'
  try {
    withCredentials([usernamePassword(credentialsId: 'github-app-gitops-bot',
                                      usernameVariable: 'GH_APP_ID',
                                      passwordVariable: 'GH_TOKEN')]) {
      def sha
      if (env.CHANGE_ID) {
        // PR 빌드: 머지커밋(GIT_COMMIT) 아닌 PR head SHA에 찍어야 PR 화면에 표시됨.
        // pull/<번호>/head = GitHub가 노출하는 PR head ref(머지/헤드 모드·parent 순서 무관).
        sha = sh(returnStdout: true, script:
          'git ls-remote "https://x-access-token:${GH_TOKEN}@github.com/urbanworkteam/Infra" "pull/' + env.CHANGE_ID + '/head" | cut -f1'
        ).trim()
      } else {
        sha = env.GIT_COMMIT   // branch 빌드: 체크아웃된 커밋이 곧 대상
      }
      if (!sha) { echo 'ghStatus: SHA 획득 실패 — 게시 생략'; return }
      sh """
        curl -sf -X POST \
          -H "Authorization: Bearer \${GH_TOKEN}" \
          -H "Accept: application/vnd.github+json" \
          "https://api.github.com/repos/urbanworkteam/Infra/statuses/${sha}" \
          -d '{"state":"${state}","context":"${CONTEXT}","target_url":"${env.BUILD_URL}","description":"${description}"}'
      """
    }
  } catch (e) {
    echo "ghStatus 실패(무시): ${e.message}"
  }
}

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
    // ⚠️ TF_SKIP은 environment{}에 두지 않는다 — 선언형 environment 블록은 매 스테이지 시작마다
    //    다시 적용돼 런타임에 바꾼 값('true')을 'false'로 리셋함. → Check Changes에서 env.TF_SKIP을
    //    직접 set하고, 이후 스테이지가 그 값을 끝까지 본다(리셋 안 됨).
  }

  stages {

    stage('Checkout') {
      steps {
        checkout scm
        // 커스텀 context 'pending' — terraform Job 전용 칸(pr-head 충돌 회피). GIT_COMMIT은 checkout 후 set됨.
        script { ghStatus('pending', 'terraform pipeline running') }
      }
    }

    stage('Check Changes') {
      steps {
        script {
          // 변경 감지는 fetch 없이 "로컬 ref"만 사용한다.
          //   - tf-agent raw sh에는 GitHub 자격증명이 없어 수동 git fetch가 실패함(실측: FETCH_HEAD·명시적 ref 둘 다 빈 결과).
          //   - Jenkins PR 머지빌드: HEAD = merge(소스, 타깃) → HEAD^2 = 머지된 타깃(main, 로컬). diff(HEAD^2, HEAD) = 이 PR의 순수 변경.
          //   - PR head빌드/branch 빌드: 머지커밋 아님 → 직전 커밋(HEAD~1) 기준.
          // sh는 set +e·2>/dev/null·true로 항상 0 종료 → returnStdout 예외(빌드 ERROR) 방지.
          def isPR = (env.CHANGE_TARGET != null && env.CHANGE_TARGET != '')
          def changed = sh(
            returnStdout: true,
            script: """
              set +e
              if git rev-parse --verify HEAD^2 >/dev/null 2>&1; then
                # PR 머지빌드: parent 순서 불확실(main이 ^1인지 ^2인지 Jenkins 구현 따라 다름).
                # → 양쪽 diff 합집합. 한쪽=PR 순수변경, 다른쪽=main advance.
                #   합쳐도 Desktop/VPC 미포함이면 안전 skip이고, false-skip(놓침)은 발생 안 함.
                { git diff --name-only HEAD^1 HEAD; git diff --name-only HEAD^2 HEAD; } 2>/dev/null | sort -u
              else
                git diff --name-only HEAD~1 HEAD 2>/dev/null || git show --name-only --format='' HEAD 2>/dev/null
              fi
              true
            """
          ).trim()

          // 진단: 다음 빌드 로그에서 변경목록을 바로 확인(오작동 시 원인 추적용)
          echo "Check Changes — isPR=${isPR} / 변경 파일:\n${changed ?: '(없음/판정불가)'}"

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
            env.TF_SKIP = 'false'
            echo "Terraform 변경 감지(또는 판정불가) — plan/apply 진행"
          }
        }
      }
    }

    stage('Assume Role') {
      steps {
        script {
          if (env.TF_SKIP == 'true') { echo "TF_SKIP — Assume Role 건너뜀"; return }
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
      steps {
        script {
          if (env.TF_SKIP == 'true') { echo "TF_SKIP — Load Vars 건너뜀"; return }
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
      steps {
        script {
          if (env.TF_SKIP == 'true') { echo "TF_SKIP — Validate 건너뜀"; return }
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
        script {
          if (env.TF_SKIP == 'true') { echo "TF_SKIP — Plan 건너뜀"; return }
          dir(TF_DIR) {
            sh 'terraform init -input=false'
            def rc = sh(returnStatus: true, script: '''
              terraform plan -input=false -lock-timeout=120s \
                -out=tfplan -detailed-exitcode
            ''')
            if (rc == 1) { error('terraform plan 실패') }
            env.TF_HAS_CHANGES = (rc == 2) ? 'true' : 'false'
            stash name: 'tfplan', includes: 'tfplan'
            if (env.CHANGE_ID) {
              sh 'terraform show -no-color tfplan > plan.txt'
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
        ghStatus('success', env.TF_SKIP == 'true' ? 'no terraform changes (skipped)' : 'terraform ok')
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
        ghStatus('failure', 'terraform pipeline failed')
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
