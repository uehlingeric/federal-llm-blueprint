output "key_arns" {
  description = "KMS CMK ARNs keyed by domain (data, logs, secrets, etc.)"
  value = {
    for k, v in aws_kms_key.this : k => v.arn
  }
}

output "key_ids" {
  description = "KMS CMK IDs keyed by domain (data, logs, secrets, etc.)"
  value = {
    for k, v in aws_kms_key.this : k => v.id
  }
}

output "alias_arns" {
  description = "KMS CMK alias ARNs keyed by domain (data, logs, secrets, etc.)"
  value = {
    for k, v in aws_kms_alias.this : k => v.arn
  }
}
