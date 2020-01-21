terraform {
  required_version = ">= 0.12"
}

# ---------------------------------------------------------------------------------------------------------------------
# PROVIDERS
# ---------------------------------------------------------------------------------------------------------------------
provider "aws" {
  version = "~> 2.2"

  region = var.aws_region
}

provider "local" {
  version = "~> 1.2"
}

provider "template" {
  version = "~> 2.1"
}

provider "random" {
  version = "~> 2.2"
}

data "aws_caller_identity" "current" {
}

# ---------------------------------------------------------------------------------------------------------------------
# LOCALS
# ---------------------------------------------------------------------------------------------------------------------
locals {
  id = var.id != "" ? var.id : random_uuid.uuid.result

  deployment_package_bucket_arn = "arn:aws:s3:::${var.deployment_package_bucket_name}"
}

resource "random_uuid" "uuid" {}

# ---------------------------------------------------------------------------------------------------------------------
# DEPLOY PIPLELINE
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_codepipeline" "deploy_pipeline" {
  name     = "lambda-src-${local.id}"
  role_arn = aws_iam_role.lambda_deploy_codepipeline_iam.arn

  artifact_store {
    location = aws_s3_bucket.artifact_bucket.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "ThirdParty"
      provider         = "GitHub"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        Owner  = var.github_owner
        Repo   = var.github_lambda_repo
        Branch = var.github_lambda_branch
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]
      version          = "1"

      configuration = {
        ProjectName = aws_codebuild_project.lambda_builder.name
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "Deploy"
      run_order       = 1
      category        = "Deploy"
      owner           = "AWS"
      provider        = "S3"
      input_artifacts = ["build_output"]
      version         = "1"

      configuration = {
        BucketName = var.deployment_package_bucket_name
        Extract    = "true"
      }
    }

    action {
      name            = "UpdateLambdaFunctions"
      run_order       = 2
      category        = "Invoke"
      owner           = "AWS"
      provider        = "Lambda"
      input_artifacts = ["build_output"]
      version         = "1"

      configuration = {
        FunctionName   = aws_lambda_function.update_functions_lambda.function_name
      }
    }
  }

  depends_on = [aws_iam_role_policy_attachment.codepipeline]
}

# ---------------------------------------------------------------------------------------------------------------------
# ARTIFACT S3 BUCKET
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_s3_bucket" "artifact_bucket" {
  bucket = "lambda-cd-artifacts-${local.id}"

  force_destroy = var.force_destroy_buckets
}

# ---------------------------------------------------------------------------------------------------------------------
# CODEPIPELINE IAM ROLE
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_iam_role" "lambda_deploy_codepipeline_iam" {
  name = "lambda-src-pipeline-${local.id}"

  assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "codepipeline.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        },
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "codebuild.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF

}

# ---------------------------------------------------------------------------------------------------------------------
# CODEPIPELINE IAM ACCESS
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_iam_policy" "codepipeline" {
  name = "lambda-src-pipeline-${local.id}"

  policy = data.aws_iam_policy_document.codepipeline.json
}

resource "aws_iam_role_policy_attachment" "codepipeline" {
  role       = aws_iam_role.lambda_deploy_codepipeline_iam.id
  policy_arn = aws_iam_policy.codepipeline.arn
}

