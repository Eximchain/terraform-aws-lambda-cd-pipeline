# --------------------------------------------------------
# REQUIRED VARIABLES
# --------------------------------------------------------
variable "github_lambda_repo" {
  description = "Name of the repo with the lambda on it"
}

variable "github_lambda_branch" {
  description = "Name of the branch with the lambda on it"
}

variable "deployment_target_lambdas" {
  description = "List of lambda functions to deploy to"
  type        = list
}

variable "deployment_package_filename" {
  description = "Name of the deployment package after being built"
}

variable "deployment_package_bucket_name" {
  description = "S3 bucket name for deployable deployment packages"
}

# --------------------------------------------------------
# OPTIONAL VARIABLES
# --------------------------------------------------------
variable "aws_region" {
  description = "AWS Region to use"
  default     = "us-east-1"
}

variable "force_destroy_buckets" {
  description = "Set to true to force destroy buckets on terraform destroy"
  default     = false
}

variable "github_owner" {
  description = "Owner the repository with the lambda repository belongs to"
  default     = "Eximchain"
}

variable "deployment_directory" {
  description = "The directory in the repository in which the artifacts to deploy can be found"
  default     = "./"
}

variable "build_command" {
  description = "The command to use to build the Lambda, if you want the pipeline to build it (e.g. 'npm run build').  If not specified, the pipeline will assume the static bundle is already built."
  default     = ":"
}

variable "id" {
  description = "Short, unique, descriptive name for resource naming purposes. Will use a UUID if not provided"
  default     = ""
}