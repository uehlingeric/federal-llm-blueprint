output "bucket_ids" {
  description = "S3 bucket IDs keyed by bucket type (documents, access-logs, alb-logs)"
  value = {
    documents     = aws_s3_bucket.documents.id
    "access-logs" = aws_s3_bucket.access_logs.id
    "alb-logs"    = aws_s3_bucket.alb_logs.id
  }
}

output "bucket_arns" {
  description = "S3 bucket ARNs keyed by bucket type (documents, access-logs, alb-logs)"
  value = {
    documents     = aws_s3_bucket.documents.arn
    "access-logs" = aws_s3_bucket.access_logs.arn
    "alb-logs"    = aws_s3_bucket.alb_logs.arn
  }
}

output "documents_bucket_regional_domain_name" {
  description = "Regional domain name of the documents bucket; useful for in-VPC S3 API calls and data ingestion pipelines"
  value       = aws_s3_bucket.documents.bucket_regional_domain_name
}