data "aws_iam_policy_document" "codepipeline" {
  version = "2012-10-17"

  statement {
    sid = "S3Access"

    effect = "Allow"

    actions = ["s3:*"]

    resources = [
      local.deployment_package_bucket_arn,
      "${local.deployment_package_bucket_arn}/*",
      aws_s3_bucket.artifact_bucket.arn,
      "${aws_s3_bucket.artifact_bucket.arn}/*",
    ]
  }

  statement {
    sid = "CloudWatchLogsPolicy"

    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["*"]
  }

  statement {
    sid = "CodeBuildStart"

    effect = "Allow"

    actions = [
      "codebuild:BatchGetBuilds",
      "codebuild:StartBuild",
    ]

    resources = ["*"]
  }

  statement {
    sid = "LambdaInvoke"

    effect = "Allow"

    actions = ["lambda:InvokeFunction"]

    // A known issue with the Lambda IAM permissions system makes it impossible
    // to grant more granular permissions.  lambda:InvokeFunction cannot be called
    // on specific functions, and lambda:Invoke is not recognized as a valid policy.
    // Given that only our Lambda can create the CodePipeline which has this role,
    // I think it ought to be fine.  Frustrating, though.  - John
    //
    // https://stackoverflow.com/q/48031334/2128308
    resources = ["*"]
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# CODEBUILD PROJECT
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_codebuild_project" "lambda_builder" {
  name          = "lambda-src-${local.id}"
  build_timeout = 10
  service_role  = aws_iam_role.lambda_deploy_codepipeline_iam.arn

  environment {
    type         = "LINUX_CONTAINER"
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:2.0"

    environment_variable {
      name  = "NPM_USER"
      value = var.npm_user
    }

    environment_variable {
      name  = "NPM_PASS"
      value = var.npm_pass
    }

    environment_variable {
      name  = "NPM_EMAIL"
      value = var.npm_email
    }
  }

  artifacts {
    type                = "CODEPIPELINE"
    encryption_disabled = true
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = templatefile("${path.module}/buildspec.yml",
      {
        deployment_directory        = var.deployment_directory
        deployment_package_filename = var.deployment_package_filename
        build_command               = var.build_command
        do_npm_login                = var.npm_user != "NULL" && var.npm_pass != "NULL" && var.npm_email != "NULL"
      }
    )
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# CODEPIPELINE UPDATE FUNCTIONS LAMBDA
# ---------------------------------------------------------------------------------------------------------------------
# Wait ensures that the role is fully created when Lambda tries to assume it.
resource "null_resource" "update_functions_lambda_wait" {
  provisioner "local-exec" {
    command = "sleep 10"
  }
  
  depends_on = [aws_iam_role.update_functions_lambda_iam]
}

resource "aws_lambda_function" "update_functions_lambda" {
  filename         = "${path.module}/lambda-deploy-lambda.zip"
  function_name    = "lambda-update-functions-${local.id}"
  role             = aws_iam_role.update_functions_lambda_iam.arn
  handler          = "index.handler"
  source_code_hash = filebase64sha256("${path.module}/lambda-deploy-lambda.zip")
  runtime          = "nodejs12.x"
  timeout          = 60

  environment {
    variables = {
      DEPLOYMENT_PACKAGE_BUCKET = var.deployment_package_bucket_name
      DEPLOYMENT_PACKAGE_KEY    = var.deployment_package_filename
      FUNCTIONS_TO_DEPLOY       = join(",", var.deployment_target_lambdas)
    }
  }

  depends_on = [null_resource.update_functions_lambda_wait]
}

# ---------------------------------------------------------------------------------------------------------------------
# UPDATE FUNCTIONS LAMBDA IAM
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_iam_role" "update_functions_lambda_iam" {
  name = "lambda-update-functions-${local.id}"

  assume_role_policy = data.aws_iam_policy_document.update_functions_lambda_assume_role.json
}

data "aws_iam_policy_document" "update_functions_lambda_assume_role" {
  version = "2012-10-17"

  statement {
    sid = "1"

    effect = "Allow"

    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# UPDATE FUNCTIONS LAMBDA ACCESS
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_iam_policy" "update_functions_lambda_allow_lambda" {
  name = "allow-lambda-update-functions-${local.id}"

  policy = data.aws_iam_policy_document.update_functions_lambda_allow_lambda.json
}

resource "aws_iam_role_policy_attachment" "update_functions_lambda_allow_lambda" {
  role       = aws_iam_role.update_functions_lambda_iam.id
  policy_arn = aws_iam_policy.update_functions_lambda_allow_lambda.arn
}

data "aws_iam_policy_document" "update_functions_lambda_allow_lambda" {
  version = "2012-10-17"

  statement {
    sid = "1"

    effect = "Allow"

    actions = [
      "lambda:UpdateFunctionCode",
      "lambda:PublishVersion",
    ]
    resources = ["*"]
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# UPDATE FUNCTIONS S3 ACCESS
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_iam_policy" "update_functions_lambda_allow_s3" {
  name = "allow-s3-update-functions-${local.id}"

  policy = data.aws_iam_policy_document.update_functions_lambda_allow_s3.json
}

resource "aws_iam_role_policy_attachment" "update_functions_lambda_allow_s3" {
  role       = aws_iam_role.update_functions_lambda_iam.id
  policy_arn = aws_iam_policy.update_functions_lambda_allow_s3.arn
}

data "aws_iam_policy_document" "update_functions_lambda_allow_s3" {
  version = "2012-10-17"

  statement {
    sid = "1"

    effect = "Allow"

    actions = ["s3:GetObject"]
    
    resources = ["${local.deployment_package_bucket_arn}/*"]
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# UPDATE FUNCTIONS LAMBDA CLOUDWATCH ACCESS
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_iam_policy" "update_functions_lambda_allow_cloudwatch" {
  name = "allow-cloudwatch-update-functions-${local.id}"

  policy = data.aws_iam_policy_document.update_functions_lambda_allow_cloudwatch.json
}

resource "aws_iam_role_policy_attachment" "update_functions_lambda_allow_cloudwatch" {
  role       = aws_iam_role.update_functions_lambda_iam.id
  policy_arn = aws_iam_policy.update_functions_lambda_allow_cloudwatch.arn
}

data "aws_iam_policy_document" "update_functions_lambda_allow_cloudwatch" {
  version = "2012-10-17"

  statement {
    sid = "1"

    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# UPDATE FUNCTIONS LAMBDA CODEPIPELINE ACCESS
# ---------------------------------------------------------------------------------------------------------------------
resource "aws_iam_policy" "update_functions_lambda_allow_codepipeline" {
  name = "allow-codepipeline-update-functions-${local.id}"

  policy = data.aws_iam_policy_document.update_functions_lambda_allow_codepipeline.json
}

resource "aws_iam_role_policy_attachment" "update_functions_lambda_allow_codepipeline" {
  role       = aws_iam_role.update_functions_lambda_iam.id
  policy_arn = aws_iam_policy.update_functions_lambda_allow_codepipeline.arn
}

data "aws_iam_policy_document" "update_functions_lambda_allow_codepipeline" {
  version = "2012-10-17"

  statement {
    sid = "1"

    effect = "Allow"

    actions = [
      "codepipeline:PutJobSuccessResult",
      "codepipeline:PutJobFailureResult",
    ]
    resources = ["*"]
  }
}