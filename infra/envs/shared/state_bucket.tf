# ─── Terraform state bucket ──────────────────────────────────────────────────
#
# The bucket itself was bootstrapped by hand (dev-docs/AWS_SETUP.md) and is
# deliberately NOT a Terraform resource here: importing it would put the
# bucket holding this very state under the state's own control, one bad diff
# from a destroy. Only its policy is managed. It had none before this.
#
# State holds prod secrets (provider client secrets, SSM-sourced values), so:
#   - TLS only. Every AWS SDK, the CLI and Terraform already use HTTPS; this
#     makes a plaintext request fail rather than succeed.
#   - SSE stays SSE-S3 for now. SSE-KMS with a CMK is a follow-up: the S3
#     backend sends an explicit AES256 header unless `kms_key_id` is set, so a
#     bucket-default CMK would encrypt nothing Terraform writes until every
#     backend in both repos (and every dev machine) names the key, and every CI
#     role and dev user holds kms:Decrypt/GenerateDataKey on it.

locals {
  state_bucket = "andreas-services-terraform-state"
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      "arn:aws:s3:::${local.state_bucket}",
      "arn:aws:s3:::${local.state_bucket}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state_bucket" {
  bucket = local.state_bucket
  policy = data.aws_iam_policy_document.state_bucket.json
}
