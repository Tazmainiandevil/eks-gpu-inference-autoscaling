terraform {
  # Local state — fine for personal dev/testing.
  # To migrate to S3 (recommended for shared or production use):
  #   1. Copy backend.hcl.example → backend.hcl and fill in your bucket/table values
  #   2. Replace `backend "local" {}` below with `backend "s3" {}`
  #   3. Run: terraform init -backend-config=backend.hcl -migrate-state
  backend "local" {}
}
