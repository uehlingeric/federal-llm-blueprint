# Deliberately non-compliant module used to prove every CI gate fails.
# VIOLATION (fmt gate): the resource block below is misindented.
# VIOLATION (validate gate): references var.undeclared_variable, which does not exist.
# VIOLATION (checkov gate): S3 bucket with no encryption, versioning, logging,
#   public access block, or lifecycle configuration.
resource "aws_s3_bucket" "noncompliant" {
        bucket = "negative-test-noncompliant"
    force_destroy = var.undeclared_variable
}
